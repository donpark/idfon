"""Train the registry's decision heads on shards (data.py), distill the teacher-sourced
ones, and report every head against its gate. New batches of real conversations are
just more shards: keep them in the shard dirs and warm-start from the previous
student so the model accumulates instead of restarting.

    .venv/bin/python ports/tyger-student/train.py --shards bench-results/student-shards/train \
        --val bench-results/student-shards/val --out bench-results/student
    .venv/bin/python ports/tyger-student/train.py --shards <new batch dir(s)> \
        --init bench-results/student/student.pt --out bench-results/student   # batch N+1
    .venv/bin/python ports/tyger-student/train.py --selfcheck        # synthetic smoke (torch + numpy only)

The gate report runs on --val (or the last training shard when omitted). Exit code
is 1 when any gated head misses its bar; decision-level agreement is gate.py's job.
"""
import argparse
import json
import os
import sys
from dataclasses import replace

import numpy as np
import torch

from data import FRAME_KEYS, iter_shards, pick_features, save_shard
from model import Student, count_params
from registry import HEADS, Head, teacher_cols


def windows(T, w):
    """Fixed-size frame windows; the tail shorter than one window is dropped.
    shortcut: the GRU state resets between windows, 20 s of history is the compromise;
    upgrade to stateful batching if long-range drift shows up in the gates."""
    for s in range(0, T - w + 1, w):
        yield slice(s, s + w)


def batch(frames, labels, sl, layer=15):
    hu, ha = pick_features(frames, layer)
    t = lambda a: torch.from_numpy(np.ascontiguousarray(a[sl]))
    lab = {k: torch.from_numpy(np.ascontiguousarray(v[sl])) for k, v in labels.items()}
    return t(hu), t(ha), t(frames["energy"]), t(frames["prev_state"]), t(frames["teacher"]), lab


def auc(scores, labels):
    """Mann-Whitney AUC via average ranks (no scipy). None when one class is empty."""
    labels = np.asarray(labels, dtype=bool)
    n_pos, n_neg = int(labels.sum()), int((~labels).sum())
    if not n_pos or not n_neg:
        return None
    _, inv, counts = np.unique(scores, return_inverse=True, return_counts=True)
    ranks = (np.cumsum(counts) - (counts - 1) / 2.0)[inv]
    return float((ranks[labels].sum() - n_pos * (n_pos + 1) / 2.0) / (n_pos * n_neg))


def evaluate(model, shards, layer=15):
    """Per-head metrics over (frames, labels) pairs: mse vs teacher probs for `mse`
    heads, AUC vs labels for `bce` heads. Missing metrics are None."""
    model.eval()
    agg = {h.id: {"sq": 0.0, "n": 0, "scores": [], "lab": []} for h in model.heads_spec}
    with torch.no_grad():
        for frames, labels in shards:
            for sl in windows(len(frames["energy"]), model.window):
                hu, ha, energy, prev_state, teacher, lab = batch(frames, labels, sl, layer)
                outs, _ = model(hu, ha, energy, prev_state)
                targets = model.targets(teacher, lab)
                for h in model.heads_spec:
                    o, t = outs[h.id], targets[h.id]
                    if teacher_cols(h) is not None:  # score metric = prob matching, whatever the training loss
                        p = torch.softmax(o, dim=-1) if h.kind == "choice" else torch.sigmoid(o)
                        agg[h.id]["sq"] += float(((p - t) ** 2).sum())
                        agg[h.id]["n"] += t.numel()
                    else:
                        agg[h.id]["scores"].extend(torch.sigmoid(o.squeeze(-1)).flatten().tolist())
                        agg[h.id]["lab"].extend(t.flatten().tolist())
    res = {}
    for hid, a in agg.items():
        res[hid] = {"mse": a["sq"] / a["n"]} if a["n"] else {"auc": auc(a["scores"], a["lab"])}
    model.train()
    return res


def gate_check(head, metrics):
    """-> {"status": "pass"|"fail"|"report-only", ...} per the registry's gate dict."""
    if not head.gate:
        return {"status": "report-only"}
    metric, limit = head.gate["metric"], head.gate.get("max", head.gate.get("min"))
    value = metrics.get(metric)
    if value is None:
        return {"status": "report-only", "note": f"no {metric} metric on val"}
    ok = value <= limit if "max" in head.gate else value >= limit
    return {"status": "pass" if ok else "fail", "metric": metric, "value": round(value, 5), "limit": limit}


