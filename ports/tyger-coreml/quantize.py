"""Quantize the exported TygerEncoder — the shipping footprint tier.

Maps to the two prior measurements:
  * the MLX storage study's passing config (per-unit group-16 asymmetric int8,
    ~0.007 per-head on the val slice) -> `linear` int8, PER_BLOCK, block 16
    (GGUF block-affine, the Q8_0-family shape);
  * the Parakeet-GGUF prior (Q8_0 is the tier the community ships lossless)
    -> 8-bit per-channel k-means palettization as the alternative.

Norms are auto-exempt (their weights fall under the 2048-element threshold).
TygerStep (the 14M GRU + heads) stays fp32 — calibration-sensitive, tiny.

Usage: python quantize.py [--kind linear8|palettize8]   -> bench-results/coreml/TygerEncoderQ8.mlpackage
Acceptance: parity6.py --enc TygerEncoderQ8.mlpackage   (per-head ≤ 0.02)
"""
import argparse
from pathlib import Path

import coremltools as ct
from coremltools.optimize.coreml import (OpLinearQuantizerConfig, OpPalettizerConfig,
                                        OptimizationConfig, linear_quantize_weights,
                                        palettize_weights)

MODELS = Path(__file__).resolve().parents[2] / "bench-results" / "coreml"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", default="linear8", choices=["linear8", "palettize8"])
    ap.add_argument("--src", default="TygerEncoder.mlpackage")
    ap.add_argument("--out", default="TygerEncoderQ8.mlpackage")
    ap.add_argument("--granularity", default="per_block", choices=["per_block", "per_channel"],
                    help="per_channel + block 16 = per-output-unit group-16 along the contraction axis (the MLX-PASS layout)")
    args = ap.parse_args()

    m = ct.models.MLModel(str(MODELS / args.src))
    if args.kind == "linear8":
        cfg = OpLinearQuantizerConfig(mode="linear", dtype="int8",
                                      granularity=args.granularity, block_size=16)
        q = linear_quantize_weights(m, config=OptimizationConfig(global_config=cfg))
    else:
        cfg = OpPalettizerConfig(mode="kmeans", nbits=8, granularity="per_grouped_channel", group_size=32)
        q = palettize_weights(m, config=OptimizationConfig(global_config=cfg))
    q.save(str(MODELS / args.out))
    for p in (MODELS / args.src, MODELS / args.out):
        size = sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1e9
        print(f"  {p.name}: {size:.3f} GB")


if __name__ == "__main__":
    main()
