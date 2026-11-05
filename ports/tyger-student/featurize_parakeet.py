"""Rebuild a shard set's features from parakeet-unified's encoder taps (epic #132 P5).

Second-ASR portability: keep everything the teacher said (its 8-vectors, events,
the corpus labels, energy and prev_state — same contract as featurize_tap.py) and
replace `hu`/`ha` with rows from ONE encoder layer of `nvidia/parakeet-unified-en-0.6b`
(Unified-FastConformer-RNNT, 24 layers x 1024-d, x8 subsampling = 80 ms frames — the
decision grid). One full-context pass per channel extracts every layer via hooks.

Two outputs from the one pass:

  out/<sid>.npz            canonical hu/ha = --layer K, fp32 (the training shards)
  out/sweep-l<J>/<sid>.npz per-layer probe sets, fp16 hu/ha = layer J — one shard
                           dir per depth for probe.py's per-depth sweep (its
                           --canonical labels the row); fp16 is probe-only, the
                           training set is always the fp32 --layer run

Rows land on the ref shards' frame grid by index (burst-train measured: row k =
k*80 ms exactly, +1 tail row trimmed — the featurize_tap.py convention); the first
session's row alignment vs the ref frame energy is verified on layer 0 (the
time-local subsampled features; deeper layers smear event energy forward — L12
norms peak ~4 rows late — a receptive-field property of the tap, not a grid offset).
Lag is a tripwire: only a confidently offset, well-correlated profile (peak r > 0.75
beats lag 0 by > 0.1) aborts the run — the grid itself is measured exact (burst train,
row k = k*80 ms; recomputed ref energy bit-identical), while the tap's response lag
varies with content and is the adapter's business.

shortcut: full-context pass, not the cache-aware streaming one — fine for the probe
sweep and the adapter fit; re-run the deploy tier taps with `cache_aware_stream_step`
before any on-device swap-over (the drift is unmeasured here).

Usage:
  ports/tyger-student/.venv-nemo/bin/python ports/tyger-student/featurize_parakeet.py \
      --shards /Users/don/dev/idfon/bench-results/student-shards/train --split train \
      --layer 12 --sweep 0-23 --out bench-results/parakeet-taps [--sessions N] [--device mps]
"""
import argparse
import os
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from data import load_shard, save_shard  # noqa: E402
from oracle import decode_channel, resample16k  # noqa: E402

DATASET = "anyreach-ai/dualturn-otospeech-turn-taking"
MODEL = "nvidia/parakeet-unified-en-0.6b"


def parse_layers(spec):
    """'0-23' | '2,6,10' | '4' -> sorted unique ints."""
    out = set()
    for part in spec.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-")
            out.update(range(int(a), int(b) + 1))
        elif part:
            out.add(int(part))
    return sorted(out)


def load_model(device, layers, name=MODEL):
    """-> (model, captured) with forward hooks stashing {layer: (T, 1024)} per pass."""
    import nemo.collections.asr as nemo_asr
    model = nemo_asr.models.ASRModel.from_pretrained(model_name=name, map_location="cpu")
    model = model.eval().to(device)
    enc = model.encoder
    captured = {}

    def hook(i):
        def fn(_m, _inp, out):
            captured[i] = (out[0] if isinstance(out, tuple) else out)[0].float().cpu().numpy()
        return fn

    for i in layers:
        enc.layers[i].register_forward_hook(hook(i))
    return model, captured


def tap(model, captured, wav, device):
    """(samples,) -> {layer: (frames, 1024)} at 80 ms, one full-context encoder pass."""
    sig = torch.from_numpy(np.asarray(wav, np.float32))[None].to(device)
    with torch.no_grad():
        model(input_signal=sig, input_signal_length=torch.tensor([sig.shape[1]], device=device))
    return {k: v.copy() for k, v in captured.items()}


