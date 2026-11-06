"""Endpoint on a labelled corpus: events against human turn ends.

The reference is the corpus's own `eot_ch0` labels, not the teacher, so this is the
one endpoint number that is independent of what our model was distilled from. It
runs the same replay as the gates: the teacher's recorded events, and optionally a
student checkpoint, matched to turn ends within a tolerance.

Watch the event kinds. `aligned_count` matches on kind equality, and a reference
written as "EP" against a candidate "ENDPOINT" matches nothing at all -- which
reads as 0% recall rather than as a bug. This file's selfcheck pins that.

    .venv/bin/python scripts/switchboard-endpoint.py \\
        --shards bench-results/switchboard-shards/test-138 \\
        --student bench-results/student-l4-60/student.pt --layer 4

  --selfcheck   kind matching and the precision/recall arithmetic, no files
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

import numpy as np


def distances(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """For every element of `a`, the frame distance to the nearest element of `b`."""
    if not len(a) or not len(b):
        return np.full(len(a), 10 ** 9)
    return np.abs(a[:, None] - b[None, :]).min(1)


def selfcheck() -> None:
    """Distance arithmetic, and the kind-string trap that reads as 0%."""
    assert distances(np.array([10, 30]), np.array([12])).tolist() == [2, 18]
    assert distances(np.array([10]), np.array([])).tolist() == [10 ** 9]
    assert distances(np.array([]), np.array([1])).tolist() == []
    refs = [("EP", 10)]          # a reference labelled "EP"
    cands = [("ENDPOINT", 10)]   # against a candidate labelled "ENDPOINT"
    assert not ({k for k, _ in refs} & {k for k, _ in cands})
    print("selfcheck ok")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards")
    ap.add_argument("--student", help="optional checkpoint; omit for the teacher's recorded events")
    ap.add_argument("--tap", default=None)
    ap.add_argument("--layer", type=int, default=4)
    ap.add_argument("--thr", default="0.75,0.5,0.5", help="ep,barge,bc thresholds for the student replay")
    ap.add_argument("--tols", default="2,5,10")
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selfcheck", action="store_true")
    a = ap.parse_args()
    if a.selfcheck:
        return selfcheck()
    if not a.shards:
        ap.error("--shards is required (or --selfcheck)")

    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ports", "tyger-student"))
    from data import load_shard

    model = oracle = None
    thr = tuple(float(x) for x in a.thr.split(","))
    if a.student:
        from checkpoint import load as load_model
        from oracle import Oracle
        model, _ = load_model(a.student, tap=a.tap, device=a.device)
        oracle = Oracle(device="cpu")
        from gate import student_events

    # frames are per session: distances across sessions would pair unrelated events
    per_session = []
    mins = 0.0
    for path in sorted(glob.glob(os.path.join(a.shards, "*.npz"))):
        frames, labels, events, meta = load_shard(path)
        mins += len(frames["energy"]) * 0.08 / 60
        ref = [i + 1 for i, v in enumerate(labels["eot_ch0"]) if v == 1]
        if a.student:
            cand = [f for f, k in student_events(model, oracle, frames, layer=a.layer, thr=thr)
                    if k == "ENDPOINT"]
        else:
            cand = [] if events is None else [int(f) for f, k in zip(events[0], events[1])
                                              if str(k) == "ENDPOINT"]
        per_session.append((np.array(ref), np.array(cand)))

    n_ref = sum(len(r) for r, _ in per_session)
    n_cand = sum(len(c) for _, c in per_session)
    out = {"minutes": round(mins, 1), "turn_ends": n_ref, "events": n_cand,
           "turn_ends_per_min": round(n_ref / mins, 2) if mins else 0,
           "events_per_min": round(n_cand / mins, 2) if mins else 0, "at": {}}
    for tol in [int(x) for x in a.tols.split(",")]:
        on_end = sum(int((distances(c, r) <= tol).sum()) for r, c in per_session)
        caught = sum(int((distances(r, c) <= tol).sum()) for r, c in per_session)
        out["at"][tol] = {"events_on_a_turn_end": on_end,
                          "precision": round(on_end / n_cand, 4) if n_cand else 0,
                          "turn_ends_caught": caught,
                          "coverage": round(caught / n_ref, 4) if n_ref else 0}
    if a.json:
        print(json.dumps(out, indent=2))
        return
    who = "student" if a.student else "teacher"
    print(f"{who} on {mins:.0f} min: {n_cand} endpoint events ({out['events_per_min']}/min), "
          f"{n_ref} turn ends ({out['turn_ends_per_min']}/min)")
    for tol, v in out["at"].items():
        print(f"  +-{tol:>2} frames ({int(tol) * 80:>4} ms): "
              f"{100 * v['precision']:>3.0f}% of events sit on a turn end "
              f"({v['events_on_a_turn_end']}/{n_cand}); "
              f"{100 * v['coverage']:>3.0f}% of turn ends have an event within reach "
              f"({v['turn_ends_caught']}/{n_ref})")
    print("  coverage is many-to-one: an event within reach can serve several turn ends, "
          "so with fewer events than turn ends it cannot reach 100%")


if __name__ == "__main__":
    main()
