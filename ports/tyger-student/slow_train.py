"""Train and judge the P6 slow-tier decoders (issue #160).

Three shapes, same event set, same seed, same targets:

  fast-floor                 the fast seam's own answer at the event frame (the floor)
  z-gru                      cheap GRU heads over the trailing shared latent (shape A)
  state-transformer          tiny transformer over the serialized per-frame state (shape B)
  state-transformer-large    the capacity-scaling rung (2.2M params)

The reference is the teacher's 8-vector at the event frame; the event set is the
runtime-detectable trigger set from `slow_state.py` (VAD transitions + fast candidate
crossings), so "agreement vs the teacher" is classification against the teacher's own
frame decision, never accuracy (#129 guardrail). Per-axis thresholds are fitted on
train events and reported beside defaults; the live domain gets a leave-one-session-out
fit, because calibration is per model AND per domain (#145).

    .venv/bin/python ports/tyger-student/slow_train.py \
        --train bench-results/slow/train --val bench-results/slow/val \
        --live bench-results/slow/live --out bench-results/slow \
        --epochs 30 --seed 0

    .venv/bin/python ports/tyger-student/slow_train.py --selfcheck
"""
import argparse
import json
import os
import sys
import time

import numpy as np
import torch

import slow_model as sm
from slow_state import EVENT_KINDS, FAST_COLS, TEACHER_THRESHOLDS, iter_sessions, record
from train import auc

STATE_LABELS = sm.STATE_LABELS
AXES = ("endpoint", "barge", "backchannel")
EP_GRID = [round(0.50 + 0.05 * i, 2) for i in range(10)] + [0.9146]
BIN_GRID = [round(0.1 * i, 1) for i in range(1, 10)]


def load_dir(path, limit=0):
    """-> list of per-session tensor dicts (+ raw numpy teacher for thresholds)."""
    out = []
    for p, events, meta in iter_sessions(path):
        out.append({
            "path": p, "session_id": meta["session_id"],
            "z": torch.from_numpy(events["z"].astype(np.float32)),
            "fast": torch.from_numpy(events["fast"].astype(np.float32)),
            "energy": torch.from_numpy(events["energy"].astype(np.float32)),
            "prev_state": torch.from_numpy(events["prev_state"].astype(np.int64)),
            "mode": torch.from_numpy(events["mode"].astype(np.int8)),
            "activity": torch.from_numpy(events["activity"].astype(np.int8)),
            "kind": torch.from_numpy(events["kind"].astype(np.int64)),
            "frame": torch.from_numpy(events["frame"].astype(np.int64)),
            "teacher": torch.from_numpy(events["teacher"].astype(np.float32)),
            "commit": torch.from_numpy(events["commit"].astype(np.int64)),
        })
        if limit and len(out) >= limit:
            break
    if not out:
        sys.exit(f"no serialized sessions in {path}")
    return out


def cat_sessions(sessions):
    keys = ("z", "fast", "energy", "prev_state", "mode", "activity", "kind",
            "frame", "teacher", "commit")
    return {k: torch.cat([s[k] for s in sessions]) for k in keys}


def targets(teacher):
    """The record's training targets from the teacher's 8-vector."""
    state_t = torch.softmax(teacher[:, 0:4], dim=-1)
    conf = state_t.max(-1).values
    bins = torch.bucketize(conf, torch.tensor([1.0 / 3.0, 2.0 / 3.0]))
    return state_t, teacher[:, 4:8], bins


def loss_fn(model, batch):
    outs = sm.forward_state(model, batch)
    state_t, noul_t, bins = targets(batch["teacher"])
    loss = torch.nn.functional.cross_entropy(outs["state"], state_t)
    for i, axis in enumerate(("hazard", "barge", "backchannel", "endpoint")):
        loss = loss + torch.nn.functional.binary_cross_entropy_with_logits(
            outs[axis].squeeze(-1), noul_t[:, i])
    # the slow-tier judgment: did a turn commit within 400 ms of this event?
    loss = loss + torch.nn.functional.binary_cross_entropy_with_logits(
        outs["commit"].squeeze(-1), batch["commit"].float())
    loss = loss + torch.nn.functional.cross_entropy(outs["confidence"], bins)
    return loss / 7.0


