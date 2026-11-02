"""Export the student decision model to ONNX — the size rung of the P1 brief
(docs/voice-decision-model.md): 5.3 MB fp32 checkpoint -> ~1.3 MB int8 shipping artifact.

Contract mirrors ports/tyger-onnx/export_step.py's TygerStep 1:1 — the same 8-vector
seam, energy normalization ((act_db+50)/25 clamp) baked in (head_step semantics):

  StudentStep   hu (1,1,1024), ha (1,1,1024), act_db (1,1), prev_state (1,1 int64),
                state (2,1,256) -> out (1,1,8), state_out (2,1,256)

State width/depth differ from the teacher's (2x256 vs 3x768) — the seam is the
8-vector, the state plumbing is per-model.

--quantize (default on) applies ports/tyger-onnx/quantize_step.py's P0 pattern to the
student: GRU core + fuse projections stored int8 per-output-unit group-16, dequantized
in-graph (compute stays fp32; heads/norms/state-emb bit-exact). Both variants are then
gated against the torch model over real shard frames: fp32 max|d| <= 1e-4 (the teacher's
step-parity gate), int8 per-slot probs <= 2e-3 (its qstep envelope). QAT is only needed
if these gates fail.

Usage:
  .venv/bin/python ports/tyger-student/export.py [--student bench-results/student/student.pt]
      [--shards bench-results/student-shards/val] [--frames 248] [--group 16] [--no-quantize]
Output: bench-results/student-onnx/StudentStep{,Int8}.onnx (+ .data) + parity.md
"""
import argparse
import importlib.machinery
import os
import sys
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
import torch.nn as nn

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from model import Student  # noqa: E402
from registry import HEADS, by_id, seam_heads  # noqa: E402

FP32_GATE = 1e-4
INT8_GATE = 2e-3  # per-slot probs; the teacher's qstep envelope
TRAIT_THRS = {5: 0.4, 6: 0.4, 7: 0.85}  # yield/bc/p_end at the student's traits: crossing flips are the rules-visible errors


