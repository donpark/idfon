"""The weighted multi-teacher baseline (epic #132 P2): one `SharedLatentStudent`
trained on ONE shard set per registry tap adapter, with per-axis teacher weighting
from the P0 tap-probe table. The fixed baseline the P3 consistency term is added to
— it must reproduce the current gate bars first (score gates, event agreement,
harness deltas), and every number must be regenerable from repo scripts.

Per-axis weighting rule (the epic's hard rule — probe quality decides, NEVER
averaged teacher outputs; averaging muddled teachers is what the failed event-loss
auxiliary demonstrated):

    raw(tap, head) = max(val R2 of the tap's ridge probe on the head's 8-vector
                         columns, 0)       # probe.py, fit on the tap's train shards
    w(tap, head)   = raw / mean(raw over the five teacher heads)   # mean = 1
    w(tap, hold)   = 1.0                  # corpus head, no probe applies

so the weighted loss `sum(w[h] * head_loss[h]) / n_heads` has exactly the scale of
train.py's plain mean under uniform weights, while each tap's batches emphasize the
axes that tap measurably carries (P0, bench-results/tap-probes.md: l15-windowed
leads p_end/bc, l4-streaming is at parity with l4-windowed on every dualturn axis).
The held-out val R2 is the weight basis on purpose: same split the score gates judge
on, so the formula is one probe.py run away from the report.

    .venv/bin/python ports/tyger-student/train_shared.py \
        --tap l15-windowed=/path/to/student-shards \
        --tap l4-windowed=/path/to/l4-shards \
        --tap l4-streaming=/path/to/tap4-shards \
        --out bench-results/shared-weighted [--epochs 20] [--weights auto|uniform|FILE]

Cross-tap consistency (epic #132 P3, issue #143): `--consistency LAM` adds
`LAM · symmetric-KL(decisions via tap A ‖ decisions via tap B)` on the SAME
frames (the shard sets are frame-aligned per session), seam decisions only —
the 8-vector: state softmax KL + four Bernoulli Kls, mean over the five heads.
Per step a seeded random partner tap among the others is drawn (grads through
both forwards); the teacher losses and per-axis weights are untouched — the
term aligns taps to each other toward the same decision endpoint, it never
replaces teacher targets. `--consistency 0` (default) reduces exactly to the
baseline recipe (same items, same seeded shuffle, same loss).

Each tap root holds train/ and val/ subdirs (the three dualturn sets are
frame-aligned per session id — paired multi-tap batches for P3 need no matching).
The report (report.json + stdout) prints the probe R2, the exact weights, and every
head's gate per tap. Exit code is 1 when any tap path misses a score gate.
"""
import argparse
import glob
import json
import os
import sys

import numpy as np
import torch
from dataclasses import replace

from checkpoint import TapBound, load as load_checkpoint, save as save_checkpoint
from data import iter_shards
from model import SharedLatentStudent, count_params
from qat import fake_quant, project as qat_project, selfcheck_parity, target_params
from registry import ADAPTERS, ADAPTER_GATE, HEADS, adapter_by_id, seam_heads, teacher_cols
from train import batch, evaluate, gate_check, windows

import probe as probe_mod

# probe.py axis -> registry head, keyed by the 8-vector columns each covers
AXIS_BY_COLS = {tuple(cols): axis for axis, cols in probe_mod.AXES}
HEAD_AXIS = {h.id: AXIS_BY_COLS[tuple(teacher_cols(h))]
             for h in HEADS if teacher_cols(h) is not None}
DEPLOY_TAP = "l4-streaming"   # registry's deploy target; the checkpoint's default eval tap
EPS = 1e-6


def seam_kl(outs_a, outs_b):
    """Symmetric KL between two taps' seam decisions on the same frames — the P3
    consistency surface (the 8-vector the rules read): state softmax KL + four
    Bernoulli Kls, mean over the five teacher-seam heads (hold excluded: its
    corpus labels are identical on every tap). Zero iff the decisions agree."""
    kls = []
    for h in seam_heads():
        a, b = outs_a[h.id], outs_b[h.id]
        if h.kind == "choice":
            pa, pb = torch.softmax(a, dim=-1), torch.softmax(b, dim=-1)
            la, lb = pa.clamp_min(EPS).log(), pb.clamp_min(EPS).log()
            kls.append(0.5 * ((pa * (la - lb)).sum(-1) + (pb * (lb - la)).sum(-1)))
        else:
            pa = torch.sigmoid(a.squeeze(-1)).clamp(EPS, 1 - EPS)
            pb = torch.sigmoid(b.squeeze(-1)).clamp(EPS, 1 - EPS)
            fwd = pa * (pa.log() - pb.log()) + (1 - pa) * ((1 - pa).log() - (1 - pb).log())
            rev = pb * (pb.log() - pa.log()) + (1 - pb) * ((1 - pb).log() - (1 - pa).log())
            kls.append(0.5 * (fwd + rev))
    return torch.stack(kls).mean()


