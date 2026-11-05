"""Export the student decision model to Core ML — the apps' delivery tier
(docs/voice-tyger-ondevice.md's tier table). Same I/O contract as
ports/tyger-coreml/export.py's TygerStep, at the student's sizes:

  StudentStep   hu (1,1,1024), ha (1,1,1024), act_db (1,1), prev_state (1,1 int32),
                state (2,1,256) -> decision_vector (1,1,8), gru_state_next (2,1,256)

fp32 by default: the shipping step tier is fp32 (the ANE fp16 defect family and the
p_end drift rulings — docs/voice-tyger-ondevice.md, coreml-ane-precision). `--precision
float16` exists for study only. Energy normalisation is in-graph (head_step semantics).

Parity: Core ML vs torch over real shard frames with carried state (the live path).
Gate: max|d| <= 0.01 (the pathc student gate; fp32 lands ~1e-5). Note the conversion
renames the `state` input/output (pathc met `state_workaround`) — I/O is matched by
SHAPE here, not by name.

Usage:  .venv/bin/python ports/tyger-student/export_coreml.py [--student ...]
        [--shards bench-results/student-shards/val] [--frames 248] [--precision float32]
Output: bench-results/student-coreml/StudentStep.mlpackage + parity.md
"""
import argparse
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]

from export import StepWrap, load_student  # noqa: E402

GATE = 0.01          # fp32: the pathc student gate (fp32 lands ~1e-5)
INT8_GATE = 2e-3     # int8: P4's envelope (per-head probs) — a different grid, gated as such


def convert(step, width, layers, precision="float32"):
    """-> MLModel for the step: fp16 changes compute precision; `int8` quantizes the
    converted model's *weights* (coremltools' linear scheme: symmetric, per-block-16 —
    NOT the ONNX/QAT asymmetric per-output-unit grid, so it is its own rung; the P7
    matrix gates it as such). `state` is a reserved Core ML name, so I/O is matched by
    shape downstream (io_by_shape)."""
    import coremltools as ct
    import torch

    hua = torch.zeros(1, 1, 1024)
    act = torch.zeros(1, 1)
    prev = torch.zeros(1, 1, dtype=torch.long)
    state = torch.zeros(layers, 1, width)
    prec = ct.precision.FLOAT16 if precision == "float16" else ct.precision.FLOAT32
    ml = ct.convert(torch.jit.trace(step, (hua, hua, act, prev, state), strict=False),
                    inputs=[ct.TensorType(name="hu", shape=hua.shape),
                            ct.TensorType(name="ha", shape=hua.shape),
                            ct.TensorType(name="act_db", shape=act.shape),
                            ct.TensorType(name="prev_state", shape=prev.shape, dtype=np.int32),
                            ct.TensorType(name="state", shape=state.shape)],
                    compute_precision=prec, compute_units=ct.ComputeUnit.ALL,
                    minimum_deployment_target=ct.target.iOS18)
    if precision == "int8":
        from coremltools.optimize.coreml import (OpLinearQuantizerConfig,
                                                 OptimizationConfig,
                                                 linear_quantize_weights)
        cfg = OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8",
                                      granularity="per_block", block_size=16,
                                      weight_threshold=1024)
        ml = linear_quantize_weights(ml, config=OptimizationConfig(global_config=cfg))
    return ml


def io_by_shape(spec_io, width, layers, expect):
    """Map the conversion's (possibly renamed) I/O to their roles by shape."""
    named = {i.name: tuple(i.type.multiArrayType.shape) for i in spec_io}
    state_shape = (layers, 1, width)
    got = {}
    for name, shape in named.items():
        if shape == (1, 1, 1024):
            got["hu" if "hu" not in got else "ha"] = name
        elif shape == (1, 1):
            got["act_db" if "act_db" not in got else "prev_state"] = name
        elif shape == state_shape:
            got["state"] = name
        elif shape == (1, 1, 8):
            got["out"] = name
    missing = expect - set(got)
    assert not missing, f"could not locate {missing} by shape; conversion gave {named}"
    return got


def main():
    import coremltools as ct
    import torch

    ap = argparse.ArgumentParser()
    ap.add_argument("--student", default=str(ROOT / "bench-results/student/student.pt"))
    ap.add_argument("--shards", default=str(ROOT / "bench-results/student-shards/val"))
    ap.add_argument("--frames", type=int, default=248)
    ap.add_argument("--precision", default="float32", choices=["float32", "float16", "int8"])
    ap.add_argument("--tap", default=None,
                    help="shared checkpoints: adapter to prune to (default: the checkpoint's deploy tap)")
    ap.add_argument("--out", default=str(ROOT / "bench-results/student-coreml"))
    args = ap.parse_args()

    model, tap = load_student(args.student, tap=args.tap)
    step = StepWrap(model, tap).eval()
    width, layers = model.width, model.layers

    ml = convert(step, width, layers, args.precision)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    pkg = out / "StudentStep.mlpackage"
    ml.save(str(pkg))
    size = sum(f.stat().st_size for f in pkg.rglob("*") if f.is_file()) / 1e6
    print(f"saved {pkg.name} ({size:.1f} MB, {args.precision})")

    from data import iter_shards
    _p, frames, _l, _e, meta = next(iter_shards(args.shards))
    n = min(args.frames, len(frames["energy"]))
    cm = ct.models.MLModel(str(pkg))
    ins = io_by_shape(cm.get_spec().description.input, width, layers,
                      expect={"hu", "ha", "act_db", "prev_state", "state"})
    outs = io_by_shape(cm.get_spec().description.output, width, layers,
                       expect={"out", "state"})

    st_t = torch.zeros(layers, 1, width)
    st_c = np.zeros((layers, 1, width), np.float32)
    worst = state_worst = 0.0
    with torch.no_grad():
        for f in range(n):
            a = torch.tensor([[float(frames["energy"][f])]])
            ps = torch.tensor([[int(frames["prev_state"][f])]])
            o_t, st_t = step(torch.as_tensor(frames["hu"][f])[None, None],
                             torch.as_tensor(frames["ha"][f])[None, None], a, ps, st_t)
            res = cm.predict({
                ins["hu"]: frames["hu"][f][None, None].astype(np.float32),
                ins["ha"]: frames["ha"][f][None, None].astype(np.float32),
                ins["act_db"]: np.array([[float(frames["energy"][f])]], np.float32),
                ins["prev_state"]: np.array([[int(frames["prev_state"][f])]], np.int32),
                ins["state"]: st_c,
            })
            o_c = np.asarray(res[outs["out"]])[0, 0].astype(np.float64)
            st_c = np.asarray(res[outs["state"]]).astype(np.float32)
            worst = max(worst, float(np.abs(o_c - o_t[0, 0].numpy().astype(np.float64)).max()))
            state_worst = max(state_worst, float(np.abs(st_c - st_t.numpy()).max()))
    gate = INT8_GATE if args.precision == "int8" else GATE
    ok = worst <= gate
    print(f"parity on {n} real frames (carried state, {meta['session_id'][:16]}…): "
          f"out max|d| {worst:.2e} (gate {gate:.0e}), state max|d| {state_worst:.2e}  "
          f"{'PASS' if ok else 'FAIL'}")
    (out / "parity.md").write_text(
        f"# StudentStep Core ML parity ({args.precision})\n\n"
        f"- checkpoint: {args.student}\n- frames: {n} from {meta['session_id']} (carried state)\n"
        f"- out max|d|: {worst:.2e} (gate {gate:.0e})\n- state max|d|: {state_worst:.2e}\n"
        f"- size: {size:.1f} MB\n")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
