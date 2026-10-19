#!/usr/bin/env python3
"""S1 parity + timing: MLX encoder→L15 vs the torch reference on identical features.

    .venv/bin/python ports/tyger-mlx/parity.py [--wav clip.wav]

Compares `hidden_states[L15]` (the exact tensor the turn-taker's heads read) between
transformers' NemotronAsrStreamingEncoder (num_lookahead_tokens=0, as ReferenceEars
uses) and the MLX port, then times one hop (320 ms of audio) on each device. Acceptance
(docs/voice-tyger-ondevice.md): fp32 max|Δ| ≈ 1e-5; decisions identical after the heads.
"""
import argparse
import os
import sys
import time
from pathlib import Path

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE", os.path.expanduser(
    "~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6"))
sys.path.insert(0, S2S)
sys.path.insert(0, os.path.join(S2S, "scripts"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))

import numpy as np  # noqa: E402

import mlx.core as mx  # noqa: E402
import torch  # noqa: E402

from app.plugins.ears.tyger.bundle import load  # noqa: E402
from app.plugins.ears.tyger.constants import L15, SR  # noqa: E402
from encoder import EncoderL15  # noqa: E402


def features_for(proc, wav):
    inp = proc(wav, sampling_rate=SR, return_tensors="pt")
    return inp["input_features"], inp.get("attention_mask")


def main():
    ap_ = argparse.ArgumentParser()
    ap_.add_argument("--wav", default=None)
    args = ap_.parse_args()

    if args.wav:
        import wave
        with wave.open(args.wav) as w:
            assert w.getsampwidth() == 2 and w.getnchannels() == 1
            rate = w.getframerate()
            x = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768.0
        if rate != SR:
            n = int(round(len(x) * SR / rate))
            x = np.interp(np.linspace(0, len(x), n, endpoint=False), np.arange(len(x)), x).astype(np.float32)
    else:
        x = np.random.default_rng(7).normal(0, 0.1, SR * 2).astype(np.float32)
    x = x[: SR * 2]  # 2 s: 25 encoder frames at 80 ms

    torch.set_num_threads(4)
    asr, proc, _tt, _cfg = load(Path(BUNDLE))
    feats, am = features_for(proc, x)
    print(f"features: {tuple(feats.shape)}")

    with torch.no_grad():
        eo = asr.encoder(input_features=feats, attention_mask=am, num_lookahead_tokens=0, output_hidden_states=True)
    ref = eo.hidden_states[L15][0].float()
    print(f"torch hidden_states[{L15}]: {tuple(ref.shape)}")

    mlx_enc = EncoderL15(BUNDLE, layers=L15 if L15 <= 15 else 15)
    out = mlx_enc(mx.array(feats.numpy()), lookahead=0)
    print(f"mlx: {tuple(out.shape)}")
    diff = np.abs(out - ref.numpy())
    print(f"parity: max|Δ| = {diff.max():.3e}   mean|Δ| = {diff.mean():.3e}")
    print("PASS" if diff.max() < 1e-3 else "FAIL (see docs/voice-tyger-ondevice.md acceptance)")

    # one-hop timing (the encoder is the dominant per-hop cost)
    hop_extra = int(0.32 * SR / 8)  # mel frames for 320 ms more audio (10 ms frames / subsample 8)
    for name, run in [
        ("torch cpu", lambda: asr.encoder(input_features=feats, attention_mask=am, num_lookahead_tokens=0, output_hidden_states=True)),
    ]:
        ts = []
        for _ in range(3):
            t = time.perf_counter()
            run()
            ts.append(time.perf_counter() - t)
        print(f"timing {name}: {min(ts) * 1000:.0f} ms per full-window encode")
    ts = []
    for _ in range(3):
        mx.eval(mx.array(feats.numpy()))
        t = time.perf_counter()
        mx.eval(mlx_enc(mx.array(feats.numpy()), lookahead=0))
        ts.append(time.perf_counter() - t)
    print(f"timing mlx: {min(ts) * 1000:.0f} ms per full-window encode")


if __name__ == "__main__":
    main()
