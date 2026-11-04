"""Product-metric gate: the distilled student's decisions vs the teacher's on the SAME
axes the tyger model card and the P1 brief score (docs/voice-decision-model.md) —
endpoint latency / early cut-ins / misses, barge catch-640ms / false fires, backchannel
precision / recall — instead of gate.py's frame-exact event identity (that bar is
calibrated for same-weights ports; for a distilled student it mostly measures
structural noise). Metric definitions are exact ports of scripts/tyger-eval.py
(sweep / bc_score / barge_sweep / floor_series); both sides are judged against the
same corpus labels, on the same session.

Events come from two sources: the shard's recorded teacher events (data.py:
ev_frames/ev_kinds, frames 1-based) and gate.py's student_events replay (same rules
feedback semantics — carried GRU state, EarsSession prev_state — honoring the
threshold/debounce knobs). Barge cannot come from events: rules.py only fires BARGE in
mode "speaking", which neither replay enters — so both sides' barge metrics threshold
the yield-head stream at --barge-thr (teacher: the shard's recorded 8-vector col 5,
student: the replay's), exactly tyger-eval's barge_sweep. --barge-deb rides through to
the rules but only debounces the speaking path, which the replay never enters.

One deliberate deviation from tyger-eval's literal text: its interrupting-onset test
`(bot_ch0 == 1) & (floor == 2)` is dead code (floor_series consumes the onset frame's
bot before assigning floor[f], so floor there is 1 or 0, never 2 — 0 onsets on any
input). Onsets are therefore tested against the PRE-onset floor (floor[f-1] == 2):
ch0 begins a turn while ch1 held the floor — the definition the words mean.

    .venv/bin/python ports/tyger-student/harness.py --shards bench-results/student-shards/val \
        --student bench-results/student/student.pt
"""
import argparse
import glob
import os
import sys

import numpy as np
import torch

from data import load_shard
from gate import student_events
from oracle import FRAME_MS, Oracle

FRAME_S = FRAME_MS / 1000
BARGE_WINDOW = 8   # 640 ms at 80 ms frames: tyger-eval's "caught within" window
BC_WINDOW = 8
BC_REFRACTORY = 15


def floor_series(lab, T):
    """Who holds the floor per frame (0: none, 1: ch0, 2: ch1): last bot without its eot.
    Ported exactly from scripts/tyger-eval.py."""
    floor = np.zeros(T, np.int8)
    cur = 0
    for f in range(T):
        if lab["bot_ch0"][f]:
            cur = 1
        elif lab["bot_ch1"][f]:
            cur = 2
        if lab["eot_ch0"][f] and cur == 1:
            cur = 0
        if lab["eot_ch1"][f] and cur == 2:
            cur = 0
        floor[f] = cur
    return floor


def sweep(ends, eot_s, horizon_s=1.2):
    """Ground-truth turn ends -> (latencies, early, miss) for a list of fire times (s).
    Ported exactly from scripts/tyger-eval.py."""
    lat, early, miss = [], 0, 0
    for f in eot_s:
        first = next((t for t in ends if f - 1.6 <= t < f), None)
        if first is not None:
            early += 1
            continue
        first = next((t for t in ends if f <= t <= f + horizon_s), None)
        if first is None:
            miss += 1
        else:
            lat.append(first - f)
    return lat, early, miss


def bc_score(fires_frames, bc_frames, window=BC_WINDOW, refractory=BC_REFRACTORY):
    """Ported exactly from scripts/tyger-eval.py."""
    kept = []
    for f in fires_frames:
        if not kept or f - kept[-1] >= refractory:
            kept.append(f)
    hits = sum(1 for f in kept if any(abs(f - b) <= window for b in bc_frames))
    matched = sum(1 for b in bc_frames if any(abs(f - b) <= window for f in kept))
    return {"fires": len(kept), "hits": hits,
            "precision": round(hits / len(kept), 2) if kept else None,
            "recall": round(matched / len(bc_frames), 2) if len(bc_frames) else None}


