"""Featurize live `TurnCapture` stereo wavs through the 42/13 int8 artifact.

`pass_gate.py --emit-shards --artifact` covers the dualturn corpus. Live captures are
stereo 16 kHz wavs (`ch0` = mic, `ch1` = agent), so the same artifact can produce their
L4 streaming rows; this script keeps the live shard's recorded teacher/eight-vector/events
and replaces only `hu`/`ha` — the per-domain ("live") calibration input P4 asks for.

Row convention matches `pass_gate.py`: 7 rows per chunk, with the first row duplicated
so the emitted grid lines up with the windowed shard's T (measured offset 0).

Usage:
  .venv/bin/python ports/tyger-student/featurize_live_artifact.py \
      --wavs "$HOME/Library/Application Support/Idfon/turn-captures" \
      --shards /Users/don/dev/idfon/bench-results/live-shards-l4-all \
      --out bench-results/live-shipping \
      --artifact bench-results/asr-tap/encoder_tap_42-13_fp16_int8w.mlpackage
"""
import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from data import load_shard, save_shard  # noqa: E402
from asr_tap import TIERS  # noqa: E402
from pass_gate import PASSES  # noqa: E402

SR = 16_000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wavs", required=True, help="dir of TurnCapture stereo 16 kHz wavs")
    ap.add_argument("--shards", required=True, help="live shard dir (teacher/events; hu/ha replaced)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--artifact", required=True)
    ap.add_argument("--pass", dest="pass_", default="shipping", choices=sorted(PASSES))
    ap.add_argument("--chunk-ms", type=int, default=560, choices=sorted(TIERS),
                    help="chunk tier; must match the artifact's metadata.json")
    ap.add_argument("--model", default="nvidia/nemotron-3.5-asr-streaming-0.6b")
    args = ap.parse_args()

    import coremltools as ct
    import soundfile as sf
    from transformers import AutoProcessor

    from export_asr_tap import ml_stream

    cfg = PASSES[args.pass_]
    tier = TIERS[args.chunk_ms]
    side = Path(args.artifact).parent / "metadata.json"
    if side.exists():
        have = json.loads(side.read_text()).get("chunk_ms")
        assert have == tier.ms, f"{side}: chunk_ms {have} != --chunk-ms {tier.ms}"
    proc = AutoProcessor.from_pretrained(args.model)
    from transformers import AutoConfig
    prompt_id = int(getattr(AutoConfig.from_pretrained(args.model), "default_prompt_id", 101))
    mlmodel = ct.models.MLModel(args.artifact, compute_units=ct.ComputeUnit.CPU_AND_NE)
    refs = {p.stem: p for p in sorted(Path(args.shards).glob("*.npz"))}
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    done = 0
    for f in sorted(Path(args.wavs).glob("*.wav")):
        sid = f"live-{f.stem}"
        if sid not in refs:
            continue
        frames, labels, events, meta = load_shard(str(refs[sid]))
        T = len(frames["energy"])
        x, sr = sf.read(str(f), dtype="float32")
        assert sr == SR and x.ndim == 2 and x.shape[1] == 2, (f, sr, x.shape)
        rows = []
        for ch in (0, 1):
            feats = proc(np.ascontiguousarray(x[:, ch]), sampling_rate=SR,
                         return_tensors="pt")["input_features"].numpy()
            _, tap, _ = ml_stream(mlmodel, feats, prompt_id=prompt_id, cache_size=cfg.left,
                                  tier=tier)
            rows.append(np.concatenate([tap[:1], tap]))
        hu, ha = rows[0][:T], rows[1][:T]
        n = min(T, len(hu), len(ha))
        frames = {k: (v[:n] if isinstance(v, np.ndarray) else v) for k, v in frames.items()}
        frames["hu"], frames["ha"] = hu[:n], ha[:n]
        save_shard(str(out / f"{sid}.npz"), sid, frames,
                   {k: v[:n] for k, v in labels.items()},
                   events=(np.asarray(events[0], np.int32), events[1]) if events is not None else None)
        done += 1
        print(f"  {sid[:24]}… {n}/{T} frames -> {out}", flush=True)
    print(f"{done} live shard(s) in {out}")


if __name__ == "__main__":
    main()
