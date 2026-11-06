"""Score a head at floor handoffs, with per-domain thresholds.

The head's *scale* does not transfer across domains while its *ranking* does, so an
absolute threshold is meaningless: `turn_grab` trained on the synthetic corpus
scores AUC 0.734 on Open Yap and fires 42 times in 80 minutes at 0.5. This reports
both views for one head over one domain:

  absolute   events at a fixed threshold
  percentile events at the Nth percentile of the background (non-handoff) frames
             in *this* domain -- the only threshold form that has moved between
             domains so far

and it prints the background percentile values themselves, so a threshold fitted
on one domain can be applied to another by hand (`--apply-from`).

    .venv/bin/python scripts/handoff-eval.py --shards <dir> --wavs <dir> \\
        --student <pt> --head turn_grab --percentiles 90,95,99

  --selfcheck   handoff matching, percentile and event arithmetic, no models
"""
from __future__ import annotations

import argparse
import glob
import importlib.util
import os
import sys

import numpy as np


def _mod(name: str, filename: str):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), filename)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def events_at(score: np.ndarray, thr: float, deb: int = 2) -> np.ndarray:
    """Frame indices where the score holds at or above `thr` for `deb` frames."""
    out, run = [], 0
    for i, v in enumerate(score >= thr):
        run = run + 1 if v else 0
        if run >= deb:
            out.append(i)
            run = 0
    return np.array(out, dtype=int)


def score_at(events: np.ndarray, wins: list[tuple[int, int]], tol: int) -> tuple[int, int]:
    """(events landing on a window, windows holding an event) within `tol` frames."""
    if not len(events) or not wins:
        return 0, 0
    starts = np.array([w[0] for w in wins])
    hit_ev = int((np.abs(events[:, None] - starts[None, :]).min(1) <= tol).sum())
    hit_win = int((np.abs(starts[:, None] - events[None, :]).min(1) <= tol).sum())
    return hit_ev, hit_win


def selfcheck() -> None:
    s = np.array([0, .6, .6, .1, 0, 0, .7, .7, 0])
    assert events_at(s, 0.5).tolist() == [2, 7], events_at(s, 0.5)
    assert events_at(s, 0.65).tolist() == [7]
    wins = [(2, 5), (20, 23)]
    assert score_at(np.array([3]), wins, 2) == (1, 1)          # event inside tolerance of window 0
    assert score_at(np.array([10]), wins, 2) == (0, 0)
    assert score_at(np.array([]), wins, 2) == (0, 0)
    # a percentile over background frames is what a per-domain threshold means
    bg = np.array([0.0, 0.1, 0.2, 0.3])
    assert float(np.percentile(bg, 95)) > 0.2
    print("selfcheck ok")