def run(shard_dirs, val_dir, out_dir, epochs, window, lr, init=None, feature_layer=15, seed=0,
        distill_loss="soft", pos_weight=1.0, head_set="all"):
    torch.manual_seed(seed)
    np.random.seed(seed)
    if head_set == "teacher-seam":
        base_heads = tuple(h for h in HEADS if teacher_cols(h) is not None)
    elif head_set == "all":
        base_heads = HEADS
    else:
        raise ValueError(f"unknown head set: {head_set!r}")
    if distill_loss == "mse":  # A/B instrument: old probability-matching distillation
        heads = tuple(replace(h, loss="mse") if teacher_cols(h) is not None else h for h in base_heads)
    else:
        heads = base_heads
    if pos_weight != 1.0:  # A/B instrument: rare-fire frame weighting (barge/backchannel)
        heads = tuple(replace(h, pos_weight=pos_weight) if h.id in ("barge", "backchannel") else h
                      for h in heads)
    loaded = [x for d in shard_dirs for x in iter_shards(d)]
    if not loaded:
        sys.exit(f"no shards in {', '.join(shard_dirs)}")
    train_sh = [(f, l) for _, f, l, _, _ in loaded]
    if val_dir:
        val_sh = [(f, l) for _, f, l, _, _ in iter_shards(val_dir)]
        if not val_sh:
            sys.exit(f"no shards in {val_dir}")
    else:
        val_sh = [(f, l) for _, f, l, _, _ in loaded[-1:]] if len(loaded) > 1 else train_sh

    model = Student(heads)
    model.window = window
    if init:
        ckpt = torch.load(init, map_location="cpu")
        target_state = model.state_dict()
        extra = set(ckpt["state_dict"]) - target_state.keys()
        known_heads = {h.id for h in HEADS}
        assert all(k.startswith("heads.") and k.split(".")[1] in known_heads for k in extra), \
            f"checkpoint has unknown keys: {sorted(extra)}"
        unexpected = model.load_state_dict({k: v for k, v in ckpt["state_dict"].items()
                                            if k in target_state}, strict=False)[1]
        assert not unexpected, f"checkpoint has unknown keys: {unexpected}"
        fresh = [h.id for h in heads if h.id not in ckpt.get("heads", [])]
        print(f"warm start: {init} (batch N+1; fresh heads: {', '.join(fresh) or 'none'})")
    print(f"student: {count_params(model):,} params ({count_params(model) * 4 / 1e6:.1f} MB fp32), "
          f"{len(train_sh)} shard(s), heads: {', '.join(h.id for h in heads)}")
    opt = torch.optim.Adam(model.parameters(), lr=lr)
    first = last = None
    for ep in range(epochs):
        total, steps = 0.0, 0
        order = torch.randperm(sum(len(list(windows(len(f['energy']), window))) for f, _ in train_sh))
        batches = []
        for frames, labels in train_sh:
            for sl in windows(len(frames["energy"]), window):
                batches.append(batch(frames, labels, sl, feature_layer))
        for i in order.tolist():
            hu, ha, energy, prev_state, teacher, lab = batches[i]
            outs, _ = model(hu, ha, energy, prev_state)
            losses = model.losses(outs, model.targets(teacher, lab))
            loss = torch.stack(list(losses.values())).mean()
            opt.zero_grad()
            loss.backward()
            opt.step()
            total += float(loss)
            steps += 1
        first = first if first is not None else total / steps
        last = total / steps
        print(f"  epoch {ep + 1}/{epochs}: loss {last:.5f}")

    metrics = evaluate(model, val_sh, feature_layer)
    report = {"params": count_params(model), "window_frames": window, "epochs": epochs,
              "feature_layer": feature_layer, "distill_loss": distill_loss, "pos_weight": pos_weight,
              "head_set": head_set,
              "shards": [os.path.basename(p) for p, _, _, _, _ in loaded], "heads": {}}
    ok = True
    print(f"\n{'head':<12} {'source':<18} {'val':>12} {'gate':>12}  status")
    for h in heads:
        m = metrics[h.id]
        shown = f"mse {m['mse']:.5f}" if "mse" in m else (f"auc {m['auc']:.3f}" if m.get("auc") is not None else "n/a")
        g = gate_check(h, m)
        ok = ok and g["status"] != "fail"
        report["heads"][h.id] = {"source": h.source, "val": m, "gate": g,
                                 "train_loss": round(last, 5)}
        lim = f"{h.gate.get('metric', '')} {h.gate.get('max', h.gate.get('min', ''))}" if h.gate else "-"
        print(f"{h.id:<12} {h.source:<18} {shown:>12} {lim:>12}  {g['status']}")

    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        torch.save({"state_dict": model.state_dict(), "heads": [h.id for h in heads],
                    "width": model.width, "layers": model.layers, "params": count_params(model)},
                   os.path.join(out_dir, "student.pt"))
        with open(os.path.join(out_dir, "report.json"), "w") as f:
            json.dump(report, f, indent=2)
        print(f"\nwrote {out_dir}/student.pt + report.json")
    return ok, first, last, model