def partner_streams(frames, sl):
    """A partner tap's two feature streams for one window slice."""
    t = lambda a: torch.from_numpy(np.ascontiguousarray(a[sl]))
    return t(frames["hu"]), t(frames["ha"])


def tap_probe_r2(tap_root, alpha=1.0):
    """Per-axis val ridge R2 for one tap's canonical hu/ha streams — the P0 probe,
    run on the tap root's own train/val shards (probe.py, same fit/split)."""
    paths = {"train": [p for p in sorted(glob.glob(os.path.join(tap_root, "train", "*.npz")))],
             "val": [p for p in sorted(glob.glob(os.path.join(tap_root, "val", "*.npz")))]}
    if not paths["train"] or not paths["val"]:
        sys.exit(f"{tap_root}: need train/ and val/ shard dirs")
    res = probe_mod.probe(paths, "hu", "ha", alpha)
    return {axis: (0.0 if not np.isfinite(r2) else float(r2)) for axis, (r2, _cos) in res.items()}


def axis_weights(r2_by_axis):
    """The weighting rule (module docstring): per-head weights whose teacher-head
    mean is exactly 1.0; hold is always 1.0."""
    raw = {h: max(r2_by_axis[HEAD_AXIS[h]], 0.0) for h in HEAD_AXIS}
    if sum(raw.values()) == 0:  # nothing decodable anywhere: uniform is the only honest fallback
        return {h.id: 1.0 for h in HEADS}
    scale = 5.0 / sum(raw.values())
    out = {h: raw[h] * scale for h in raw}
    out["hold"] = 1.0
    return out


def build_weights(tap_roots, mode, alpha=1.0):
    """-> ({tap: {head: w}}, {tap: {axis: r2}}) for --weights auto/uniform/FILE."""
    if mode == "uniform":
        return ({t: {h.id: 1.0 for h in HEADS} for t in tap_roots}, {})
    if mode != "auto":
        if not os.path.exists(mode):
            sys.exit(f"--weights: no such file: {mode} (want auto, uniform, or a weights.json)")
        with open(mode) as f:
            saved = json.load(f)
        return ({t: dict(saved["weights"][t]) for t in tap_roots},
                {t: dict(saved["probe_r2"].get(t, {})) for t in tap_roots})
    weights, r2 = {}, {}
    for tap, root in tap_roots.items():
        r2[tap] = tap_probe_r2(root, alpha)
        weights[tap] = axis_weights(r2[tap])
    return weights, r2


def load_tap_shards(tap_roots, split):
    """-> {tap: {session_id: (frames, labels)}} for one split of every tap root
    (session ids are the shard stems; the sets are frame-aligned per session)."""
    out = {}
    for tap, root in tap_roots.items():
        shards = {}
        for p, f, l, _, _ in iter_shards(os.path.join(root, split)):
            shards[os.path.splitext(os.path.basename(p))[0]] = (f, l)
        if not shards:
            sys.exit(f"no shards in {os.path.join(root, split)}")
        out[tap] = shards
    return out


