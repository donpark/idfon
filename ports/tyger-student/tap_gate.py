"""The tap-swap gate (#102, epic #132's last mile): does moving the decision model
from one feature source to another change its decisions?

The question is not "is the model good" (that is `gate.py` vs the teacher) but "is
this tap interchangeable" — so ONE checkpoint is replayed twice over the same
recorded sessions, once per tap source, with the same rules and carried state:

  side A  the reference tap      e.g. the windowed re-encode the model was trained on
  side B  the candidate tap      e.g. the ASR's cache-aware streaming tap

and the report is (a) feature drift per ear per frame, (b) the event agreement
A↔B (parity7's same-kind ±tol matching — the interchangeability number, bar ≥99%),
(c) each side's agreement against the teacher events the shards recorded
(context, not the gate).

Usage:
  .venv/bin/python ports/tyger-student/tap_gate.py \
      --student bench-results/shared-consistent-l03/student.pt --tap l15-windowed \
      --shards-a /Users/don/dev/idfon/bench-results/student-shards/val \
      --shards-b bench-results/l15-stream/val [--tol 2] [--sessions N]
Output: a table on stdout; `--json` writes the same record.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from checkpoint import load as load_model  # noqa: E402
from data import iter_shards  # noqa: E402
from gate import aligned_count, student_events  # noqa: E402
from oracle import Oracle  # noqa: E402


def cosine_rel(a, b):
    """Per-frame cosine similarity and relative L2 between two [T, D] feature sets."""
    a = np.asarray(a, np.float64)
    b = np.asarray(b, np.float64)
    na, nb = np.linalg.norm(a, axis=1), np.linalg.norm(b, axis=1)
    cos = (a * b).sum(1) / np.maximum(na * nb, 1e-12)
    rel = np.linalg.norm(a - b, axis=1) / np.maximum(nb, 1e-12)
    return cos, rel


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--student", required=True)
    ap.add_argument("--tap", default=None, help="shared checkpoints: the adapter to replay on BOTH sides")
    ap.add_argument("--shards-a", required=True, help="reference tap shards (the one the model was trained on)")
    ap.add_argument("--shards-b", required=True, help="candidate tap shards (same sessions)")
    ap.add_argument("--feature-layer", type=int, default=15,
                    help="shard key convention: 15 = canonical hu/ha; else hu_l{K}/ha_l{K}")
    ap.add_argument("--tol", type=int, default=2, help="same-kind match tolerance, frames")
    ap.add_argument("--sessions", type=int, default=0, help="limit paired sessions (0 = all)")
    ap.add_argument("--frames", type=int, default=0,
                    help="trim each session to the first N frames (0 = all); matches a shorter "
                         "earlier sample so rows stay comparable")
    ap.add_argument("--ep-thr", type=float, default=0.9146)
    ap.add_argument("--barge-thr", type=float, default=0.5)
    ap.add_argument("--bc-thr", type=float, default=0.5)
    ap.add_argument("--json", default=None, help="write the record here")
    args = ap.parse_args()

    model, ckpt = load_model(args.student, tap=args.tap)
    oracle = Oracle(device="cpu")  # rules only
    thr = (args.ep_thr, args.barge_thr, args.bc_thr)

    b_by_sid = {m["session_id"]: (f, e) for _p, f, _l, e, m in iter_shards(args.shards_b)}
    rows, drift = [], {"cos": [], "rel": []}
    same = total = 0
    a_teacher = b_teacher = 0
    for _p, fa, _la, ea, ma in iter_shards(args.shards_a):
        sid = ma["session_id"]
        if sid not in b_by_sid:
            continue
        fb, eb = b_by_sid[sid]
        n = min(len(fa["energy"]), len(fb["energy"]))
        if args.frames:
            n = min(n, args.frames)
        fa = {k: (v[:n] if isinstance(v, np.ndarray) else v) for k, v in fa.items()}
        fb = {k: (v[:n] if isinstance(v, np.ndarray) else v) for k, v in fb.items()}
        for ear in ("hu", "ha"):
            cos, rel = cosine_rel(fa[ear], fb[ear])
            drift["cos"].append(cos)
            drift["rel"].append(rel)
        ev_a = student_events(model, oracle, fa, args.feature_layer, thr=thr)
        ev_b = student_events(model, oracle, fb, args.feature_layer, thr=thr)
        al, only_a, only_b = aligned_count(ev_a, ev_b, args.tol)
        denom = max(len(ev_a), len(ev_b))
        same += al
        total += denom
        ta = tb = 0
        if ea is not None:
            ref = list(zip(ea[0].tolist(), ea[1].tolist()))
            a_teacher += aligned_count(ref, ev_a, args.tol)[0]
            ta = aligned_count(ref, ev_a, args.tol)[0]
            b_teacher += aligned_count(ref, ev_b, args.tol)[0]
            tb = aligned_count(ref, ev_b, args.tol)[0]
        rows.append({"session": sid, "frames": n,
                     "events_a": len(ev_a), "events_b": len(ev_b), "aligned": al,
                     "agree": round(al / denom if denom else 1.0, 4),
                     "only_a": only_a, "only_b": only_b,
                     "a_vs_teacher": ta, "b_vs_teacher": tb,
                     "teacher_events": len(ea[0]) if ea is not None else None})
        print(f"  {sid[:16]}… {n:5d} frames  events a/b {len(ev_a):3d}/{len(ev_b):3d}  "
              f"aligned {al:3d}  agree {rows[-1]['agree']:.1%}  "
              f"only_a {only_a} only_b {only_b}  vs teacher {ta}/{tb}", flush=True)
        if args.sessions and len(rows) >= args.sessions:
            break

    if not rows:
        sys.exit("no paired sessions — do the two shard dirs hold the same session ids?")
    cos = np.concatenate(drift["cos"])
    rel = np.concatenate(drift["rel"])
    agree = same / total if total else 1.0
    rec = {"student": args.student, "tap": args.tap,
           "shards_a": args.shards_a, "shards_b": args.shards_b,
           "tol": args.tol, "sessions": rows, "frames": int(len(cos)),
           "feature_drift": {"cos_p50": float(np.median(cos)), "cos_p05": float(np.percentile(cos, 5)),
                             "rel_p50": float(np.median(rel)), "rel_p95": float(np.percentile(rel, 95))},
           "decision_agreement": round(agree, 4),
           "events": total, "aligned": same,
           "teacher_agree": {"a": a_teacher, "b": b_teacher},
           "verdict": "PASS" if agree >= 0.99 else "FAIL"}
    print(f"\nfeature drift: cos p50 {rec['feature_drift']['cos_p50']:.4f} "
          f"(p05 {rec['feature_drift']['cos_p05']:.4f}), rel L2 p50 {rec['feature_drift']['rel_p50']:.3f} "
          f"(p95 {rec['feature_drift']['rel_p95']:.3f}) over {rec['frames']} frames")
    print(f"decision agreement A↔B: {agree:.2%} ({same}/{total} events, ±{args.tol} frames) "
          f"— {rec['verdict']} (bar 99%)")
    if args.json:
        Path(args.json).write_text(json.dumps(rec, indent=2, default=float) + "\n")
    raise SystemExit(0 if rec["verdict"] == "PASS" else 1)


if __name__ == "__main__":
    main()