def barge_sweep(run, bot_int):
    """tyger-eval's barge_sweep block for one threshold series: catch = a score>=thr frame
    inside [onset, onset+8); false fires = rising-edge crossings outside every such window.
    catch is None without onsets; false fires stay meaningful (every crossing is spurious)."""
    L = len(run)
    caught = sum(1 for b in bot_int if run[b : b + BARGE_WINDOW].any())
    crossings = [f for f in range(1, L) if run[f] and not run[f - 1]]
    false = sum(1 for f in crossings if not any(b <= f < b + BARGE_WINDOW for b in bot_int))
    return {"catch_640ms": round(caught / len(bot_int), 2) if len(bot_int) else None,
            "false_fires": false}


class ScoreTap:
    """Wrap the student so gate.student_events' replay also records each frame's 8-vector
    — the barge axis needs the yield stream and the response-mode replay emits no BARGE
    events. Same tensors in/out; only side effect is the recording."""

    def __init__(self, model):
        self.model = model
        self.scores = []

    def __call__(self, hu, ha, act, prev, hidden):
        return self.model(hu, ha, act, prev, hidden)

    def eight_vector(self, outs):
        v = self.model.eight_vector(outs)
        self.scores.append(v[0, 0].detach().to(torch.float64).numpy())
        return v


def event_fires(ev, kind):
    """Event frames of one kind, 1-based -> 0-based (the label grid tyger-eval scores on)."""
    return [int(f) - 1 for f, k in ev if k == kind]


def source_metrics(ev, yield_stream, eot_s, bot_int, bc_frames, barge_thr):
    """One side's product metrics: events for endpoint/backchannel, yield stream for barge."""
    lat, early, miss = sweep([f * FRAME_S for f in event_fires(ev, "ENDPOINT")], eot_s)
    out = {"endpoint": {"latency_med": round(float(np.median(lat)), 2) if lat else None,
                        "early": early, "miss": miss}}
    out["barge"] = barge_sweep(yield_stream >= barge_thr, bot_int)
    out["bc"] = bc_score(event_fires(ev, "BACKCHANNEL"), bc_frames) if len(bc_frames) else None
    return out


# table columns: (header, decimals) — counts (early/miss/false) print as ints
HDR = ("ep_lat_s", "early", "miss", "catch640", "false", "bc_prec", "bc_rec")
DEC = (2, 0, 0, 2, 0, 2, 2)
COUNTS = (1, 2, 4)


def flat(m):
    return [m["endpoint"]["latency_med"], m["endpoint"]["early"], m["endpoint"]["miss"],
            m["barge"]["catch_640ms"] if m["barge"] else None,
            m["barge"]["false_fires"] if m["barge"] else None,
            m["bc"]["precision"] if m["bc"] else None,
            m["bc"]["recall"] if m["bc"] else None]


def cell(v, i, signed=False):
    if v is None:
        return "-"
    if i in COUNTS:
        return f"{v:+d}" if signed else f"{v:d}"
    return f"{v:+.{DEC[i]}f}" if signed else f"{v:.{DEC[i]}f}"


def show(t, s):
    print(f"  {'source':<9}" + "".join(f"{h:>10}" for h in HDR))
    for name, row, signed in (("teacher", t, False), ("student", s, False),
                              ("delta", [s[i] - t[i] if s[i] is not None and t[i] is not None else None
                                         for i in range(len(HDR))], True)):
        print(f"  {name:<9}" + "".join(f"{cell(v, i, signed):>10}" for i, v in enumerate(row)))