@torch.no_grad()
def predict(model, batch, bs=512):
    model.eval()
    probs = {k: [] for k in ("state", "endpoint", "barge", "backchannel", "commit", "confidence")}
    n = len(batch["kind"])
    for s in range(0, n, bs):
        sl = {k: v[s:s + bs] for k, v in batch.items()}
        p = sm.probabilities(sm.forward_state(model, sl))
        for k in probs:
            probs[k].append(p[k].cpu())
    return {k: torch.cat(v) for k, v in probs.items()}


def fast_probs(batch):
    fast = batch["fast"][:, -1]  # the event frame is the window's last frame
    state = torch.softmax(fast[:, :4], dim=-1)
    conf = state.max(-1).values
    bins = torch.bucketize(conf, torch.tensor([1.0 / 3.0, 2.0 / 3.0]))
    bins = torch.nn.functional.one_hot(bins, 3).float()
    return {"state": state, "endpoint": fast[:, 7], "barge": fast[:, 5],
            "backchannel": fast[:, 6], "commit": fast[:, 7], "confidence": bins}


def labels(teacher, commit):
    """Teacher frame decisions: the rules' default thresholds, the confidence bin, and
    the pause-vs-completion event label (teacher ENDPOINT within the horizon)."""
    out = {axis: (teacher[:, FAST_COLS[axis]] >= TEACHER_THRESHOLDS[axis])
           for axis in AXES}
    state_t = torch.softmax(teacher[:, 0:4], dim=-1)
    out["state"] = state_t.argmax(-1)
    conf = state_t.max(-1).values
    out["confidence"] = torch.bucketize(conf, torch.tensor([1.0 / 3.0, 2.0 / 3.0]))
    out["commit"] = commit.bool()
    return out


def fit_threshold(prob, label, grid):
    best = (grid[0], float(((prob >= grid[0]) == label).float().mean()))
    for t in grid[1:]:
        a = float(((prob >= t) == label).float().mean())
        if a > best[1]:
            best = (t, a)
    return best[0]


def fit_thresholds(probs, teacher, commit):
    lab = labels(teacher, commit)
    axes = AXES + ("commit",)
    return {axis: fit_threshold(probs[axis], lab[axis],
                                EP_GRID if axis == "endpoint" else BIN_GRID)
            for axis in axes}


def metrics(probs, teacher, commit, thresholds=None):
    """Per-axis report: AUC (threshold-free), default-threshold agreement, fitted
    agreement, and the teacher's positive rate."""
    lab = labels(teacher, commit)
    out = {}
    for axis in AXES + ("commit",):
        p = probs[axis]
        default_t = TEACHER_THRESHOLDS.get(axis, 0.5)
        default = float(((p >= default_t) == lab[axis]).float().mean())
        thr = (thresholds or {}).get(axis, default_t)
        fitted = float(((p >= thr) == lab[axis]).float().mean())
        out[axis] = {"auc": auc(p.tolist(), lab[axis].tolist()),
                     "agreement_default": round(default, 4),
                     "agreement_fitted": round(fitted, 4), "threshold": thr,
                     "positive_rate": round(float(lab[axis].float().mean()), 4)}
    out["state"] = {"agreement": round(float((probs["state"].argmax(-1) == lab["state"])
                                            .float().mean()), 4)}
    out["confidence"] = {"agreement": round(float((probs["confidence"].argmax(-1)
                                                   == lab["confidence"]).float().mean()), 4)}
    return out


def loso_metrics(probs_by_session, teacher_by_session, commit_by_session, grid):
    """Leave-one-session-out threshold fit for a domain with no training split. Returns
    the held-out agreement for each axis (fit on the other sessions, judge this one)."""
    axes = AXES + ("commit",)
    hits = {a: 0 for a in axes}
    total = 0
    for i, (probs, teacher) in enumerate(zip(probs_by_session, teacher_by_session)):
        commit = commit_by_session[i]
        fit_p = {a: torch.cat([p[a] for j, p in enumerate(probs_by_session) if j != i])
                 for a in axes}
        fit_t = torch.cat([t for j, t in enumerate(teacher_by_session) if j != i])
        fit_c = torch.cat([c for j, c in enumerate(commit_by_session) if j != i])
        thrs = fit_thresholds(fit_p, fit_t, fit_c)
        m = metrics(probs, teacher, commit, thrs)
        for a in axes:
            hits[a] += round(m[a]["agreement_fitted"] * len(teacher))
        total += len(teacher)
    return {a: round(hits[a] / total, 4) for a in axes}, total


