"""Cross-checkpoint decision replay (#102): one tap gate's A↔B, but with a different
checkpoint on each side.

`tap_gate.py` holds the checkpoint fixed and swaps the feature source, which answers
"is this pass interchangeable for this adapter". This answers the other question the
refit has to answer — "does the *deployed* decision surface match the reference one"
— where the two sides differ in both features and adapter. No thresholds or rules
change: same `gate.student_events`, same same-kind ±tol matching as `tap_gate.py`.

Usage:
  .venv/bin/python ports/tyger-student/cross_gate.py \
      --a-student pre.pt  --a-shards .../tap4-shards/val \
      --b-student refit.pt --b-shards .../tap-shipping/val --label "refit@42 vs pre@56"
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from checkpoint import load as load_model  # noqa: E402
from data import iter_shards  # noqa: E402
from gate import aligned_count, student_events  # noqa: E402
from oracle import Oracle  # noqa: E402


def events(student, tap, shards, thr, layer):
    model, _ckpt = load_model(student, tap=tap)
    oracle = Oracle(device="cpu")
    out = {}
    for _p, frames, _labels, _ev, meta in iter_shards(shards):
        out[meta["session_id"]] = student_events(model, oracle, frames, layer, thr=thr)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a-student", required=True)
    ap.add_argument("--a-shards", required=True)
    ap.add_argument("--b-student", required=True)
    ap.add_argument("--b-shards", required=True)
    ap.add_argument("--tap", default="l4-streaming")
    ap.add_argument("--feature-layer", type=int, default=15)
    ap.add_argument("--tol", type=int, default=2)
    ap.add_argument("--ep-thr", type=float, default=0.9146)
    ap.add_argument("--barge-thr", type=float, default=0.5)
    ap.add_argument("--bc-thr", type=float, default=0.5)
    ap.add_argument("--label", default="A vs B")
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    thr = (args.ep_thr, args.barge_thr, args.bc_thr)
    a = events(args.a_student, args.tap, args.a_shards, thr, args.feature_layer)
    b = events(args.b_student, args.tap, args.b_shards, thr, args.feature_layer)
    common = [s for s in a if s in b]
    if not common:
        sys.exit("no shared session ids between the two shard dirs")
    same = total = 0
    for sid in common:
        al, only_a, only_b = aligned_count(a[sid], b[sid], args.tol)
        total += max(len(a[sid]), len(b[sid]))
        same += al
        print(f"  {sid[:16]}…  events a/b {len(a[sid]):3d}/{len(b[sid]):3d}  aligned {al:3d}  "
              f"only_a {only_a} only_b {only_b}", flush=True)
    rec = {"label": args.label, "sessions": len(common), "aligned": same,
           "events": total, "agree": round(same / total, 4), "tol": args.tol}
    print(f"{args.label}: {same}/{total} = {same/total:.2%} (±{args.tol} frames)")
    if args.json:
        Path(args.json).write_text(json.dumps(rec, indent=2) + "\n")


if __name__ == "__main__":
    main()
