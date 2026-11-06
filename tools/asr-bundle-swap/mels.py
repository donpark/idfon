"""Write four real 560 ms mel windows from a call capture for `--compare`.

`--compare` needs in-distribution input: two encoders compared on random noise
disagree wildly (attention on out-of-distribution frames), which says nothing
about the export. These are the exact windows the manager builds — 65 mel frames,
advancing 56 per chunk, front-end = the same HF processor our export was made
with (`nvidia/nemotron-3.5-asr-streaming-0.6b`).

Usage (needs the tyger venv: transformers + soundfile):
  ports/tyger-student/.venv/bin/python tools/asr-bundle-swap/mels.py \
      --wav "~/Library/Application Support/Idfon/turn-captures/turn-2026-10-26T20:17:43Z.wav" \
      --out bench-results/asr-bundle-swap/mels.f32 --chunks 4
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "ports" / "tyger-student"))

TOTAL_MEL, PRE_CACHE = 65, 9  # 560 ms tier: 56 new mel frames + 9 pre-encode context


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--wav", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--chunks", type=int, default=4)
    args = ap.parse_args()

    from batched_ears import mel_of  # the repo's front-end path
    import soundfile as sf

    x, sr = sf.read(Path(os.path.expanduser(args.wav)), dtype="float32")
    assert sr == 16_000, sr
    wav = x[:, 0] if x.ndim > 1 else x  # channel 0 = the mic, what the ASR sees
    from transformers import AutoProcessor

    proc = AutoProcessor.from_pretrained(
        os.environ.get("TYGER_ASR", "nvidia/nemotron-3.5-asr-streaming-0.6b"))
    feats = mel_of(proc, wav)  # [1, frames, 128]
    stride = TOTAL_MEL - PRE_CACHE  # 56 new mel frames per 560 ms chunk
    # feats is [1, frames, 128]; the manager's chunk i window is [i*56 : i*56+65].
    mels = [feats[0, i * stride:i * stride + TOTAL_MEL].T for i in range(args.chunks)]
    assert all(m.shape == (128, TOTAL_MEL) for m in mels), [m.shape for m in mels]
    arr = np.stack([m[None] for m in mels]).astype(np.float32)  # [chunks, 1, 128, 65]
    out = Path(os.path.expanduser(args.out))
    out.parent.mkdir(parents=True, exist_ok=True)
    arr.tofile(out)
    print(f"wrote {out}  {arr.shape} float32  "
          f"({arr.size * 4} bytes, {TOTAL_MEL - PRE_CACHE} mel frames/chunk advance)")


if __name__ == "__main__":
    main()