class StepWrap(nn.Module):
    """The student as a single step graph. Thin delegation (like the teacher's
    ports/tyger-coreml StepWrap): the Core AI converter mis-fuses ops inlined at the
    top-level forward, so the math stays inside the submodule calls."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, hu, ha, act_db, prev_state, state):
        outs, state = self.model(hu, ha, act_db, prev_state, state)
        return self.model.eight_vector(outs), state


def load_student(path):
    ckpt = torch.load(path, map_location="cpu")
    model = Student([by_id(i) for i in ckpt["heads"]], width=ckpt["width"], layers=ckpt["layers"])
    model.load_state_dict(ckpt["state_dict"])
    model.eval()
    return model


def quantize_student(src, dst, group):
    """quantize_step.py's pattern, student targeting. The classic exporter hoists MatMul/GRU
    weights into anonymous initializers, so target by shape: ONNX-GRU W/R (1, 3h, h) and
    the fuse projections as stored (in, out). proj_energy (1,h) stays fp32 (teacher's rule:
    heads/norms/emb/fuse-biases bit-exact, recurrence + big fuse stored int8)."""
    qs = importlib.machinery.SourceFileLoader(
        "quantize_step", str(ROOT / "ports" / "tyger-onnx" / "quantize_step.py")).load_module()
    from onnx import TensorProto, numpy_helper

    m = onnx.load(str(src))
    width = None
    for t in m.graph.initializer:
        if t.name == "model.state_emb.weight":
            width = int(t.dims[1])
    assert width, "state_emb not found — wrong export?"

    targets = []  # (tensor, contract axis, flat dims or None)
    for t in m.graph.initializer:
        d = tuple(t.dims)
        if len(d) == 3 and d[0] == 1 and d[1] == 3 * width and d[2] == width:
            targets.append((t, 1, (d[1], d[2])))        # GRU W/R (1, 3h, h): rows = output units
        elif d == (1024, width):
            targets.append((t, 0, None))                 # proj_user/proj_agent (in, out)
    assert targets, "no quantization targets found — wrong export?"
    new_nodes, new_inits, renamed = [], [], {}
    for t, axis, flat in targets:
        t2d = t
        if flat:
            t2d = TensorProto()
            t2d.CopyFrom(t)
            del t2d.dims[:]
            t2d.dims.extend(flat)
        final, nodes, inits = qs.quantize_init(t2d, group, axis)
        if flat:  # keep the GRU's rank-3 shape in the dequantize chain
            for arr in inits:
                if arr.name.endswith(".shape"):
                    arr.CopyFrom(numpy_helper.from_array(
                        np.array(list(t.dims), dtype=np.int64), arr.name))
        renamed[t.name] = final
        new_nodes += nodes
        new_inits += inits
    names = {t.name for t, _, _ in targets}
    for t in [t for t in m.graph.initializer if t.name in names]:
        m.graph.initializer.remove(t)
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
                    location=data.name, size_threshold=1024)
    return len(targets), sum(int(np.prod(t.dims)) for t, _, _ in targets)


def run_frames(wrap, sess, frames, width, layers):
    """Thread frames through torch and ORT separately; -> (torch outs, onnx outs, final state |d|)."""
    outs_t, outs_o = [], []
    st_t = torch.zeros(layers, 1, width)
    st_o = np.zeros((layers, 1, width), np.float32)
    with torch.no_grad():
        for hu, ha, act, prev in frames:
            t = (torch.tensor([[hu.tolist()]]), torch.tensor([[ha.tolist()]]),
                 torch.tensor([[act]]), torch.tensor([[prev]], dtype=torch.long), st_t)
            o_t, st_t = wrap(*t)
            o_o, st_o = sess.run(None, {"hu": t[0].numpy(), "ha": t[1].numpy(),
                                        "act_db": t[2].numpy(), "prev_state": t[3].numpy(),
                                        "state": st_o})
            outs_t.append(o_t[0, 0].numpy().copy())
            outs_o.append(np.asarray(o_o[0, 0]).copy())
    return outs_t, outs_o, float(np.abs(st_t.numpy() - st_o).max())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--student", default=str(ROOT / "bench-results/student/student.pt"))
    ap.add_argument("--shards", default=None, help="real frames for the parity gate (default: seeded random)")
    ap.add_argument("--frames", type=int, default=248)
    ap.add_argument("--group", type=int, default=16)
    ap.add_argument("--out", default=str(ROOT / "bench-results/student-onnx"))
    ap.add_argument("--no-quantize", action="store_true")
    args = ap.parse_args()

    model = load_student(args.student)
    wrap = StepWrap(model).eval()
    width, layers = model.width, model.layers

    # sanity: StepWrap == Student.forward + eight_vector (the norm/assembly is in the graph)
    with torch.no_grad():
        hu = torch.randn(1, 2, 1024) * 0.5
        ha = torch.randn(1, 2, 1024) * 0.5
        act = torch.rand(1, 2) * 60 - 40
        prev = torch.randint(0, 5, (1, 2))
        o_w, _ = wrap(hu, ha, act, prev, torch.zeros(layers, 1, width))
        outs, _ = model(hu, ha, act, prev)
        o_t = model.eight_vector(outs)
    assert (o_w - o_t).abs().max() < 1e-6, "StepWrap != Student.forward + eight_vector"

    if args.shards:
        from data import iter_shards
        _p, frames, _l, _e, meta = next(iter_shards(args.shards))
        n = min(args.frames, len(frames["energy"]))
        rng = list(zip(frames["hu"][:n], frames["ha"][:n], frames["energy"][:n],
                       frames["prev_state"][:n]))
        src = f"shard {meta['session_id'][:16]} ({n} frames)"
    else:
        g = torch.Generator().manual_seed(0)
        rng = list(zip(torch.randn(args.frames, 1024, generator=g).numpy() * 0.5,
                       torch.randn(args.frames, 1024, generator=g).numpy() * 0.5,
                       (torch.rand(args.frames, generator=g).numpy() * 60 - 40),
                       torch.randint(0, 5, (args.frames,), generator=g).numpy()))
        src = f"seeded random ({args.frames} frames)"

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    onnx_path = out / "StudentStep.onnx"
    ex = (torch.zeros(1, 1, 1024), torch.zeros(1, 1, 1024), torch.zeros(1, 1),
          torch.zeros(1, 1, dtype=torch.long), torch.zeros(layers, 1, width))
    torch.onnx.export(wrap, ex, str(onnx_path),
                      input_names=["hu", "ha", "act_db", "prev_state", "state"],
                      output_names=["out", "state_out"], dynamo=False)
    print(f"wrote {onnx_path.name} ({onnx_path.stat().st_size / 1e6:.2f} MB)")

    def mb(p):
        return p.stat().st_size / 1e6 if p.exists() else 0.0

    def gate(path, label, limit):
        sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
        outs_t, outs_o, st_diff = run_frames(wrap, sess, rng, width, layers)
        a_t, a_o = np.stack(outs_t), np.stack(outs_o)
        probs = float(np.abs(a_t[:, 4:] - a_o[:, 4:]).max())   # hazard/yield/bc/p_end: the calibrated part
        logits = float(np.abs(a_t[:, :4] - a_o[:, :4]).max())  # state logits: reported, gated via flips
        flips = int((a_t[:, :4].argmax(1) != a_o[:, :4].argmax(1)).sum())
        thr_flips = {s: int(((a_t[:, s] >= t) != (a_o[:, s] >= t)).sum()) for s, t in TRAIT_THRS.items()}
        ok = probs <= limit
        print(f"{label}: probs max|d| {probs:.2e} (gate {limit:.0e}), state-logits {logits:.2e}, "
              f"argmax flips {flips}, threshold flips {thr_flips}, state max|d| {st_diff:.2e}  "
              f"{'PASS' if ok else 'FAIL'}")
        return probs, logits, flips, thr_flips, st_diff

    lines = [f"# StudentStep ONNX parity ({src})", "",
             f"checkpoint: {os.path.relpath(args.student, ROOT)}  |  {width}x{layers} GRU", ""]
    w, lg, fl, tfl, st = gate(onnx_path, "fp32 vs torch", FP32_GATE)
    lines += [f"- **fp32**: probs max|d| {w:.2e} (gate {FP32_GATE:.0e}), state-logits {lg:.2e}, "
              f"argmax flips {fl}, threshold flips {tfl}, state max|d| {st:.2e}",
              f"- sizes: StudentStep.onnx {mb(onnx_path):.2f} MB + .data "
              f"{mb(onnx_path.with_suffix('.onnx.data')):.2f} MB"]

    if not args.no_quantize:
        int8_path = out / "StudentStepInt8.onnx"
        n_t, n_p = quantize_student(onnx_path, int8_path, args.group)
        print(f"quantized {n_t} tensors ({n_p / 1e6:.2f}M params, group-{args.group}) -> {int8_path.name}")
        w8, lg8, fl8, tfl8, st8 = gate(int8_path, "int8 vs torch", INT8_GATE)
        lines += [f"- **int8 group-{args.group}** ({n_p / 1e6:.2f}M params): probs max|d| {w8:.2e} "
                  f"(gate {INT8_GATE:.0e}), state-logits {lg8:.2e}, argmax flips {fl8}, "
                  f"threshold flips {tfl8}, state max|d| {st8:.2e}",
                  f"- sizes: StudentStepInt8.onnx {mb(int8_path):.2f} MB + .data "
                  f"{mb(int8_path.with_suffix('.onnx.data')):.2f} MB"]
    (out / "parity.md").write_text("\n".join(lines) + "\n")
    print(f"wrote {out / 'parity.md'}")


if __name__ == "__main__":
    main()
