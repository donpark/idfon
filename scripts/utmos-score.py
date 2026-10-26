#!/usr/bin/env python3
"""UTMOS (neural MOS) for wav files — the voice pipeline's quality scorer.
Run under a python that has torch (and torchaudio):

    <torch python> scripts/utmos-score.py a.wav b.wav    # {"a.wav": 4.32, ...}

A quality floor, not a target-matching metric: it estimates how natural a
clip sounds (1-5), it does not measure style. First run downloads the
checkpoint via torch.hub (tarepan/SpeechMOS, cached under ~/.cache/torch).
"""
import json
import sys
import wave

import numpy as np
import torch


def mos(model, path):
    with wave.open(path) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype("float32") / 32768
        sr = w.getframerate()
    if not len(x):
        return None
    return round(float(model(torch.from_numpy(x).unsqueeze(0), torch.tensor([sr])).item()), 3)


def main():
    if len(sys.argv) < 2:
        print("usage: utmos-score.py WAV [WAV...]", file=sys.stderr)
        sys.exit(2)
    model = torch.hub.load("tarepan/SpeechMOS:v1.2.0", "utmos22_strong", trust_repo=True)
    model.eval()
    out = {}
    for path in sys.argv[1:]:
        try:
            out[path] = mos(model, path)
        except Exception as e:  # one bad wav must not sink the batch
            out[path] = None
            print(f"utmos-score: {path}: {e}", file=sys.stderr)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