def selfcheck():
    torch.manual_seed(0)
    np.random.seed(0)
    # 1. size brief: P1 says ~1-1.5M params / <= 6 MB fp32
    model = Student(HEADS)
    n = count_params(model)
    assert n < 2_000_000, f"student is {n} params: over the size brief"

    # 2. shard round-trip (data.py)
    import tempfile
    T, W = 1200, 250
    teacher_model = Student(HEADS)  # frozen random weights = a learnable synthetic teacher
    with torch.no_grad():
        hu, ha = torch.randn(T, 1024) * 0.5, torch.randn(T, 1024) * 0.5
        energy = torch.rand(T) * 60 - 40
        prev_state = torch.randint(0, 5, (T,))
        t_outs, _ = teacher_model(hu[None], ha[None], energy[None], prev_state[None])
        teacher = teacher_model.eight_vector(t_outs)[0].numpy().astype(np.float32)
        hold = (torch.sigmoid(t_outs["hold"][0, :, 0]) > 0.5).numpy().astype(np.int8)
    frames = {"hu": hu.numpy(), "ha": ha.numpy(), "energy": energy.numpy(),
              "prev_state": prev_state.numpy(), "teacher": teacher}
    bot = torch.zeros(T)                 # synthetic Beginning-of-Turn positives for the turn_grab head
    bot[::40] = 1.0
    labels = {"hold_ch0": hold, "bot_ch0": bot}
    with tempfile.TemporaryDirectory() as d:
        save_shard(os.path.join(d, "s1.npz"), "s1", frames, labels)
        save_shard(os.path.join(d, "s2.npz"), "s2", frames, labels)
        loaded = list(iter_shards(d))
        assert len(loaded) == 2
        f2, l2, meta = loaded[0][1], loaded[0][2], loaded[0][4]
        assert meta["session_id"] == "s1" and meta["frames"] == T
        assert loaded[0][3] is None  # no events recorded in the self-check shard
        for k in FRAME_KEYS:
            assert np.array_equal(f2[k], np.asarray(frames[k], dtype=f2[k].dtype)), k
        assert np.array_equal(l2["hold_ch0"], hold)
        assert float(np.asarray(l2["bot_ch0"]).sum()) == float(bot.sum())

        # 3. the seam contract: 8 slots, probs where the rules expect probs
        outs, _ = model(hu[:W][None], ha[:W][None], energy[:W][None], prev_state[:W][None])
        ev = model.eight_vector(outs)
        assert ev.shape == (1, W, 8), ev.shape
        assert torch.allclose(ev[0, :, 5], torch.sigmoid(outs["barge"][0, :, 0]))

        # 4. a registry entry whose source is declared but unwired must fail loudly
        try:
            model.targets(torch.zeros(1, W, 8), {"hold_ch0": torch.zeros(1, W), "bot_ch0": torch.zeros(1, W)})
            extra = Student(HEADS + (Head("mood", "noul", 1, ("false", "true"), "outcome:mood", "bce", {}),))
            extra.targets(torch.zeros(1, W, 8), {"hold_ch0": torch.zeros(1, W), "bot_ch0": torch.zeros(1, W)})
            raise AssertionError("unwired source did not raise")
        except NotImplementedError:
            pass

        # 5. the gate machinery flips on known values
        from registry import by_id
        assert gate_check(by_id("endpoint"), {"mse": 0.01})["status"] == "pass"
        assert gate_check(by_id("endpoint"), {"mse": 0.5})["status"] == "fail"
        assert gate_check(by_id("hold"), {"auc": 0.9})["status"] == "report-only"

        # 6. train on the synthetic teacher and lose a solid chunk of the loss
        # (bar is loose: soft CE/BCE starts higher and falls slower than MSE — gates
        # judge convergence quality, this only proves the loop learns)
        _, first, last, _ = run([d], None, None, epochs=25, window=W, lr=5e-3)
        assert last < first * 0.75, f"loss did not fall: {first} -> {last}"
    print("selfcheck ok")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", nargs="+", default=None, help="training shard dir(s) (featurize.py output)")
    ap.add_argument("--val", default=None, help="shard dir for the gate report (default: last training shard)")
    ap.add_argument("--init", default=None, help="warm start from this student.pt (batch N+1)")
    ap.add_argument("--feature-layer", type=int, default=15,
                    help="which recorded encoder layer the student reads (the layer sweep)")
    ap.add_argument("--seed", type=int, default=0, help="training seed (comparisons need it fixed)")
    ap.add_argument("--distill-loss", choices=("soft", "mse"), default="soft",
                    help="teacher-head loss: soft = cross-entropy on teacher probs (default), "
                         "mse = probability matching (the A/B baseline)")
    ap.add_argument("--head-set", choices=("all", "teacher-seam"), default="all",
                    help="all registered heads, or only the five Tyger teacher-seam heads")
    ap.add_argument("--pos-weight", type=float, default=1.0,
                    help="upweight rare-fire frames (barge/backchannel bce positives) in the loss")
    ap.add_argument("--out", default=None, help="write student.pt + report.json here")
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--window", type=int, default=250, help="training window in frames (20 s)")
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--selfcheck", action="store_true", help="synthetic smoke: shapes, shard round-trip, loss falls")
    args = ap.parse_args()
    if args.selfcheck:
        selfcheck()
    elif args.shards:
        ok, *_ = run(args.shards, args.val, args.out, args.epochs, args.window, args.lr,
                     init=args.init, feature_layer=args.feature_layer, seed=args.seed,
                     distill_loss=args.distill_loss, pos_weight=args.pos_weight, head_set=args.head_set)
        sys.exit(0 if ok else 1)
    else:
        ap.error("need --shards or --selfcheck")
