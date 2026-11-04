"""Decision gate: the student's own decisions vs the teacher's recorded events on the
gate shards. Each session is replayed through the student with its OWN rules feedback
(carried GRU state, EarsSession prev_state — the live semantics), and its events are
matched against the teacher events the shard recorded. The metric is parity7's:
greedy same-kind matching within ±--tol frames; PASS at ≥99% aligned of
max(ref, cand). This is the "judge on decisions" bar of the P1 brief — the per-head
score gates in train.py say the heads imitate; this says the calls would behave.

    .venv/bin/python ports/tyger-student/gate.py --shards bench-results/student-shards/val \
        --student bench-results/student/student.pt
"""
import argparse
import os
import sys

import numpy as np
import torch

from data import iter_shards, pick_features
from oracle import HOP_FRAMES, Oracle


def aligned_count(a, b, tol):
    """parity7's greedy same-kind matching within tol frames -> (matches, only_a, only_b)."""
    used = set()
    for fa, ka in a:
        for j, (fb, kb) in enumerate(b):
            if j not in used and ka == kb and abs(fa - fb) <= tol:
                used.add(j)
                break
    return len(used), len(a) - len(used), len(b) - len(used)


def student_events(model, oracle, frames, layer=15, thr=(0.9146, 0.5, 0.5), deb=(2, 2, 2)):
    """Replay one shard using its mode track (older shards default to listen-only)."""
    hu_all, ha_all = pick_features(frames, layer)
    sess = oracle.EarsSession(0, ep_thr=thr[0], ep_deb=deb[0], barge_thr=thr[1],
                              barge_deb=deb[1], bc_thr=thr[2], bc_deb=deb[2])
    hidden = None
    last_mode = None
    modes = frames.get("mode")
    events = []
    T = len(frames["energy"])
    with torch.no_grad():
        for f in range(T):
            mode = "speaking" if modes is not None and int(modes[f]) else "listen"
            if mode != last_mode:
                if oracle.rules.switch_mode(sess, mode):
                    hidden = None
                last_mode = mode
            hu = torch.from_numpy(hu_all[f : f + 1])[None]
            ha = torch.from_numpy(ha_all[f : f + 1])[None]
            act = torch.tensor([[float(frames["energy"][f])]])
            prev = torch.tensor([[int(sess.prev_state)]])  # the rules' state, live semantics
            outs, hidden = model(hu, ha, act, prev, hidden)
            out = model.eight_vector(outs)[0, 0].to(torch.float64).numpy()
            evs, _final, reset = oracle.rules.on_frame(
                sess, mode, out, float(frames["energy"][f]), left=3 - (f % HOP_FRAMES))
            if reset:
                hidden = None
            for e in evs:
                if e["kind"] != "FRAME":
                    events.append((f + 1, e["kind"]))  # parity7 counts frames 1-based
    return events


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", required=True, help="gate shard dir (featurize.py --split val)")
    ap.add_argument("--student", required=True, help="student.pt from train.py --out")
    ap.add_argument("--tap", default=None,
                    help="shared-latent checkpoints: which tap adapter to replay "
                         "(must match --feature-layer; default: the checkpoint's deploy tap)")
    ap.add_argument("--tol", type=int, default=2, help="alignment tolerance in frames")
    ap.add_argument("--feature-layer", type=int, default=15,
                    help="which recorded encoder layer the student reads (must match training)")
    ap.add_argument("--ep-thr", type=float, default=0.9146, help="rules threshold knobs for the replay")
    ap.add_argument("--barge-thr", type=float, default=0.5)
    ap.add_argument("--bc-thr", type=float, default=0.5)
    ap.add_argument("--ep-deb", type=int, default=2, help="rules debounce knobs (frames)")
    ap.add_argument("--barge-deb", type=int, default=2)
    ap.add_argument("--bc-deb", type=int, default=2)
    ap.add_argument("--min-agree", type=float, default=0.99, help="overall agreement to PASS")
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args()

    from checkpoint import load as load_model
    model, ckpt = load_model(args.student, tap=args.tap, device=args.device)
    heads = model.heads_spec
    oracle = Oracle(device="cpu")  # rules only; the student is its own chain here
    print(f"student: {args.student} ({ckpt.get('params', '?')} params, heads: {', '.join(h.id for h in heads)}), "
          f"thresholds ep/barge/bc = {args.ep_thr}/{args.barge_thr}/{args.bc_thr}", flush=True)

    same = total = 0
    n_sess = 0
    for path, frames, _labels, events, meta in iter_shards(args.shards):
        if events is None:
            print(f"  {meta['session_id'][:16]}… no recorded teacher events, skipped", flush=True)
            continue
        ref = list(zip(events[0].tolist(), events[1].tolist()))
        cand = student_events(model, oracle, frames, args.feature_layer,
                              thr=(args.ep_thr, args.barge_thr, args.bc_thr),
                              deb=(args.ep_deb, args.barge_deb, args.bc_deb))
        al, only_ref, only_cand = aligned_count(ref, cand, args.tol)
        denom = max(len(ref), len(cand))
        same += al
        total += denom
        n_sess += 1
        agree = al / denom if denom else 1.0
        print(f"  [{n_sess}] {meta['session_id'][:16]}… events ref/cand={len(ref)}/{len(cand)} "
              f"aligned={al} only_ref={only_ref} only_cand={only_cand} agree={agree:.1%}", flush=True)
    if not n_sess:
        sys.exit("no usable shards")
    overall = same / total if total else 1.0
    verdict = "PASS" if overall >= args.min_agree else "FAIL"
    print(f"\noverall agreement: {overall:.2%} ({same}/{total} events, {n_sess} sessions) — {verdict} "
          f"(bar: {args.min_agree:.0%})")
    sys.exit(0 if verdict == "PASS" else 1)


if __name__ == "__main__":
    main()
