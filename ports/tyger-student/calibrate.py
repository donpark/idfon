"""Calibrate the rules' threshold knobs (ep/barge/bc) for one trained student against
the gate shards' recorded teacher events — the per-model trait fit the calibration
sweep proved necessary (bench-results/gate-calibration.md: optima are per-model and do
not transfer; thresholds recover +12..+20 pts of decision agreement).

With `--temp-grid` (epic #132 P4, the Kev-style per-checkpoint fit) a pre-seam
**temperature** is fitted per adapter first: one scalar dividing the decision logits
before the rules read them (model-side only; `checkpoint.TempScaled`). Two objectives
are both fitted and reported — NLL-to-teacher (state CE + noul BCE over the fit
frames, classic temperature scaling) and agreement-optimal (temperature as a staged
knob above the threshold search). The report shows the four configurations: default
triple (T=1), thresholds-only, T-only, T+thresholds.

Writes <student>.traits.json in the trait shape the runtime consumes (see
scripts/tyger-eval.py --traits): {"name", "decider": {ep_thr, barge_thr, bc_thr, ...}},
plus "temperature" when fitted (additive — consumers that ignore it keep working).

    .venv/bin/python ports/tyger-student/calibrate.py --shards bench-results/student-shards/val \
        --student bench-results/student/student.pt [--feature-layer 15] [--temp-grid 0.8,…,1.25]

Staged search (coarse by design — the val split is small; refine only with more
sessions): temp grid, ep grid, then barge, then bc, then one joint neighbor pass.
Reports default and calibrated agreement: default says how self-contained the model is,
calibrated is the product configuration.
"""
import argparse
import json
import os
import sys

from checkpoint import TempScaled, load as load_model
from gate import aligned_count, student_events
from data import iter_shards
from oracle import Oracle
from train import windows as frame_windows

DEFAULTS = (0.9146, 0.5, 0.5)  # bundle defaults: the teacher's rules thresholds


def nll_temperature(model, sessions, grid, window=250):
    """Temperature minimizing per-frame NLL to the teacher's 8-vector (state CE +
    four noul BCE, the teacher-head mean) over the fit frames. Classic temperature
    scaling: outputs collected once, every T scored vectorized — no replay."""
    import numpy as np
    import torch
    from registry import seam_heads, teacher_cols
    outs_all, tgt_all = [], []
    with torch.no_grad():
        for frames, _ev in sessions:
            T = len(frames["energy"])
            teacher = torch.from_numpy(frames["teacher"])
            for sl in frame_windows(T, window):
                hu = torch.from_numpy(np.ascontiguousarray(frames["hu"][sl]))[None]
                ha = torch.from_numpy(np.ascontiguousarray(frames["ha"][sl]))[None]
                act = torch.from_numpy(np.ascontiguousarray(frames["energy"][sl]))[None]
                prev = torch.from_numpy(np.ascontiguousarray(frames["prev_state"][sl]))[None]
                outs, _ = model(hu, ha, act, prev)
                outs_all.append({h.id: outs[h.id][0].float().numpy() for h in seam_heads()})
                tgt_all.append(teacher[sl].numpy())
    heads = seam_heads()
    cols = {h.id: teacher_cols(h) for h in heads}
    best, table = None, {}
    for t in grid:
        total, n = 0.0, 0
        for outs, tgt in zip(outs_all, tgt_all):
            for h in heads:
                o = outs[h.id] / t
                y = tgt[:, cols[h.id]]
                if h.kind == "choice":
                    z = o - o.max(axis=-1, keepdims=True)
                    logp = z - np.log(np.exp(z).sum(axis=-1, keepdims=True))
                    total += float(-(y * logp).sum())
                    n += len(o)
                else:
                    p = 1.0 / (1.0 + np.exp(-o[:, 0]))
                    p = np.clip(p, 1e-6, 1 - 1e-6)
                    total += float(-(y[:, 0] * np.log(p) + (1 - y[:, 0]) * np.log(1 - p)).sum())
                    n += len(o)
        table[t] = total / n
        if best is None or table[t] < table[best]:
            best = t
    return best, table


def agreement(model, oracle, sessions, layer, cfg, tol):
    """cfg = [temp, ep_thr, barge_thr, bc_thr]; temperature scales the decision
    logits pre-seam (T=1.0 is the plain model)."""
    m = model if cfg[0] == 1.0 else TempScaled(model, cfg[0])
    same = total = 0
    for frames, ref in sessions:
        cand = student_events(m, oracle, frames, layer, tuple(cfg[1:]))
        al, _, _ = aligned_count(ref, cand, tol)
        same += al
        total += max(len(ref), len(cand))
    return same / total if total else 1.0


def argbest(model, oracle, sessions, layer, tol, grid, idx, base):
    """Best value for knob `idx` over `grid`, others fixed at `base` -> (value, agree)."""
    best = (base[idx], agreement(model, oracle, sessions, layer, base, tol))
    for v in grid:
        cfg = list(base)
        cfg[idx] = v
        a = agreement(model, oracle, sessions, layer, cfg, tol)
        if a > best[1]:
            best = (v, a)
    return best