def run(tap_roots, out_dir, epochs, window, lr, seed=0, distill_loss="soft", weights="auto",
        init=None, deploy_tap=None, val_split="val", consistency=0.0, qat=0):
    torch.manual_seed(seed)
    np.random.seed(seed)
    heads = HEADS
    if distill_loss == "mse":  # A/B instrument, same as train.py
        heads = tuple(replace(h, loss="mse") if teacher_cols(h) is not None else h for h in HEADS)
    w_by_tap, r2_by_tap = build_weights(tap_roots, weights)
    deploy_tap = deploy_tap or (DEPLOY_TAP if DEPLOY_TAP in tap_roots else next(iter(tap_roots)))
    print(f"per-axis teacher weights (probe R2 basis, teacher-head mean 1.0; hold fixed 1.0):")
    print(f"  {'tap':<14} {'head':<12} {'probe_r2':>9} {'weight':>7}")
    for tap in tap_roots:
        for h in heads:
            r2 = r2_by_tap.get(tap, {}).get(HEAD_AXIS.get(h.id, ""), None)
            print(f"  {tap:<14} {h.id:<12} "
                  f"{f'{r2:.3f}' if r2 is not None else '-':>9} {w_by_tap[tap][h.id]:>7.3f}")

    model = SharedLatentStudent(heads, adapters=[adapter_by_id(t) for t in tap_roots])
    model.window = window
    if init:
        ckpt = torch.load(init, map_location="cpu")
        target = model.state_dict()
        unexpected = [k for k in ckpt["state_dict"] if k not in target]
        assert not unexpected, f"checkpoint has unknown keys: {unexpected}"
        missing = [k for k in target if k not in ckpt["state_dict"]]
        model.load_state_dict({k: v for k, v in ckpt["state_dict"].items() if k in target}, strict=False)
        print(f"warm start: {init} (fresh: {', '.join(sorted({k.split('.')[1] for k in missing})) or 'none'})")
    if qat:
        qat_project(model, qat)  # every forward runs on the int8 grid the export ships
    print(f"shared student: {count_params(model):,} params ({count_params(model) * 4 / 1e6:.1f} MB fp32), "
          f"adapters: {', '.join(tap_roots)}, heads: {', '.join(h.id for h in heads)}"
          + (f", QAT group-{qat}" if qat else ""))

    train_sh = load_tap_shards(tap_roots, "train")
    if consistency > 0:  # paired windows need the same sessions in every tap set
        ids = [set(s) for s in train_sh.values()]
        if any(s != ids[0] for s in ids[1:]):
            sys.exit("consistency needs identical session ids in every tap set")
        for sid in ids[0]:
            lens = {len(train_sh[t][sid][0]["energy"]) for t in tap_roots}
            if len(lens) != 1:
                sys.exit(f"consistency needs frame-aligned sessions; {sid}: {sorted(lens)}")
    opt = torch.optim.Adam(model.parameters(), lr=lr)
    partner_rng = np.random.default_rng(seed)  # only touched when consistency > 0
    first = last = None
    for ep in range(epochs):
        items = [(tap, sid, frames, labels, sl)
                 for tap, shards in train_sh.items()
                 for sid, (frames, labels) in sorted(shards.items())
                 for sl in windows(len(frames["energy"]), window)]
        total, steps = 0.0, 0
        for i in torch.randperm(len(items)).tolist():
            tap, sid, frames, labels, sl = items[i]
            hu, ha, energy, prev_state, teacher, lab = batch(frames, labels, sl)
            outs, _ = model(tap, hu, ha, energy, prev_state)
            losses = model.losses(outs, model.targets(teacher, lab))
            w = w_by_tap[tap]
            loss = torch.stack([w[h.id] * losses[h.id] for h in heads]).sum() / len(heads)
            if consistency > 0:
                others = [t for t in tap_roots if t != tap]
                ptap = others[int(partner_rng.integers(len(others)))]
                hu_p, ha_p = partner_streams(train_sh[ptap][sid][0], sl)
                outs_p, _ = model(ptap, hu_p, ha_p, energy, prev_state)
                loss = loss + consistency * seam_kl(outs, outs_p)
            opt.zero_grad()
            loss.backward()
            opt.step()
            if qat:
                qat_project(model, qat)  # projected-gradient QAT: params back on the int8 grid
            total += loss.item()
            steps += 1
        first = first if first is not None else total / steps
        last = total / steps
        print(f"  epoch {ep + 1}/{epochs}: weighted loss {last:.5f}", flush=True)

    report = {"model": "SharedLatentStudent", "params": count_params(model),
              "taps": dict(tap_roots), "deploy_tap": deploy_tap,
              "weights_mode": weights, "probe_r2": r2_by_tap, "weights": w_by_tap,
              "consistency_lambda": consistency, "qat_group": qat,
              "window_frames": window, "epochs": epochs, "distill_loss": distill_loss,
              "seed": seed, "lr": lr, "train_loss_first": round(first, 5),
              "train_loss_last": round(last, 5), "heads": {}}
    ok = True
    for tap, root in tap_roots.items():
        val_sh = [(f, l) for _, f, l, _, _ in iter_shards(os.path.join(root, val_split))]
        metrics = evaluate(TapBound(model, tap), val_sh)
        report["heads"][tap] = {}
        print(f"\n== val gates: {tap} ({os.path.basename(root)}/{val_split})")
        print(f"{'head':<12} {'source':<18} {'val':>12} {'gate':>12}  status")
        for h in heads:
            m = metrics[h.id]
            shown = (f"mse {m['mse']:.5f}" if "mse" in m
                     else (f"auc {m['auc']:.3f}" if m.get("auc") is not None else "n/a"))
            # per-adapter gate ceilings where tap information bounds the head (registry.ADAPTER_GATE)
            gate_spec = ADAPTER_GATE.get(tap, {}).get(h.id, h.gate)
            g = gate_check(replace(h, gate=gate_spec), m)
            ok = ok and g["status"] != "fail"
            report["heads"][tap][h.id] = {"source": h.source, "val": m, "gate": g}
            lim = f"{gate_spec.get('metric', '')} {gate_spec.get('max', gate_spec.get('min', ''))}" if gate_spec else "-"
            print(f"{h.id:<12} {h.source:<18} {shown:>12} {lim:>12}  {g['status']}")

    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        save_checkpoint(os.path.join(out_dir, "student.pt"), model, heads, tap=deploy_tap)
        with open(os.path.join(out_dir, "report.json"), "w") as f:
            json.dump(report, f, indent=2)
        with open(os.path.join(out_dir, "weights.json"), "w") as f:
            json.dump({"weights": w_by_tap, "probe_r2": r2_by_tap}, f, indent=2)
        print(f"\nwrote {out_dir}/student.pt + report.json + weights.json")
    return ok, first, last, model