def best_lag(energy, norm, max_lag=3):
    """Row offset of tap norms vs ref frame energy (Pearson over lags) ->
    (best_lag, score, score_at_0). Positive lag means the tap's response peaks
    after the ref frame (content runs behind)."""
    scores = {}
    for lag in range(-max_lag, max_lag + 1):
        n = min(len(energy), len(norm) - lag) if lag >= 0 else min(len(energy) + lag, len(norm))
        if n < 10:
            continue
        e = energy[max(0, -lag):max(0, -lag) + n]
        m = norm[max(0, lag):max(0, lag) + n]
        scores[lag] = float(np.corrcoef(e, m)[0, 1]) if e.std() > 0 and m.std() > 0 else -1.0
    best = max(scores, key=scores.get) if scores else 0
    return best, scores.get(best, -1.0), scores.get(0, -1.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", required=True, help="reference shard dir (the teacher's frames)")
    ap.add_argument("--split", required=True, help="dataset split the shard dir came from")
    ap.add_argument("--out", required=True, help="output root (train/ and val/ get their own roots)")
    ap.add_argument("--layer", type=int, default=12, help="canonical hu/ha layer, fp32 (the training shards)")
    ap.add_argument("--sweep", default="", help="also write fp16 probe sets under out/sweep-l{J}/ for "
                                               "probe.py's per-depth sweep (e.g. '0-23')")
    ap.add_argument("--sessions", type=int, default=10_000)
    ap.add_argument("--device", default="mps")
    ap.add_argument("--model", default=MODEL, help="HF model id (the runner-up family for the A/B)")
    args = ap.parse_args()

    sweep = parse_layers(args.sweep) if args.sweep else []
    layers = sorted({0, args.layer} | set(sweep))  # layer 0 = the grid-alignment probe
    refs = {p.stem: p for p in sorted(Path(args.shards).glob("*.npz"))}
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    model, captured = load_model(args.device, layers, args.model)
    from datasets import load_dataset
    from transformers import AutoModel

    mimi = AutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()
    done = 0
    for row in load_dataset(DATASET, split=args.split, streaming=True):
        if done >= args.sessions:
            break
        sid = row["session_id"]
        if sid not in refs or (out / f"{sid}.npz").exists():
            continue
        frames, labels, events, meta = load_shard(str(refs[sid]))
        T = len(frames["energy"])
        limit = min(int(row["num_frames"]), T + 2)  # mimi codes are also 80 ms frames
        codes = {ch: np.array(row[f"codes_{ch}"], dtype=np.int16).reshape(int(row["num_frames"]), 8)[:limit]
                 for ch in ("ch0", "ch1")}
        taps = {}
        for ch in ("ch0", "ch1"):
            wav = resample16k(decode_channel(mimi, codes[ch]))
            taps[ch] = tap(model, captured, wav, args.device)
        ku, ka = taps["ch0"][args.layer], taps["ch1"][args.layer]
        lag, corr, corr0 = best_lag(frames["energy"], np.linalg.norm(taps["ch0"][0], axis=1))
        if done == 0:
            print(f"  alignment: {args.model} L0 vs ref energy -> lag {lag} "
                  f"(r={corr:.3f}, r@0={corr0:.3f})", flush=True)
        # the grid is burst-train measured (row k = k*80 ms exactly) and the wav/energy are
        # bit-identical to featurize.py's (verified: recomputed ref energy max|diff| = 0) —
        # so this is only a tripwire for gross pipeline errors (a hop-size mismatch would
        # show near-perfect r at a big offset). The tap's RESPONSE trails energy onsets by
        # 1-2 frames on some content (receptive field) — absorbed by the adapter.
        if abs(lag) > 1 and corr > 0.75 and corr > corr0 + 0.1:
            raise AssertionError(f"{sid}: tap grid misaligned (lag {lag}, r={corr:.2f} vs r@0={corr0:.2f})")
        n = min(T, len(ku), len(ka))  # index alignment + tail trim (featurize_tap.py convention)
        if n < T:
            print(f"  {sid[:16]}… tap {len(ku)}/{len(ka)} vs ref {T} frames, trimming to {n}", flush=True)
        frames["hu"], frames["ha"] = ku[:n], ka[:n]
        frames["energy"], frames["prev_state"] = frames["energy"][:n], frames["prev_state"][:n]
        frames["teacher"] = frames["teacher"][:n]
        lab = {k: v[:n] for k, v in labels.items()}
        ev = (np.asarray(events[0], np.int32), events[1]) if events is not None else None
        save_shard(str(out / f"{sid}.npz"), sid, frames, lab, events=ev)
        for j in sweep:
            sweep_frames = dict(frames)
            sweep_frames["hu"] = taps["ch0"][j][:n].astype(np.float16)
            sweep_frames["ha"] = taps["ch1"][j][:n].astype(np.float16)
            save_shard(str(out / f"sweep-l{j}" / f"{sid}.npz"), sid, sweep_frames, lab, events=ev)
        done += 1
        print(f"  {sid[:16]}… L{args.layer}{' +sweep ' + args.sweep if sweep else ''} "
              f"{n}/{T} frames -> {out.name}", flush=True)
    print(f"{done} parakeet tap shard(s) in {out}")


if __name__ == "__main__":
    main()
