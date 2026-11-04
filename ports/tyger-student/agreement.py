"""Cross-geometry decision agreement (epic #132 P5): would the two tap paths make
the SAME calls? Replays two students on the same sessions — model A from shard set A
(e.g. the parakeet adapter on parakeet tap shards), model B from shard set B (the
Nemotron-tap geometry, e.g. shared-consistent-l03 at l15-windowed on student-shards)
— through the same live rules feedback (gate.py's replay), and reports three event
agreements per session plus overall: A vs teacher, B vs teacher, and A vs B (the
portability metric: interchangeability behind the unchanged seam). parity7 matching
(gate.aligned_count), frames 1-based.

    .venv/bin/python ports/tyger-student/agreement.py \
        --shards-a bench-results/parakeet-shards/val --student-a bench-results/shared-parakeet/student.pt \
        --shards-b /Users/don/dev/idfon/bench-results/student-shards/val \
        --student-b bench-results/shared-consistent-l03/student.pt --tap-b l15-windowed
"""
import argparse
import os
import sys

import numpy as np

from data import iter_shards
from gate import aligned_count, student_events
from oracle import Oracle


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards-a", required=True, help="tap shard dir for model A (with teacher events)")
    ap.add_argument("--student-a", required=True)
    ap.add_argument("--tap-a", default=None, help="shared checkpoints: adapter to replay (default: deploy tap)")
    ap.add_argument("--temp-a", type=float, default=1.0)
    ap.add_argument("--shards-b", required=True, help="tap shard dir for model B (same sessions)")
    ap.add_argument("--student-b", required=True)
    ap.add_argument("--tap-b", default=None)
    ap.add_argument("--temp-b", type=float, default=1.0)
    ap.add_argument("--tol", type=int, default=2, help="alignment tolerance in frames")
    ap.add_argument("--ep-thr", type=float, default=0.9146)
    ap.add_argument("--barge-thr", type=float, default=0.5)
    ap.add_argument("--bc-thr", type=float, default=0.5)
    ap.add_argument("--ep-deb", type=int, default=2)
    ap.add_argument("--barge-deb", type=int, default=2)
    ap.add_argument("--bc-deb", type=int, default=2)
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args()

    from checkpoint import TempScaled, load as load_model
    ma, _ = load_model(args.student_a, tap=args.tap_a, device=args.device)
    mb, _ = load_model(args.student_b, tap=args.tap_b, device=args.device)
    if args.temp_a != 1.0:
        ma = TempScaled(ma, args.temp_a)
    if args.temp_b != 1.0:
        mb = TempScaled(mb, args.temp_b)
    oracle = Oracle(device="cpu")  # rules only; each student is its own chain
    thr = (args.ep_thr, args.barge_thr, args.bc_thr)
    deb = (args.ep_deb, args.barge_deb, args.bc_deb)

    shard_b = {os.path.splitext(os.path.basename(p))[0]: f
               for p, f, _l, _e, _m in iter_shards(args.shards_b)}
    if not shard_b:
        sys.exit(f"no shards in {args.shards_b}")
    hits = {k: [0, 0] for k in ("a_teacher", "b_teacher", "a_b")}  # aligned, denom
    n = 0
    for path, frames, _labels, events, meta in iter_shards(args.shards_a):
        sid = meta["session_id"]
        if sid not in shard_b:
            continue
        if events is None:
            print(f"  {sid[:16]}… no recorded teacher events, skipped", flush=True)
            continue
        ref = list(zip(events[0].tolist(), events[1].tolist()))
        ev_a = student_events(ma, oracle, frames, 15, thr, deb)
        ev_b = student_events(mb, oracle, shard_b[sid], 15, thr, deb)
        n += 1
        line = []
        for key, x, y in (("a_teacher", ev_a, ref), ("b_teacher", ev_b, ref), ("a_b", ev_a, ev_b)):
            al, _oa, _ob = aligned_count(x, y, args.tol)
            denom = max(len(x), len(y))
            hits[key][0] += al
            hits[key][1] += denom
            line.append(f"{key}={al / denom if denom else 1.0:.1%}")
        print(f"  [{n}] {sid[:16]}… " + " ".join(line), flush=True)
    if not n:
        sys.exit("no matched sessions")
    print(f"\n{n} sessions, tolerance ±{args.tol} frames:")
    for key in ("a_teacher", "b_teacher", "a_b"):
        al, denom = hits[key]
        print(f"  {key:<10} {al / denom if denom else 1.0:.2%} ({al}/{denom} events)")


if __name__ == "__main__":
    main()