def replay(model, oracle, frames, layer: int, heads: tuple[str, ...]) -> dict[str, np.ndarray]:
    """Per-frame scores for the requested heads, with the rules' carried state."""
    import torch
    from data import pick_features
    from oracle import HOP_FRAMES
    hu_all, ha_all = pick_features(frames, layer)
    sess = oracle.EarsSession(0)
    hidden, last = None, None
    out = {h: [] for h in heads}
    with torch.no_grad():
        for f in range(len(frames["energy"])):
            mode = "speaking" if int(frames["mode"][f]) else "listen"
            if mode != last:
                if oracle.rules.switch_mode(sess, mode):
                    hidden = None
                last = mode
            hu = torch.from_numpy(hu_all[f:f + 1])[None]
            ha = torch.from_numpy(ha_all[f:f + 1])[None]
            act = torch.tensor([[float(frames["energy"][f])]])
            prev = torch.tensor([[int(sess.prev_state)]])
            outs, hidden = model(hu, ha, act, prev, hidden)
            eight = model.eight_vector(outs)[0, 0].numpy()
            for h in heads:
                if h == "yield":
                    out[h].append(float(eight[5]))
                elif h == "endpoint":
                    out[h].append(float(eight[7]))
                elif h == "state_speak":
                    out[h].append(float(np.exp(eight[:4])[2] / np.exp(eight[:4]).sum()))
                else:
                    out[h].append(float(torch.sigmoid(outs[h][0, 0, 0])))
            _ev, _fin, reset = oracle.rules.on_frame(sess, mode, eight, float(frames["energy"][f]),
                                                     left=3 - (f % HOP_FRAMES))
            if reset:
                hidden = None
    return {h: np.array(v) for h, v in out.items()}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards")
    ap.add_argument("--wavs")
    ap.add_argument("--student")
    ap.add_argument("--tap", default=None)
    ap.add_argument("--head", default="turn_grab")
    ap.add_argument("--layer", type=int, default=4)
    ap.add_argument("--tols", default="5")
    ap.add_argument("--percentiles", default="90,95,99")
    ap.add_argument("--absolute", default="0.3,0.5")
    ap.add_argument("--per-call", action="store_true",
                    help="fit the percentile inside each call instead of the pooled domain")
    ap.add_argument("--apply-from", type=float, default=None,
                    help="also report the given absolute threshold (e.g. a percentile from another domain)")
    ap.add_argument("--selfcheck", action="store_true")
    a = ap.parse_args()
    if a.selfcheck:
        return selfcheck()
    if not (a.shards and a.wavs and a.student):
        ap.error("--shards, --wavs and --student are required (or --selfcheck)")

    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ports", "tyger-student"))
    from data import load_shard
    from checkpoint import load as load_model
    from oracle import Oracle
    H = _mod("openyap_handoffs", "openyap-handoffs.py")

    model, _ = load_model(a.student, tap=a.tap, device="cpu")
    oracle = Oracle(device="cpu")
    heads = (a.head,) if a.head in ("yield", "endpoint", "state_speak") else (a.head,)

    per_call = []
    withtorch = None
    for wav in sorted(glob.glob(os.path.join(a.wavs, "*.wav"))):
        cid = os.path.basename(wav)[:-4]
        p = os.path.join(a.shards, f"live-{cid}.npz")
        if not os.path.exists(p):
            continue
        frames, _l, _e, _m = load_shard(p)
        caller, agent = H.energy(wav)
        T = min(len(frames["energy"]), len(caller), len(agent))
        score = replay(model, oracle, frames, a.layer, heads)[a.head][:T]
        wins = [(h["caller_on"], h["caller_off"]) for h in H.handoffs(caller[:T], agent[:T])]
        mask = np.zeros(T, bool)
        for s, e in wins:
            mask[max(0, s - 2):min(T, s + 9)] = True
        per_call.append({"cid": cid, "score": score, "wins": wins, "bg": score[~mask], "mins": T * 0.08 / 60})
    if not per_call:
        sys.exit("no overlapping sessions between --shards and --wavs")

    mins = sum(c["mins"] for c in per_call)
    nwins = sum(len(c["wins"]) for c in per_call)
    bg = np.concatenate([c["bg"] for c in per_call])
    print(f"{a.head} over {len(per_call)} calls, {mins:.0f} min, {nwins} handoffs")
    print(f"  background score: p50 {np.median(bg):.3f}  p90 {np.percentile(bg,90):.3f}  "
          f"p95 {np.percentile(bg,95):.3f}  p99 {np.percentile(bg,99):.3f}")

    tols = [int(x) for x in a.tols.split(",")]
    rows = []
    for thr in [float(x) for x in a.absolute.split(",")]:
        rows.append(("abs", thr))
    for q in [float(x) for x in a.percentiles.split(",")]:
        rows.append((f"p{q:g}", float(np.percentile(bg, q))))
    if a.apply_from is not None:
        rows.append(("applied", a.apply_from))

    print(f"\n  {'threshold':<12}{'events':>7}{'ev/min':>8}" + "".join(f"{'±'+str(t)+' caught':>13}{'prec':>7}" for t in tols))
    if a.per_call:
        for q in [float(x) for x in a.percentiles.split(",")]:
            ev = 0; hit_ev = hit_win = 0
            for c in per_call:
                thr = float(np.percentile(c["bg"], q)) if len(c["bg"]) else 1.0
                e = events_at(c["score"], thr)
                ev += len(e)
                a1, a2 = score_at(e, c["wins"], tols[0])
                hit_ev += a1; hit_win += a2
            print(f"  {'per-call p'+format(q,'g'):<12}{ev:>7}{ev/mins:>8.2f}"
                  f"{100*hit_win/max(nwins,1):>12.0f}%{100*hit_ev/max(ev,1):>6.0f}%")
    for label, thr in rows:
        ev = sum(int(len(events_at(c["score"], thr))) for c in per_call)
        line = f"  {label+' '+format(thr, '.3f'):<12}{ev:>7}{ev/mins:>8.2f}"
        for tol in tols:
            hit_ev = hit_win = 0
            for c in per_call:
                e = events_at(c["score"], thr)
                a1, a2 = score_at(e, c["wins"], tol)
                hit_ev += a1; hit_win += a2
            line += f"{100*hit_win/max(nwins,1):>12.0f}%{100*hit_ev/max(ev,1):>6.0f}%"
        print(line)


if __name__ == "__main__":
    main()