def pause_metrics(probs, teacher, commit, kind, thresholds=None):
    """The slow tier's stated job on the events it was added for: at a pause, does it
    judge commit-vs-hold better than the fast tier's p_end? (AUC + fitted agreement.)"""
    mask = kind == 0
    if not bool(mask.any()):
        return None
    sub = {k: v[mask] for k, v in probs.items()}
    m = metrics(sub, teacher[mask], commit[mask], thresholds)
    return {"events": int(mask.sum()), "endpoint": m["endpoint"], "commit": m["commit"]}


def train_one(arch, train_batch, epochs, lr, seed, log=print):
    torch.manual_seed(seed)
    np.random.seed(seed)
    model = sm.build(arch)
    opt = torch.optim.Adam(model.parameters(), lr=lr)
    n = len(train_batch["kind"])
    bs = 256
    first = last = None
    for ep in range(epochs):
        model.train()
        order = torch.randperm(n)
        total, steps = 0.0, 0
        for s in range(0, n, bs):
            idx = order[s:s + bs]
            batch = {k: v[idx] for k, v in train_batch.items()}
            loss = loss_fn(model, batch)
            opt.zero_grad()
            loss.backward()
            opt.step()
            total += float(loss.detach())
            steps += 1
        first = total / steps if first is None else first
        last = total / steps
        if (ep + 1) % max(1, epochs // 6) == 0 or ep == 0:
            log(f"    {arch} epoch {ep + 1}/{epochs}: loss {last:.5f}")
    return model, first, last


@torch.no_grad()
def latency_ms(model, batch, reps=200, warmup=20):
    model.eval()
    one = {k: v[:1] for k, v in batch.items()}
    for _ in range(warmup):
        sm.forward_state(model, one)
    wall, cpu = [], []
    for _ in range(reps):
        t0, c0 = time.perf_counter(), time.process_time()
        sm.forward_state(model, one)
        wall.append((time.perf_counter() - t0) * 1000.0)
        cpu.append((time.process_time() - c0) * 1000.0)
    wall, cpu = np.asarray(wall), np.asarray(cpu)
    return {"p50_ms": round(float(np.percentile(wall, 50)), 3),
            "p95_ms": round(float(np.percentile(wall, 95)), 3),
            "cpu_p50_ms": round(float(np.percentile(cpu, 50)), 3),
            "cpu_p95_ms": round(float(np.percentile(cpu, 95)), 3),
            "mean_ms": round(float(wall.mean()), 3), "reps": reps,
            "threads": torch.get_num_threads(),
            "loadavg": [round(x, 2) for x in os.getloadavg()]}


def state_bytes(batch):
    per = (batch["z"].shape[1] * 256 * 4 + batch["fast"].shape[1] * 8 * 4
           + batch["energy"].shape[1] * 4 + batch["prev_state"].shape[1] * 8
           + batch["mode"].shape[1] + batch["activity"].shape[1])
    return int(per)


def report_table(rows):
    hdr = ("model", "params", "MB fp32", "MB int8", "ep AUC", "ep agr", "barge AUC",
           "barge agr", "bc AUC", "bc agr", "commit AUC", "pause commit AUC",
           "state agr", "conf agr", "cpu p50 ms", "cpu p95 ms")
    lines = ["| " + " | ".join(hdr) + " |", "|" + "---|" * len(hdr)]
    for r in rows:
        lines.append("| " + " | ".join(str(x) for x in (
            r["model"], f"{r['params']:,}", f"{r['mb_fp32']:.2f}", f"{r['mb_int8']:.2f}",
            f"{r['endpoint']['auc']:.3f}", f"{r['endpoint']['agreement_fitted']:.3f}",
            f"{r['barge']['auc']:.3f}", f"{r['barge']['agreement_fitted']:.3f}",
            f"{r['backchannel']['auc']:.3f}", f"{r['backchannel']['agreement_fitted']:.3f}",
            f"{r['commit']['auc']:.3f}",
            f"{r['pause_commit']['auc']:.3f}" if r.get("pause_commit") else "-",
            f"{r['state']['agreement']:.3f}", f"{r['confidence']['agreement']:.3f}",
            f"{r['latency'].get('cpu_p50_ms', 0.0):.3f}",
            f"{r['latency'].get('cpu_p95_ms', 0.0):.3f}")) + " |")
    return "\n".join(lines)


def dump_records(model, arch, batch, path, n=24):
    probs = predict(model, batch)
    with open(path, "w") as f:
        for i in range(min(n, len(batch["kind"]))):
            answers = {a: float(probs[a][i]) for a in AXES + ("commit",)}
            answers["_mode"] = float(batch["mode"][i, -1])
            rec = record(probs["state"][i].numpy(),
                         answers,
                         batch["teacher"][i].numpy(),
                         "val",
                         int(batch["frame"][i]), EVENT_KINDS[int(batch["kind"][i])],
                         f"slow/{arch}", z_ref=f"state[#{i}]")
            f.write(json.dumps(rec) + "\n")


def selfcheck():
    torch.manual_seed(0)
    rng = np.random.default_rng(0)
    T, N = 25, 96
    batch = {
        "z": torch.randn(N, T, 256) * 0.1,
        "fast": torch.rand(N, T, 8),
        "energy": torch.rand(N, T) * 60 - 60,
        "prev_state": torch.randint(0, 5, (N, T)),
        "mode": torch.randint(0, 2, (N, T), dtype=torch.int8),
        "activity": (torch.rand(N, T) > 0.5).to(torch.int8),
        "kind": torch.randint(0, len(EVENT_KINDS), (N,)),
        "frame": torch.arange(N) + 30,
        "teacher": torch.rand(N, 8),
        "commit": (torch.rand(N) > 0.5).long(),
    }
    # make the target learnable: teacher is a deterministic function of the last z frame
    with torch.no_grad():
        h = batch["z"][:, -1]
        batch["teacher"][:, 0:4] = torch.nn.functional.one_hot(
            (h[:, 0] > 0).long() + (h[:, 1] > 0).long(), 4).float() * 4
        batch["teacher"][:, 4:8] = torch.sigmoid(h[:, :4])
    for arch in ("z-gru", "state-transformer"):
        model, first, last = train_one(arch, batch, epochs=6, lr=3e-3, seed=0, log=lambda *_: None)
        assert last < first, f"{arch} loss did not fall: {first} -> {last}"
        probs = predict(model, batch)
        assert probs["state"].shape == (N, 4)
        m = metrics(probs, batch["teacher"], batch["commit"],
                    fit_thresholds(probs, batch["teacher"], batch["commit"]))
        assert set(m) == {"endpoint", "barge", "backchannel", "commit", "state", "confidence"}
        lat = latency_ms(model, batch, reps=10, warmup=2)
        assert lat["p95_ms"] >= lat["p50_ms"] > 0
        p = f"/tmp/slow-selfcheck-{arch}.pt"
        sm.save(p, model)
        m2, _ = sm.load(p)
        assert sm.count_params(m2) == sm.count_params(model)
    print("slow_train selfcheck ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selfcheck", action="store_true")
    ap.add_argument("--train", default="bench-results/slow/train")
    ap.add_argument("--val", default="bench-results/slow/val")
    ap.add_argument("--live", default=None,
                    help="optional second domain (e.g. bench-results/slow/live); LOSO calibration")
    ap.add_argument("--out", default="bench-results/slow")
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--limit-train", type=int, default=0, help="debug: first N train sessions")
    ap.add_argument("--only", default="", help="comma-separated arches (default: all three)")
    ap.add_argument("--dump-records", type=int, default=0,
                    help="write N record JSONL files for the val events")
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--latency-only", action="store_true",
                    help="load --out/<arch>.pt and measure per-event forward only")
    args = ap.parse_args()
    if args.selfcheck:
        selfcheck()
        return

    torch.set_num_threads(args.threads)
    if args.latency_only:
        val_b = cat_sessions(load_dir(args.val))
        for arch in ("z-gru", "state-transformer", "state-transformer-large"):
            path = os.path.join(args.out, f"{arch}.pt")
            if not os.path.exists(path):
                continue
            model, _ = sm.load(path)
            print(arch, latency_ms(model, val_b), flush=True)
        return
    train_s = load_dir(args.train, args.limit_train)
    val_s = load_dir(args.val)
    live_s = load_dir(args.live) if args.live else []
    train_b = cat_sessions(train_s)
    val_b = cat_sessions(val_s)
    print(f"train: {len(train_s)} sessions / {len(train_b['kind'])} events; "
          f"val: {len(val_s)} / {len(val_b['kind'])}; live: {len(live_s)}", flush=True)
    print(f"state size per event: {state_bytes(train_b) / 1024:.1f} KiB, "
          f"trigger mix: " + ", ".join(f"{k}={int((train_b['kind'] == i).sum())}"
                                       for i, k in enumerate(EVENT_KINDS)), flush=True)

    orch = [a for a in ("z-gru", "state-transformer", "state-transformer-large")
            if not args.only or a in args.only.split(",")]

    # the fast seam's own answer at the same events — the floor
    fp = fast_probs(val_b)
    fast_thr = fit_thresholds(fast_probs(train_b), train_b["teacher"], train_b["commit"])
    fast_m = metrics(fp, val_b["teacher"], val_b["commit"], fast_thr)
    fast_pause = pause_metrics(fp, val_b["teacher"], val_b["commit"], val_b["kind"], fast_thr)
    rows = [dict(model="fast-floor", params=0, mb_fp32=0.0, mb_int8=0.0,
                 latency={"p50_ms": 0.0, "p95_ms": 0.0,
                          "cpu_p50_ms": 0.0, "cpu_p95_ms": 0.0},
                 pause_commit=(fast_pause or {}).get("commit"), **fast_m)]
    report = {"train_events": int(len(train_b["kind"])), "val_events": int(len(val_b["kind"])),
              "train_sessions": len(train_s), "val_sessions": len(val_s),
              "state_bytes_per_event": state_bytes(train_b),
              "teacher_positive_rate": {a: fast_m[a]["positive_rate"]
                                        for a in AXES + ("commit",)},
              "fast_floor": fast_m, "fast_floor_pause": fast_pause, "models": {}}

    for arch in orch:
        print(f"\n== {arch}", flush=True)
        model, first, last = train_one(arch, train_b, args.epochs, args.lr, args.seed)
        probs = predict(model, val_b)
        train_probs = predict(model, train_b)
        thr = fit_thresholds(train_probs, train_b["teacher"], train_b["commit"])  # fit on TRAIN, judge on val
        m = metrics(probs, val_b["teacher"], val_b["commit"], thr)
        lat = latency_ms(model, val_b)
        n_params = sm.count_params(model)
        pause = pause_metrics(probs, val_b["teacher"], val_b["commit"], val_b["kind"], thr)
        entry = {"model": arch, "params": n_params, "mb_fp32": n_params * 4 / 1e6,
                 "mb_int8": n_params / 1e6, "train_loss_first": round(first, 5),
                 "train_loss_last": round(last, 5), "thresholds": thr,
                 "pause_commit": (pause or {}).get("commit"),
                 "pause": pause, "latency": lat, **m}
        report["models"][arch] = entry
        rows.append(entry)
        if live_s:
            live_probs = [predict(model, cat_sessions([s])) for s in live_s]
            live_t = [s["teacher"] for s in live_s]
            live_c = [s["commit"] for s in live_s]
            lo, n_live = loso_metrics(live_probs, live_t, live_c, BIN_GRID)
            entry["live_loso"] = {"events": n_live, "agreement": lo}
            print(f"  live LOSO agreement: {lo} ({n_live} events)", flush=True)
        if args.dump_records:
            dump_records(model, arch, val_b, os.path.join(args.out, f"records-{arch}.jsonl"),
                         args.dump_records)
        sm.save(os.path.join(args.out, f"{arch}.pt"), model)

    # fast floor live LOSO too, for the same-domain comparison
    if live_s:
        fast_live = [fast_probs(cat_sessions([s])) for s in live_s]
        lo, n_live = loso_metrics(fast_live, [s["teacher"] for s in live_s],
                                  [s["commit"] for s in live_s], BIN_GRID)
        report["fast_floor_live_loso"] = {"events": n_live, "agreement": lo}
        print(f"\nfast-floor live LOSO agreement: {lo} ({n_live} events)")

    os.makedirs(args.out, exist_ok=True)
    table = report_table(rows)
    with open(os.path.join(args.out, "report.json"), "w") as f:
        json.dump(report, f, indent=2)
    with open(os.path.join(args.out, "report.md"), "w") as f:
        f.write("# P6 slow-tier decoders\n\n" + table + "\n")
    print("\n" + table)
    print(f"\nwrote {args.out}/report.json + report.md")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--selfcheck", action="store_true")
    args, _ = ap.parse_known_args()
    if args.selfcheck:
        selfcheck()
    else:
        main()