def selfcheck():
    torch.manual_seed(0)
    np.random.seed(0)
    import tempfile
    from data import save_shard
    T, W = 750, 250
    teacher_model = SharedLatentStudent(HEADS)  # frozen random weights = a learnable synthetic teacher
    with tempfile.TemporaryDirectory() as d:
        # two tap roots with frame-aligned synthetic shards; each tap's teacher is
        # that tap's own frozen-teacher pass, so the mapping is actually learnable
        for tap in ("l15-windowed", "l4-streaming"):
            for sess in ("s1", "s2"):
                frames = {"hu": (torch.randn(T, 1024) * 0.5).numpy().astype(np.float32),
                          "ha": (torch.randn(T, 1024) * 0.5).numpy().astype(np.float32),
                          "energy": (torch.rand(T) * 60 - 40).numpy().astype(np.float32),
                          "prev_state": torch.randint(0, 5, (T,)).numpy()}
                with torch.no_grad():
                    outs, _ = teacher_model(tap, torch.from_numpy(frames["hu"])[None],
                                            torch.from_numpy(frames["ha"])[None],
                                            torch.from_numpy(frames["energy"])[None],
                                            torch.from_numpy(frames["prev_state"])[None])
                frames["teacher"] = teacher_model.eight_vector(outs)[0].numpy().astype(np.float32)
                hold = (torch.sigmoid(outs["hold"][0, :, 0]) > 0.5).numpy().astype(np.int8)
                for split in ("train", "val"):
                    save_shard(os.path.join(d, tap, split, f"{sess}.npz"), sess,
                               frames, {"hold_ch0": hold})
        roots = {"l15-windowed": os.path.join(d, "l15-windowed"),
                 "l4-streaming": os.path.join(d, "l4-streaming")}

        # 1. the weighting rule: teacher-head mean exactly 1.0, hold fixed 1.0
        w_by_tap, _ = build_weights(roots, "auto")
        for tap, w in w_by_tap.items():
            assert abs(sum(w[h.id] for h in HEADS if teacher_cols(h)) / 5 - 1.0) < 1e-9, tap
            assert w["hold"] == 1.0, tap
        wu, _ = build_weights(roots, "uniform")
        assert all(v == 1.0 for w in wu.values() for v in w.values())

        # 2. train on the synthetic teacher and lose a solid chunk of the loss
        _, first, last, model = run(roots, None, epochs=25, window=W, lr=5e-3, deploy_tap="l4-streaming")
        # bar is looser than train.py's 0.75: two taps share one trunk and one decoder,
        # so the synthetic smoke converges slower than the single-tap loop's
        assert last < first * 0.8, f"loss did not fall: {first} -> {last}"

        # 3. checkpoint round-trip: tap-bound replay reads like Student, wrong tap raises
        out = os.path.join(d, "out")
        os.makedirs(out)
        save_checkpoint(os.path.join(out, "student.pt"), model, HEADS, tap="l4-streaming")
        bound, ckpt = load_checkpoint(os.path.join(out, "student.pt"))
        assert bound.tap == "l4-streaming" and ckpt["adapters"] == ["l15-windowed", "l4-streaming"]
        outs, _ = bound(torch.zeros(1, W, 1024), torch.zeros(1, W, 1024),
                        torch.zeros(1, W), torch.zeros(1, W, dtype=torch.long))
        assert bound.eight_vector(outs).shape == (1, W, 8)
        try:
            TapBound(bound._model, "l24-streaming")
            raise AssertionError("unknown tap did not raise")
        except KeyError:
            pass

        # 4. the P3 consistency term: zero iff the seam decisions agree, and the
        # paired-window run trains (partner forward + KL on top of the same losses)
        z = {h.id: torch.zeros(1, W, h.size) for h in HEADS}
        o = {h.id: torch.ones(1, W, h.size) for h in HEADS}
        assert float(seam_kl(z, z)) == 0.0
        assert float(seam_kl(z, o)) > 0.0
        _, c_first, c_last, _ = run(roots, None, epochs=8, window=W, lr=5e-3, consistency=0.1)
        assert c_last < c_first, f"consistency loss did not fall: {c_first} -> {c_last}"

        # 5. QAT: the torch fake-quant matches quantize_step's numpy grid bit-exactly,
        # and the projected-gradient loop runs and learns (the export gate — int8 vs
        # torch, export.py — is what pins shipped-grid parity)
        assert selfcheck_parity() == "ok"
        _, q_first, q_last, _ = run(roots, None, epochs=6, window=W, lr=5e-3, qat=16)
        assert q_last < q_first, f"QAT loss did not fall: {q_first} -> {q_last}"
    print("selfcheck ok")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--tap", action="append", default=None, metavar="ID=ROOT",
                    help="registry adapter id = shard root holding train/ + val/ (repeatable)")
    ap.add_argument("--val-split", default="val", help="val subdir name under each root")
    ap.add_argument("--weights", default="auto",
                    help="auto = probe.py R2 per tap/axis (default), uniform = all 1.0 (the A/B), "
                         "or a weights.json from a previous run")
    ap.add_argument("--consistency", type=float, default=0.0,
                    help="P3 cross-tap KL weight: loss += LAM * symmetric-KL(seam decisions "
                         "via tap A vs tap B) on the same frames (0 = the P2 baseline recipe)")
    ap.add_argument("--qat", type=int, default=0,
                    help="P4 quantization-aware training: project the export's int8 group-N "
                         "grid after every step (0 = off; 16 = the proven rung)")
    ap.add_argument("--init", default=None, help="warm start from a previous shared student.pt")
    ap.add_argument("--deploy-tap", default=None,
                    help="adapter the checkpoint records for eval replay (default: l4-streaming)")
    ap.add_argument("--seed", type=int, default=0, help="training seed (comparisons need it fixed)")
    ap.add_argument("--distill-loss", choices=("soft", "mse"), default="soft",
                    help="teacher-head loss: soft = cross-entropy on teacher probs (default), "
                         "mse = probability matching (the A/B baseline)")
    ap.add_argument("--out", default=None, help="write student.pt + report.json + weights.json here")
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--window", type=int, default=250, help="training window in frames (20 s)")
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--selfcheck", action="store_true",
                    help="synthetic smoke: weighting rule, shard round-trip, loss falls")
    args = ap.parse_args()
    if args.selfcheck:
        selfcheck()
        sys.exit(0)
    if not args.tap:
        ap.error("need --tap ID=ROOT (one per registry adapter) or --selfcheck")
    tap_roots = {}
    for spec in args.tap:
        tap, _, root = spec.partition("=")
        if not root:
            ap.error(f"--tap wants ID=ROOT, got {spec!r}")
        adapter_by_id(tap)  # validate against the registry
        tap_roots[tap] = root
    ok, *_ = run(tap_roots, args.out, args.epochs, args.window, args.lr,
                 seed=args.seed, distill_loss=args.distill_loss, weights=args.weights,
                 init=args.init, deploy_tap=args.deploy_tap, val_split=args.val_split,
                 consistency=args.consistency, qat=args.qat)
    sys.exit(0 if ok else 1)