def staged_search(model, oracle, sessions, layer, tol, knobs, base, joint=True):
    """knobs = [(grid, cfg_index)]; one argbest pass per knob in order, then one
    joint neighbor pass over all knobs. Mutates and returns base."""
    for grid, idx in knobs:
        v, a = argbest(model, oracle, sessions, layer, tol, grid, idx, tuple(base))
        base[idx] = v
        print(f"  knob {['temp', 'ep', 'barge', 'bc'][idx]} -> {v} ({a:.2%})", flush=True)
    if joint:
        cur_agree = agreement(model, oracle, sessions, layer, tuple(base), tol)
        for grid, idx in knobs:
            cur = grid.index(base[idx]) if base[idx] in grid else None
            if cur is None:
                continue
            for j in (cur - 1, cur + 1):
                if 0 <= j < len(grid):
                    cfg = list(base)
                    cfg[idx] = grid[j]
                    a = agreement(model, oracle, sessions, layer, cfg, tol)
                    if a > cur_agree:
                        base[idx] = grid[j]
                        cur_agree = a
    return base


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", required=True, help="gate shard dir with recorded teacher events")
    ap.add_argument("--student", required=True)
    ap.add_argument("--tap", default=None,
                    help="shared-latent checkpoints: which tap adapter to replay "
                         "(must match --feature-layer; default: the checkpoint's deploy tap)")
    ap.add_argument("--feature-layer", type=int, default=15)
    ap.add_argument("--tol", type=int, default=2)
    ap.add_argument("--sessions", type=int, default=0, help="limit sessions (0 = all); for quick passes")
    ap.add_argument("--ep-grid", default="0.70,0.75,0.80,0.85,0.88,0.90,0.9146,0.93")
    ap.add_argument("--barge-grid", default="0.3,0.4,0.5,0.6")
    ap.add_argument("--bc-grid", default="0.3,0.4,0.5,0.6")
    ap.add_argument("--no-joint", action="store_true", help="skip the joint neighbor pass")
    ap.add_argument("--temp-grid", default="",
                    help="P4 per-adapter temperature grid (e.g. '0.8,0.9,1.0,1.1,1.25'); "
                         "fits the pre-seam temperature (NLL + agreement) above the threshold fit")
    ap.add_argument("--out", default=None, help="traits JSON (default: <student>.traits.json)")
    args = ap.parse_args()

    model, _ckpt = load_model(args.student, tap=args.tap)
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
    temp_grid = [float(x) for x in args.temp_grid.split(",")] if args.temp_grid else []
    cfg = [1.0] + list(DEFAULTS)
    base_agree = agreement(model, oracle, sessions, args.feature_layer, cfg, args.tol)
    print(f"default (T=1, {DEFAULTS}): {base_agree:.2%} agreement ({len(sessions)} sessions)", flush=True)

    t_nll = None
    if temp_grid:
        t_nll, nll_table = nll_temperature(model, sessions, temp_grid)
        print("NLL temperature fit: " + ", ".join(f"T {t}: {v:.4f}" for t, v in nll_table.items()), flush=True)
        print(f"  T_nll={t_nll} at default thresholds: "
              f"{agreement(model, oracle, sessions, args.feature_layer, [t_nll] + list(DEFAULTS), args.tol):.2%}",
              flush=True)

    knobs = [(grids[0], 1), (grids[1], 2), (grids[2], 3)]
    t1 = staged_search(model, oracle, sessions, args.feature_layer, args.tol, knobs,
                       [1.0] + list(DEFAULTS), joint=not args.no_joint)
    t1_agree = agreement(model, oracle, sessions, args.feature_layer, tuple(t1), args.tol)
    print(f"thresholds-only (T=1) {tuple(t1[1:])}: {t1_agree:.2%}", flush=True)

    if temp_grid:
        best = staged_search(model, oracle, sessions, args.feature_layer, args.tol,
                             [(temp_grid, 0)] + knobs, [1.0] + list(DEFAULTS), joint=not args.no_joint)
        if t1_agree >= agreement(model, oracle, sessions, args.feature_layer, tuple(best), args.tol):
            best = t1  # the staged search is greedy — never report below the T=1 path
    else:
        best = t1
    best_agree = agreement(model, oracle, sessions, args.feature_layer, tuple(best), args.tol)

    out = args.out or os.path.splitext(args.student)[0] + ".traits.json"
    traits = {"name": os.path.basename(os.path.splitext(args.student)[0]),
              "decider": {"ep_thr": best[1], "ep_deb": 2, "barge_thr": best[2], "barge_deb": 2,
                          "bc_thr": best[3], "bc_deb": 2, "bc_refractory": 15}}
    if temp_grid:
        traits["temperature"] = best[0]
        if t_nll is not None:
            traits["temperature_nll"] = t_nll
    with open(out, "w") as f:
        json.dump(traits, f, indent=2)
    print(f"\ndefault (T=1, {DEFAULTS}): {base_agree:.2%}  ->  T+thresholds {tuple(best)}: {best_agree:.2%}"
          + (f"  (thresholds-only {tuple(t1[1:])}: {t1_agree:.2%})" if temp_grid else ""))
    print(f"wrote {out}")
    print("report BOTH numbers with any gate result: default = self-contained behavior, calibrated = product config")


if __name__ == "__main__":
    main()
