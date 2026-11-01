"""Calibrate the rules' threshold knobs (ep/barge/bc) for one trained student against
the gate shards' recorded teacher events — the per-model trait fit the calibration
sweep proved necessary (bench-results/gate-calibration.md: optima are per-model and do
not transfer; thresholds recover +12..+20 pts of decision agreement).

Writes <student>.traits.json in the trait shape the runtime consumes (see
scripts/tyger-eval.py --traits): {"name", "decider": {ep_thr, barge_thr, bc_thr, ...}}.

    .venv/bin/python ports/tyger-student/calibrate.py --shards bench-results/student-shards/val \
        --student bench-results/student/student.pt [--feature-layer 15]

Staged search (coarse by design — the val split is small; refine only with more
sessions): ep grid, then barge, then bc, then one joint neighbor pass. Reports
default and calibrated agreement: default says how self-contained the model is,
calibrated is the product configuration.
"""
import argparse
import json
import os
import sys

import torch

from gate import aligned_count, student_events
from data import iter_shards
from model import Student
from oracle import Oracle
from registry import by_id

DEFAULTS = (0.9146, 0.5, 0.5)  # bundle defaults: the teacher's rules thresholds


def agreement(model, oracle, sessions, layer, thr, tol):
    same = total = 0
    for frames, ref in sessions:
        cand = student_events(model, oracle, frames, layer, thr)
        al, _, _ = aligned_count(ref, cand, tol)
        same += al
        total += max(len(ref), len(cand))
    return same / total if total else 1.0


def argbest(model, oracle, sessions, layer, tol, grid, idx, base):
    """Best value for knob `idx` over `grid`, others fixed at `base` -> (value, agree)."""
    best = (base[idx], agreement(model, oracle, sessions, layer, base, tol))
    for v in grid:
        thr = list(base)
        thr[idx] = v
        a = agreement(model, oracle, sessions, layer, thr, tol)
        if a > best[1]:
            best = (v, a)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", required=True, help="gate shard dir with recorded teacher events")
    ap.add_argument("--student", required=True)
    ap.add_argument("--feature-layer", type=int, default=15)
    ap.add_argument("--tol", type=int, default=2)
    ap.add_argument("--sessions", type=int, default=0, help="limit sessions (0 = all); for quick passes")
    ap.add_argument("--ep-grid", default="0.70,0.75,0.80,0.85,0.88,0.90,0.9146,0.93")
    ap.add_argument("--barge-grid", default="0.3,0.4,0.5,0.6")
    ap.add_argument("--bc-grid", default="0.3,0.4,0.5,0.6")
    ap.add_argument("--no-joint", action="store_true", help="skip the joint neighbor pass")
    ap.add_argument("--out", default=None, help="traits JSON (default: <student>.traits.json)")
    args = ap.parse_args()

    ckpt = torch.load(args.student, map_location="cpu")
    model = Student([by_id(i) for i in ckpt["heads"]], width=ckpt["width"], layers=ckpt["layers"])
    model.load_state_dict(ckpt["state_dict"])
    model.eval()
    oracle = Oracle(device="cpu")

    sessions = []
    for _p, frames, _labels, events, meta in iter_shards(args.shards):
        if events is None:
            print(f"  {meta['session_id'][:16]}… no teacher events, skipped", flush=True)
            continue
        sessions.append((frames, list(zip(events[0].tolist(), events[1].tolist()))))
        if args.sessions and len(sessions) >= args.sessions:
            break
    if not sessions:
        sys.exit("no usable shards")

    grids = ([float(x) for x in args.ep_grid.split(",")],
             [float(x) for x in args.barge_grid.split(",")],
             [float(x) for x in args.bc_grid.split(",")])
    base_agree = agreement(model, oracle, sessions, args.feature_layer, DEFAULTS, args.tol)
    print(f"default thresholds {DEFAULTS}: {base_agree:.2%} agreement ({len(sessions)} sessions)", flush=True)

    best = list(DEFAULTS)
    for idx, grid in enumerate(grids):
        v, a = argbest(model, oracle, sessions, args.feature_layer, args.tol, grid, idx, tuple(best))
        best[idx] = v
        print(f"  knob {['ep', 'barge', 'bc'][idx]} -> {v} ({a:.2%})", flush=True)
    if not args.no_joint:
        cur_agree = agreement(model, oracle, sessions, args.feature_layer, tuple(best), args.tol)
        for idx, grid in enumerate(grids):
            cur = grid.index(best[idx]) if best[idx] in grid else None
            if cur is None:
                continue
            for j in (cur - 1, cur + 1):
                if 0 <= j < len(grid):
                    thr = list(best)
                    thr[idx] = grid[j]
                    a = agreement(model, oracle, sessions, args.feature_layer, tuple(thr), args.tol)
                    if a > cur_agree:
                        best[idx] = grid[j]
                        cur_agree = a
    best_agree = agreement(model, oracle, sessions, args.feature_layer, tuple(best), args.tol)

    out = args.out or os.path.splitext(args.student)[0] + ".traits.json"
    traits = {"name": os.path.basename(os.path.splitext(args.student)[0]),
              "decider": {"ep_thr": best[0], "ep_deb": 2, "barge_thr": best[1], "barge_deb": 2,
                          "bc_thr": best[2], "bc_deb": 2, "bc_refractory": 15}}
    with open(out, "w") as f:
        json.dump(traits, f, indent=2)
    print(f"\ndefault {DEFAULTS}: {base_agree:.2%}  ->  calibrated {tuple(best)}: {best_agree:.2%}")
    print(f"wrote {out}")
    print("report BOTH numbers with any gate result: default = self-contained behavior, calibrated = product config")


if __name__ == "__main__":
    main()
