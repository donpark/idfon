#!/usr/bin/env python3
"""S2 parity: MLX turn-taker vs the torch bundle's, and the full decision chain.

    .venv/bin/python ports/tyger-mlx/parity2.py [--wav clip.wav]

Three checks on real encoder features:
1. GRU batch parity — torch `TurnTaker.forward` vs MLX `TurnTaker.forward`;
2. GRU *stepped* parity — MLX one frame at a time with carried state (the live
   path) must match its own batch evaluation and torch;
3. full chain — MLX EncoderL15 + MLX TurnTaker per frame vs torch ReferenceEars
   internals (`encode_l15` + `head_step`), the per-frame 8-vectors the rules read.

Acceptance (docs/voice-tyger-ondevice.md): per-head |Δscore| ≤ 0.02 (we expect ≪).
"""
import argparse
import os
import sys
import time
from pathlib import Path

import numpy as np

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE", os.path.expanduser(
    "~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6"))
sys.path.insert(0, S2S)
sys.path.insert(0, os.path.join(S2S, "scripts"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))

import mlx.core as mx  # noqa: E402
import torch  # noqa: E402

from app.plugins.ears.tyger.bundle import load  # noqa: E402
from app.plugins.ears.tyger.constants import L15, SR  # noqa: E402
from encoder import EncoderL15  # noqa: E402
from turn_taker import TurnTaker, LAYERS, WIDTH  # noqa: E402


def main():
    ap_ = argparse.ArgumentParser()
    ap_.add_argument("--wav", default=None)
    args = ap_.parse_args()

    if args.wav:
        import wave
        with wave.open(args.wav) as w:
            x = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768.0
    else:
        x = np.random.default_rng(7).normal(0, 0.1, SR * 2).astype(np.float32)
    x = x[: SR * 2]

    torch.set_num_threads(4)
    asr, proc, tt, _ = load(Path(BUNDLE))
    inp = proc(x, sampling_rate=SR, return_tensors="pt")
    feats = inp["input_features"]

    # Real per-frame features from the torch encoder (encoder parity proven separately).
    with torch.no_grad():
        eo = asr.encoder(input_features=feats, attention_mask=None, num_lookahead_tokens=0, output_hidden_states=True)
    hu = eo.hidden_states[L15][0].float()  # (T, 1024)
    T = hu.shape[0]
    ha = torch.zeros_like(hu)
    rng = np.random.default_rng(11)
    act = torch.tensor(rng.uniform(-3, 3, (1, T)), dtype=torch.float32)  # already normalised
    prev = torch.tensor(rng.integers(0, 2, (1, T)), dtype=torch.long)

    with torch.no_grad():
        ref, _ = tt(hu[None], ha[None], act, prev)  # (1, T, 8)
    ref = ref[0].numpy()

    tt_m = TurnTaker(BUNDLE)
    hu_m, ha_m, act_m, prev_m = mx.array(hu.numpy())[None], mx.array(ha.numpy())[None], mx.array(act.numpy()), mx.array(prev.numpy())
    out_b, _ = tt_m.forward(hu_m, ha_m, act_m, prev_m)
    d_batch = np.abs(np.array(out_b)[0] - ref)

    # stepped (the live path): one frame at a time, carried state
    outs, state = [], None
    for k in range(T):
        o, state = tt_m.step(hu_m[:, k:k + 1], ha_m[:, k:k + 1], act_m[:, k:k + 1], prev_m[:, k:k + 1], state)
        outs.append(np.array(o)[0, 0])
    d_step = np.abs(np.array(outs) - ref)

    names = ["state0", "state1", "state2", "state3", "hazard", "yield", "bc", "ep"]
    print(f"frames: {T}")
    print(f"GRU batch:  max|d| {d_batch.max():.3e}")
    print(f"GRU stepped (live path): max|d| {d_step.max():.3e}")
    for i, n in enumerate(names):
        print(f"  head {n:7} batch {d_batch[:, i].max():.2e}   stepped {d_step[:, i].max():.2e}")

    # full chain on one hop: MLX encoder + stepped GRU vs torch ReferenceEars internals
    sys.path.insert(0, os.path.join(S2S, "scripts"))
    from validate.reference import ReferenceEars
    ears = ReferenceEars(BUNDLE, device="cpu")
    hop = x[1000:1000 + 5120].copy() if len(x) > 6120 else x[:5120].copy()
    hu_t = ears.encode_l15(hop)  # (frames, 1024) torch
    ha_t = ears.encode_l15(np.zeros(5120, np.float32))
    enc_m = EncoderL15(BUNDLE, layers=L15, precision=os.environ.get("TYGER_MLX_PRECISION", "fp32"))
    f_u = proc(hop, sampling_rate=SR, return_tensors="pt")["input_features"]
    f_a = proc(np.zeros(5120, np.float32), sampling_rate=SR, return_tensors="pt")["input_features"]
    hu_m1 = enc_m(mx.array(f_u.numpy()))[0]
    ha_m1 = enc_m(mx.array(f_a.numpy()))[0]
    dc = np.abs(np.array(hu_m1) - hu_t.numpy()).max()
    print(f"\nfull chain: encoder L15 max|d| {dc:.3e} over {hu_m1.shape[0]} frames")
    state = None
    worst = 0.0
    for k in range(min(hu_m1.shape[0], hu_t.shape[0])):
        o_t = ears.head_step(hu_t[k], ha_t[k], 0.0, 0)  # torch reference frame
        o_m, state = tt_m.step(hu_m1[k:k + 1][None], ha_m1[k:k + 1][None],
                               mx.array([[(0.0 + 50) / 25]]), mx.array([[0]]), state)  # head_step normalises act
        worst = max(worst, float(np.abs(np.array(o_m)[0, 0] - o_t).max()))
    print(f"full chain: per-frame 8-vector max|d| {worst:.3e}   ({'PASS' if worst <= 0.02 else 'FAIL'}, budget 0.02)")

    ts = []
    for _ in range(20):
        t0 = time.perf_counter()
        tt_m.step(hu_m[:, 0:1], ha_m[:, 0:1], act_m[:, 0:1], prev_m[:, 0:1], state)
        mx.eval(mx.array(0))
        ts.append(time.perf_counter() - t0)
    print(f"timing: GRU step {min(ts) * 1000:.3f} ms/frame")


if __name__ == "__main__":
    main()
