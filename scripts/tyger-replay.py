#!/usr/bin/env python3
"""Offline decision replay through the real TYGER bundle (docs/voice-tyger.md, P0b-i).

Feeds a recorded call to `ReferenceEars` — tyger-s2s's own plain single-session
implementation of the bundle (their scripts/validate/reference.py; same rules.py
as the live engine) — on the CPU, and prints the turn-taking decisions with
timestamps. No GPU, no tyger stack, no network: the model runs where this runs.

    TYGER_S2S=/path/to/tyger-s2s TYGER_BUNDLE=/path/to/bundle \
      .venv/bin/python /path/to/scripts/tyger-replay.py --wav call.wav [--mode listen]

- `--wav`: mono s16 WAV at any rate; resampled to 16 kHz (the model's grid).
- `--mode`: `listen` (the agent is silent — measure endpoints) or `speaking`
  (the recording includes the agent's own voice — measure yields/barge-in).
- `--agent`: a second WAV, same length, the agent's playback as the second ear.

The bundle is public (`nineninesix/tyger`): `huggingface_hub.snapshot_download`
fetched it without a token. `TYGER_BUNDLE` is the snapshot directory.
"""
import argparse
import os
import struct
import sys
import time
import wave

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE")
sys.path.insert(0, S2S)
sys.path.insert(0, os.path.join(S2S, "scripts"))

import numpy as np  # noqa: E402
import torch  # noqa: E402

from app.plugins.ears.tyger import rules  # noqa: E402
from app.plugins.ears.tyger.session import EarsSession  # noqa: E402
from validate.reference import ReferenceEars  # noqa: E402

HOP_MS = 320  # one hop is one batch of 80 ms frames: 320 ms at 16 kHz
SR = 16_000


def read_mono16k(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2, f"{path}: need mono s16"
        rate = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768.0
    if rate != SR:  # linear resample to the model's grid
        n = int(round(len(x) * SR / rate))
        x = np.interp(np.linspace(0, len(x), n, endpoint=False), np.arange(len(x)), x).astype(np.float32)
    return x


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", required=True)
    ap.add_argument("--agent", default=None)
    ap.add_argument("--mode", default="listen", choices=["listen", "speaking"])
    ap.add_argument("--device", default="cpu",
                    help="torch device for the reference encoder (cpu is the "
                         "calibrated one; mps is ~10-20x faster for sweeps, "
                         "with float-noise caveat)")
    args = ap.parse_args()

    user = read_mono16k(args.wav)
    agent = read_mono16k(args.agent) if args.agent else np.zeros_like(user)
    n = min(len(user), len(agent))
    user, agent = user[:n], agent[:n]
    hop = HOP_MS * SR // 1000

    torch.set_num_threads(os.cpu_count() or 8)
    t0 = time.perf_counter()
    ears = ReferenceEars(BUNDLE, device=args.device)
    print(f"loaded {BUNDLE} in {time.perf_counter() - t0:.1f}s", file=sys.stderr)

    sess = EarsSession(0)
    print(f"# {len(user) / SR:.1f}s of audio, {len(user) // hop} hops, mode={args.mode}")
    for start in range(0, len(user) - hop + 1, hop):
        t = start / SR
        events = ears.feed(sess, user[start : start + hop], agent[start : start + hop], args.mode)
        for ev in events:
            fields = " ".join(f"{k}={v!r}" for k, v in ev.items() if k not in ("kind",))
            print(f"t={t:7.2f}  {ev['kind']:<12} {fields}")
        print(f"t={t:7.2f}  .", end="\r", file=sys.stderr)
    print()


if __name__ == "__main__":
    main()
