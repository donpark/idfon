"""Store the TygerStep turn-taker's recurrence as int8, keeping the calibrated heads fp32.

P0 of docs/voice-decision-model.md: the shipped decision model is 56 MB (14M
params fp32) and should not be. The GRU core (10.63M) + fuse projections
(1.57M) are stored int8 — per-output-unit group-N asymmetric along the
contraction axis, the layout that passed the S3 precision study — and
dequantized **in-graph** (DequantizeLinear), so compute stays fp32 and the
heads/norms/state-emb (the calibration-sensitive part) are bit-exact. The
export's gate-reorder/reshape chain downstream of the raw initializers is
untouched.

Gate: node ports/tyger-onnx/qstep-parity.mjs (per-head |Δ| ≤ 0.02 + decision
parity through the shared rules).

Usage:
  uv run --with onnx --with numpy python ports/tyger-onnx/quantize_step.py \
      [--group 16] [--gru-only] [--in bench-results/onnx/TygerStep.onnx] [--out ...]

Output: <out> (+ `<out>.data` external weights), default
bench-results/onnx/TygerStepInt8.onnx. `--group 0` = one scale per output row;
`--gru-only` keeps the fuse projections fp32.
"""
import argparse
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

ROOT = Path(__file__).resolve().parents[2]
GRU_PREFIXES = ("tt.core.weight_ih_l", "tt.core.weight_hh_l")
FUSE_SHAPE = (1024, 768)  # val_7 / val_9: proj_user / proj_agent as stored (in, out)


def quantize(a: np.ndarray, group: int, axis: int):
    """-> (int8 (out*G, g) or (out, in), scale f32 (out*G,), zp i8 (out*G,)) in row space.

    `axis` is the contraction axis of `a`; rows = output units after transpose.
    """
    b = a if axis == 1 else a.T  # (out, in)
    out, inn = b.shape
    g = group or inn
    assert inn % g == 0, f"in={inn} not divisible by group {g}"
    G = inn // g
    bb = b.reshape(out * G, g)
    mn, mx = bb.min(1), bb.max(1)
    scale = (mx - mn) / 255.0
    zero = scale <= 0
    scale = np.where(zero, 1.0, scale)
    zp = np.round(-mn / scale) - 128.0  # deq = (q - zp) * scale, q ∈ [-128, 127]
    zp = np.clip(zp, -128, 127)
    q = np.clip(np.round(bb / scale[:, None]) + zp[:, None], -128, 127).astype(np.int8)
    return q, scale.astype(np.float32), zp.astype(np.int8)


def quantize_init(t: TensorProto, group: int, axis: int):
    """Replace initializer t with int8 storage + DQ chain; returns the fp32 output name."""
    a = numpy_helper.to_array(t).astype(np.float32)
    out, inn = a.shape if axis == 1 else a.T.shape
    g = group or inn
    G = inn // g
    q, scale, zp = quantize(a, group, axis)
    prefix = t.name
    nodes = [
        helper.make_node(
            "DequantizeLinear",
            [f"{prefix}.q", f"{prefix}.scale", f"{prefix}.zp"],
            [f"{prefix}.dq_raw"], axis=0),
        helper.make_node(
            "Reshape", [f"{prefix}.dq_raw", f"{prefix}.shape"], [f"{prefix}.dq"]),
    ]
    inits = [
        numpy_helper.from_array(q.reshape(out * G, g), f"{prefix}.q"),
        numpy_helper.from_array(scale, f"{prefix}.scale"),
        numpy_helper.from_array(zp, f"{prefix}.zp"),
        numpy_helper.from_array(np.array([out, inn], dtype=np.int64), f"{prefix}.shape"),
    ]
    final = f"{prefix}.dq"
    if axis == 0:
        nodes.append(helper.make_node("Transpose", [final], [f"{prefix}.dqT"], perm=[1, 0]))
        final = f"{prefix}.dqT"
    return final, nodes, inits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", type=int, default=16, help="group size along the contraction axis (0 = per row)")
    ap.add_argument("--gru-only", action="store_true", help="keep the fuse projections fp32")
    ap.add_argument("--in", dest="src", default=str(ROOT / "bench-results/onnx/TygerStep.onnx"))
    ap.add_argument("--out", dest="dst", default=None)
    args = ap.parse_args()
    dst = Path(args.dst or Path(args.src).with_name("TygerStepInt8.onnx"))

    m = onnx.load(args.src)  # loads external .data into memory
    by_name = {t.name: t for t in m.graph.initializer}

    targets = []  # (tensor, contract axis)
    for t in m.graph.initializer:
        if t.name.startswith(GRU_PREFIXES):
            targets.append((t, 1))
        elif not args.gru_only and tuple(t.dims) == FUSE_SHAPE:
            targets.append((t, 0))
    assert targets, "no quantization targets found — wrong model?"

    new_nodes, new_inits = [], []
    renamed = {}
    for t, axis in targets:
        final, nodes, inits = quantize_init(t, args.group, axis)
        renamed[t.name] = final
        new_nodes += nodes
        new_inits += inits
    for t, _ in targets:
        m.graph.initializer.remove(by_name[t.name])
    m.graph.initializer.extend(new_inits)
    for n in m.graph.node:
        for i, name in enumerate(n.input):
            if name in renamed:
                n.input[i] = renamed[name]
    m.graph.node.extend(new_nodes)

    for t in m.graph.initializer:  # reset external-data metadata before re-saving
        t.data_location = TensorProto.DEFAULT
        del t.external_data[:]
    if dst.exists():
        dst.unlink()
    data = dst.with_suffix(dst.suffix + ".data")
    if data.exists():
        data.unlink()
    onnx.save_model(m, str(dst), save_as_external_data=True, all_tensors_to_one_file=True,
                    location=data.name, size_threshold=1024)  # small constants inline: ORT shape inference cannot read external data for them

    def mb(p): return p.stat().st_size / 1e6
    n_params = sum(np.prod(numpy_helper.to_array(by_name[t.name]).shape) for t, _ in targets)
    print(f"quantized {len(targets)} tensors ({n_params / 1e6:.2f}M params, group-{args.group or 'row'}, "
          f"{'gru-only' if args.gru_only else 'gru+fuse'}):")
    for t, axis in targets:
        print(f"  {t.name:24s} {tuple(t.dims)}  axis={axis}")
    print(f"wrote {dst.name} {mb(dst):.1f} MB + {data.name} {mb(data):.1f} MB "
          f"(was {mb(Path(args.src)) + mb(Path(args.src).with_suffix('.onnx.data')):.1f} MB)")


if __name__ == "__main__":
    main()