def agg(rows):
    """Aggregate like tyger-eval's trait summary: mean of per-session medians/ratios
    (skipping Nones), counts summed."""
    out = []
    for i, col in enumerate(zip(*rows)):
        vals = [v for v in col if v is not None]
        out.append(sum(vals) if i in COUNTS and vals else
                   round(sum(vals) / len(vals), 2) if vals else None)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", required=True, help="gate shard dir (featurize.py --split val)")
    ap.add_argument("--student", required=True, help="student.pt from train.py --out")
    ap.add_argument("--tap", default=None,
                    help="shared-latent checkpoints: which tap adapter to replay "
                         "(must match --feature-layer; default: the checkpoint's deploy tap)")
    ap.add_argument("--temp", type=float, default=1.0,
                    help="pre-seam temperature (calibrate.py --temp-grid fit; 1.0 = off)")
    ap.add_argument("--feature-layer", type=int, default=15,
                    help="which recorded encoder layer the student reads (must match training)")
    ap.add_argument("--ep-thr", type=float, default=0.9146, help="rules threshold knobs for the replay")
    ap.add_argument("--barge-thr", type=float, default=0.5)
    ap.add_argument("--bc-thr", type=float, default=0.5)
    ap.add_argument("--ep-deb", type=int, default=2, help="rules debounce knobs (frames)")
    ap.add_argument("--barge-deb", type=int, default=2)
    ap.add_argument("--bc-deb", type=int, default=2)
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args()

    # snapshot: other workers append to the shard dir concurrently
    paths = sorted(glob.glob(os.path.join(args.shards, "*.npz")))
    print(f"shards: {len(paths)} session(s) snapshotted in {args.shards}", flush=True)
    if not paths:
        sys.exit("no shards")

    from checkpoint import TempScaled, load as load_model
    model, ckpt = load_model(args.student, tap=args.tap, device=args.device)
    if args.temp != 1.0:
        model = TempScaled(model, args.temp)
    heads = model.heads_spec
    oracle = Oracle(device="cpu")  # rules only; the student is its own chain here
    print(f"student: {args.student} ({ckpt.get('params', '?')} params, heads: {', '.join(h.id for h in heads)}), "
          f"thresholds ep/barge/bc = {args.ep_thr}/{args.barge_thr}/{args.bc_thr}, "
          f"debounce ep/barge/bc = {args.ep_deb}/{args.barge_deb}/{args.bc_deb}", flush=True)

    t_rows, s_rows, totals = [], [], {"eot": 0, "onsets": 0, "bc": 0}
    used = 0
    for path in paths:
        frames, labels, events, meta = load_shard(path)
        if events is None:
            print(f"  {meta['session_id'][:16]}… no recorded teacher events, skipped", flush=True)
            continue
        T = len(frames["energy"])
        eot_s = (np.flatnonzero(labels["eot_ch0"]) * FRAME_S).tolist()
        bc_frames = np.flatnonzero(labels["bc_ch0"])
        floor = floor_series(labels, T)
        # tyger-eval's literal `(bot_ch0 == 1) & (floor == 2)` is dead code (floor[f] is
        # already 1 at the onset frame); the onset fires where ch1 HELD the floor going in.
        floor_pre = np.concatenate([[0], floor[:-1]])
        bot_int = np.flatnonzero((labels["bot_ch0"] == 1) & (floor_pre == 2))
        teacher_ev = [(int(f), str(k)) for f, k in zip(events[0].tolist(), events[1].tolist())]

        tap = ScoreTap(model)
        student_ev = student_events(tap, oracle, frames, args.feature_layer,
                                    thr=(args.ep_thr, args.barge_thr, args.bc_thr),
                                    deb=(args.ep_deb, args.barge_deb, args.bc_deb))
        t = source_metrics(teacher_ev, frames["teacher"][:, 5], eot_s, bot_int, bc_frames, args.barge_thr)
        s = source_metrics(student_ev, np.stack(tap.scores)[:, 5], eot_s, bot_int, bc_frames, args.barge_thr)
        used += 1
        totals["eot"] += len(eot_s)
        totals["onsets"] += len(bot_int)
        totals["bc"] += len(bc_frames)
        print(f"\n[{used}] {meta['session_id'][:16]}… {T} frames ({T * FRAME_S:.1f}s)  "
              f"eot={len(eot_s)} onsets={len(bot_int)} bc={len(bc_frames)}", flush=True)
        show(flat(t), flat(s))
        t_rows.append(flat(t))
        s_rows.append(flat(s))

    if not used:
        sys.exit("no usable shards")
    print(f"\n== aggregate over {used} session(s) "
          f"(eot={totals['eot']} onsets={totals['onsets']} bc={totals['bc']}) "
          f"— early/miss/false are sums, the rest means ==")
    ta, sa = agg(t_rows), agg(s_rows)
    show(ta, sa)
    print(f"\nused {used} of {len(paths)} snapshotted session(s)")


if __name__ == "__main__":
    main()
