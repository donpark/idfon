"""Rebuild a shard set's features from the STREAMING (cache-aware) encoder tap (#102).

The reference shards record what the teacher saw: a per-hop 8 s windowed re-encode.
This script keeps everything the teacher said (its 8-vectors, events, the corpus
labels, energy and prev_state) and replaces only `hu`/`ha` with the same encoder's
layer-K rows from ONE cache-aware streaming pass -- the features the ASR already
computes and throws away. Student trained on these = zero train/serve drift.

Verified on 2 sessions: the tap's frame grid is the windowed grid exactly
(offset 0/0 on both channels; the tap is ~2 frames short at the tail, trimmed).

Usage:
  TYGER_BUNDLE=... ports/tyger-student/.venv/bin/python ports/tyger-student/featurize_tap.py \
      --shards bench-results/student-shards/val --split val --layer 4 \
      --out bench-results/tap4-shards/val [--sessions N] [--device mps]
"""
import argparse
import os
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from data import load_shard, save_shard  # noqa: E402
from oracle import GRID, HOP, HOP_FRAMES, SR, WIN_S, Oracle, decode_channel, resample16k  # noqa: E402
from transformers.cache_utils import DynamicCache  # noqa: E402
from transformers.models.nemotron_asr_streaming.modeling_nemotron_asr_streaming import (  # noqa: E402
    NemotronAsrStreamingEncoderCausalConvPaddingCache)

CHUNK_MEL = 56
PRE_ENCODE = 9
DATASET = "anyreach-ai/dualturn-otospeech-turn-taking"


def tap(oracle, wav, layer, lookahead=0):
    """(samples,) -> (frames, 1024) at the encoder's frame grid, one streaming pass."""
    enc = oracle.asr.encoder
    feats = oracle.proc(np.asarray(wav, np.float32), sampling_rate=SR,
                        return_tensors="pt")["input_features"].to(oracle.device)
    cache = DynamicCache(config=enc.config)
    pc = NemotronAsrStreamingEncoderCausalConvPaddingCache()
    rows = []
    with torch.no_grad():
        for end in range(PRE_ENCODE + CHUNK_MEL, feats.shape[1] + 1, CHUNK_MEL):
            out = enc(input_features=feats[:, end - PRE_ENCODE - CHUNK_MEL:end],
                      use_cache=True, past_key_values=cache, padding_cache=pc,
                      num_lookahead_tokens=lookahead, output_hidden_states=True)
            rows.append(out.hidden_states[layer][0].float()[1:])  # 1st row = 9 cached mel frames
    return torch.cat(rows).detach().cpu().numpy() if rows else np.zeros((0, 1024), np.float32)


def windowed(oracle, wav, layer, coreml=None):
    """The reference pass: per 320 ms hop, re-encode the last 8 s window, last 4 rows.
    A Core ML L4 package serves the steady-state windows (10 ms/window vs 150 ms in
    torch; fp32 parity is 2e-4, and it is the graph the device runs). Early growing
    windows still take the oracle path (the static graph needs 801 mel frames)."""
    rows = []
    full = WIN_S * SR
    for h in range(len(wav) // HOP):
        x = (h + 1) * HOP
        win = wav[max(0, x - full):x]
        if coreml is not None and len(win) >= full:
            mel = oracle.proc(np.asarray(win, np.float32), sampling_rate=SR,
                              return_tensors="pt")["input_features"].numpy()
            arr = np.asarray(next(iter(coreml.predict({"feats": mel}).values())))[0]
            rows.extend(arr[-HOP_FRAMES:])
            continue
        hs = oracle.encode_hidden(win)
        rows.extend(hs[layer][-min(HOP_FRAMES, len(hs[layer])):])
    return np.stack(rows) if rows else np.zeros((0, 1024), np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", required=True, help="reference shard dir (the teacher's frames)")
    ap.add_argument("--split", required=True, help="dataset split the shard dir came from")
    ap.add_argument("--out", required=True)
    ap.add_argument("--layer", type=int, default=4)
    ap.add_argument("--lookahead", type=int, default=0)
    ap.add_argument("--sessions", type=int, default=10_000)
    ap.add_argument("--device", default="mps")
    ap.add_argument("--coreml", default=None,
                    help="Core ML L4 encoder package for the windowed steady state (10 ms/window)")
    ap.add_argument("--asr-model", default=None,
                    help="HF model id to tap INSTEAD of the TYGER bundle (same encoder family, "
                         "nemotron_asr_streaming_encoder — stream pass only), e.g. "
                         "nvidia/nemotron-3.5-asr-streaming-0.6b")
    ap.add_argument("--pass", dest="pass_", default="stream", choices=("stream", "windowed"),
                    help="stream = the ASR's cache-aware tap; windowed = the 8 s re-encode")
    args = ap.parse_args()

    refs = {p.stem: p for p in sorted(Path(args.shards).glob("*.npz"))}
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.asr_model and args.pass_ != "stream":
        sys.exit("--asr-model supports --pass stream only (windowed needs the bundle's encode_hidden)")
    from datasets import load_dataset
    from transformers import AutoModel

    mimi = AutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()
    coreml = None
    if args.coreml and args.pass_ == "windowed":
        import coremltools as ct
        coreml = ct.models.MLModel(args.coreml, compute_units=ct.ComputeUnit.ALL)
    done = 0
    rows = iter(load_dataset(DATASET, split=args.split, streaming=True))
    if args.asr_model:
        from transformers import AutoModel as _AutoModel, AutoProcessor

        class _Shim:  # tap() only touches asr.encoder and proc — the Oracle surface
            pass
        oracle = _Shim()
        oracle.device = args.device
        oracle.proc = AutoProcessor.from_pretrained(args.asr_model)
        oracle.asr = _AutoModel.from_pretrained(args.asr_model, torch_dtype=torch.float32).eval().to(args.device)
    else:
        oracle = Oracle(device=args.device).load_bundle()
    for row in rows:
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
        wav = {ch: resample16k(decode_channel(mimi, codes[ch])) for ch in ("ch0", "ch1")}
        if args.pass_ == "stream":
            hu = tap(oracle, wav["ch0"], args.layer)
            ha = tap(oracle, wav["ch1"], args.layer)
        else:
            hu = windowed(oracle, wav["ch0"], args.layer, coreml)
            ha = windowed(oracle, wav["ch1"], args.layer, coreml)
        n = min(T, len(hu), len(ha))
        if n < T:
            print(f"  {sid[:16]}… tap {len(hu)}/{len(ha)} vs ref {T} frames, trimming to {n}", flush=True)
        frames["hu"], frames["ha"] = hu[:n], ha[:n]
        frames["energy"], frames["prev_state"] = frames["energy"][:n], frames["prev_state"][:n]
        frames["teacher"] = frames["teacher"][:n]
        save_shard(str(out / f"{sid}.npz"), sid, frames,
                   {k: v[:n] for k, v in labels.items()},
                   events=(np.asarray(events[0], np.int32), events[1])
                   if events is not None else None)
        done += 1
        print(f"  {sid[:16]}… {args.pass_} L{args.layer} {n}/{T} frames -> {out.name}", flush=True)
    print(f"{done} tap shard(s) in {out}")


if __name__ == "__main__":
    main()
