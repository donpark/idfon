#!/usr/bin/env python3
"""Export the accepted MLX chain's weights for the Swift MLX runtime (mac tier —
the platform-split ruling in docs/voice-tyger-ondevice.md).

One fp32 safetensors, `bench-results/mlx/TygerChainInt8.safetensors`:
  enc.* = the L15 encoder prepped with the accepted config (per-output-unit
          group-16 asymmetric int8, quantise->dequantise to fp32; stem +
          layers.0 kept fp32 — the only config that ever passed the 0.02
          budget, see prep_weights)
  tt.*  = the 14M turn-taker as loaded (fp32; never quantised)

The quantisation is baked in as dequantised fp32, so the Swift GEMMs are plain
fp32 matmuls that reproduce the accepted arithmetic exactly — no quantisation
code in Swift.

Usage:
  python export_swift.py [--check]   # --check: reload and assert exactness
"""
import argparse
import os
import sys
from pathlib import Path

import mlx.core as mx

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from encoder import EncoderL15, load_encoder_weights, prep_weights  # noqa: E402
from turn_taker import TurnTaker, load_turn_weights  # noqa: E402

BUNDLE = os.environ.get("TYGER_BUNDLE", os.path.expanduser(
    "~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6"))
OUT = Path(HERE).resolve().parents[1] / "bench-results" / "mlx" / "TygerChainInt8.safetensors"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    enc_w = prep_weights(load_encoder_weights(BUNDLE, 15), "int8")
    tt_w = load_turn_weights(BUNDLE)
    tensors = {**{f"enc.{k}": v for k, v in enc_w.items()},
               **{f"tt.{k}": v for k, v in tt_w.items()}}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(str(OUT), tensors)
    n = sum(v.size for v in tensors.values())
    print(f"wrote {OUT}  tensors={len(tensors)}  params={n / 1e6:.1f}M")

    if not args.check:
        return
    # reload and prove the artifact alone reproduces the accepted chain exactly
    loaded = mx.load(str(OUT))
    enc2 = EncoderL15(weights={k[4:]: v for k, v in loaded.items() if k.startswith("enc.")})
    tt2 = TurnTaker(weights={k[3:]: v for k, v in loaded.items() if k.startswith("tt.")})
    enc1, tt1 = EncoderL15(BUNDLE, precision="int8"), TurnTaker(BUNDLE)

    mx.random.seed(0)
    feats = mx.random.normal((1, 25, 128))
    d = mx.abs(enc1(feats) - enc2(feats)).max().item()
    print(f"encoder max|Δ| = {d}")
    assert d == 0.0, "artifact encoder differs from the accepted chain"

    hu, ha = mx.random.normal((1, 1, 1024)), mx.random.normal((1, 1, 1024))
    act, ps = mx.array([[0.5]]), mx.array([[0]])
    o1, _ = tt1.step(hu, ha, act, ps, None)
    o2, _ = tt2.step(hu, ha, act, ps, None)
    d = mx.abs(o1 - o2).max().item()
    print(f"step    max|Δ| = {d}")
    # the .T weight views vs the reloaded contiguous copies can pick different
    # Metal GEMM paths: bit-exactness is not guaranteed across layouts
    assert d < 1e-5, "artifact turn-taker differs from the accepted chain"
    print("CHECK OK — the artifact is the accepted chain (to fp noise)")


if __name__ == "__main__":
    main()
