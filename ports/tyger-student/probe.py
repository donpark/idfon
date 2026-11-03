"""Tap probe survey (#132 P0): how much of each decision axis is linearly
decodable from each encoder tap.

One ridge probe per tap feature stream found in a shard set (the canonical
`hu`/`ha` pair plus any `hu_lK`/`ha_lK` extras) from the two 1,024-d streams
concatenated (2,048-d; energy and prev_state deliberately excluded — this
measures tap information alone), targets = the teacher 8-vector columns
(4 state logits, hazard, yield, bc, p_end). Reports R² and cosine on held-out
sessions. The output table is what drives the per-axis adapter loss weights of
the shared-latent student (epic #132): tap choice is measured per axis, never
averaged.

Sessions are split train/val by name (sorted, the last `--val-sessions` are
val), so one run compares every tap it finds on the same held-out frames.

Usage:
  .venv/bin/python ports/tyger-student/probe.py --shards DIR [DIR ...] \
      --name "dualturn 68 — Tyger windowed L15" --canonical L15 \
      [--val-sessions 8] [--alpha 1.0] [--selfcheck]
"""
import argparse
import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from data import load_shard  # noqa: E402

STATE_COLS = (0, 1, 2, 3)
AXES = (("state", (0, 1, 2, 3)), ("hazard", (4,)), ("yield", (5,)), ("bc", (6,)), ("p_end", (7,)))


def collect(paths, key_u, key_a):
    """-> X (T, 2048) float32, Y (T, 8) float32 over the given shard files."""
    xs, ys = [], []
    for p in paths:
        frames, _labels, _events, _meta = load_shard(str(p))
        xs.append(np.concatenate([frames[key_u], frames[key_a]], axis=1).astype(np.float32))
        ys.append(frames["teacher"].astype(np.float32))
    return np.concatenate(xs), np.concatenate(ys)


def fit_ridge(Xtr, Ytr, alpha):
    """Standardized ridge, closed form. Returns (mu, sd, Ym, W)."""
    mu, sd = Xtr.mean(0), Xtr.std(0)
    sd[sd < 1e-6] = 1.0
    Xtr -= mu
    Xtr /= sd
    Ym = Ytr.mean(0)
    Yc = Ytr - Ym
    D = Xtr.shape[1]
    XtX = (Xtr.T @ Xtr).astype(np.float64) + alpha * np.eye(D)
    Xty = Xtr.T.astype(np.float64) @ Yc.astype(np.float64)
    return mu, sd, Ym, np.linalg.solve(XtX, Xty)


def score(pred, true):
    """Per-column (R², cosine) over all val frames."""
    r2, cos = [], []
    for c in range(pred.shape[1]):
        p, t = pred[:, c].astype(np.float64), true[:, c].astype(np.float64)
        ss = ((t - t.mean()) ** 2).sum()
        r2.append(1.0 - ((t - p) ** 2).sum() / ss if ss > 0 else float("nan"))
        n = np.linalg.norm(p) * np.linalg.norm(t)
        cos.append(float(p @ t / n) if n > 0 else float("nan"))
    return r2, cos


def probe(paths, key_u, key_a, alpha):
    """-> {axis: (r2, cos)} with the state axis averaged over its 4 logits."""
    Xtr, Ytr = collect(paths["train"], key_u, key_a)
    Xva, Yva = collect(paths["val"], key_u, key_a)
    mu, sd, Ym, W = fit_ridge(Xtr, Ytr, alpha)
    pred = ((Xva - mu) / sd) @ W + Ym
    r2, cos = score(pred, Yva)
    out = {}
    for axis, cols in AXES:
        out[axis] = (float(np.mean([r2[c] for c in cols])),
                     float(np.mean([cos[c] for c in cols])))
    return out


def selfcheck():
    rng = np.random.default_rng(0)
    T, D = 4000, 64
    X = rng.standard_normal((T, D)).astype(np.float32)
    W = rng.standard_normal((D, 8)).astype(np.float32)
    Y = X @ W + 0.05 * rng.standard_normal((T, 8)).astype(np.float32)
    mu, sd, Ym, Wf = fit_ridge(X[:3000].copy(), Y[:3000], 1.0)
    pred = ((X[3000:] - mu) / sd) @ Wf + Ym
    r2, cos = score(pred, Y[3000:])
    assert min(r2) > 0.9, f"selfcheck R² too low: {r2}"
    assert min(cos) > 0.95, f"selfcheck cosine too low: {cos}"
    print(f"selfcheck ok (min R² {min(r2):.4f}, min cos {min(cos):.4f})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", nargs="+", help="shard dir(s) sharing one tap family")
    ap.add_argument("--name", default="tap set", help="run title (dataset + provenance)")
    ap.add_argument("--canonical", default="canonical", help="row label for the hu/ha pair")
    ap.add_argument("--val-sessions", type=int, default=8)
    ap.add_argument("--alpha", type=float, default=1.0)
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args()
    if args.selfcheck:
        selfcheck()
        return

    files = {}
    for d in args.shards:
        for p in sorted(Path(d).glob("*.npz")):
            files.setdefault(p.stem, []).append(p)
    sessions = sorted(files)
    if len(sessions) <= args.val_sessions:
        sys.exit(f"need more than {args.val_sessions} sessions for a held-out split")
    val = set(sessions[-args.val_sessions:])

    # tap streams: canonical hu/ha plus any hu_lK/ha_lK pair found anywhere
    keys = {}
    for paths in files.values():
        frames, _l, _e, _m = load_shard(str(paths[0]))
        names = set(frames)
        if {"hu", "ha"} <= names:
            keys.setdefault(args.canonical, ("hu", "ha"))
        for k in names:
            m = re.fullmatch(r"hu_l(\d+)", k)
            if m and f"ha_l{m.group(1)}" in names:
                keys.setdefault(f"L{m.group(1)}", (k, f"ha_l{m.group(1)}"))
    paths = {
        "train": [p for s in sessions if s not in val for p in files[s]],
        "val": [p for s in sessions if s in val for p in files[s]],
    }
    ntr = sum(1 for s in sessions if s not in val)

    print(f"# Tap probe survey — {args.name}\n")
    print(f"{len(sessions)} sessions ({ntr} train / {args.val_sessions} val, split by "
          f"session name); features = [hu, ha] concatenated (2,048-d); ridge alpha "
          f"{args.alpha}; targets = teacher 8-vector; metrics on val frames.\n")
    print("| tap | state R²/cos | hazard R²/cos | yield R²/cos | bc R²/cos | p_end R²/cos |")
    print("| --- | --- | --- | --- | --- | --- |")
    for label, (key_u, key_a) in keys.items():
        res = probe(paths, key_u, key_a, args.alpha)
        cells = " | ".join(f"{res[a][0]:.3f} / {res[a][1]:.3f}" for a, _ in AXES)
        print(f"| {label} | {cells} |")


if __name__ == "__main__":
    main()
