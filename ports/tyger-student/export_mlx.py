"""Export the student decision model to MLX — the mac tier of the four-tier P7 matrix
(docs/voice-tyger-ondevice.md: macOS 14–26 runs MLX int8-g16; the student replaces the
teacher step there exactly as ONNX/CoreML/Core AI do).

Same I/O contract and same weight grid as `export.py`'s ONNX step, one frame in:

  StudentStep  hu (1024,), ha (1024,), act_db (), prev_state (), state (layers,1,width)
               -> decision_vector (8,), state_next (layers,1,width)

The int8 rung is the MLX convention the S3 precision study established (storage int8
per-output-unit group-16 along the contraction axis, dequantised at load; compute
stays fp32, heads/norms/state-emb stored fp32). The grid is `ports/tyger-onnx/
quantize_step.py`'s `quantize()` — the same call QAT projects onto (`qat.py`'s
selfcheck proves the two bit-identical) — so a QAT-trained student is bit-exact
here too. `group=0` = one scale per output row; `None` = fp32.

Usage:
  .venv/bin/python ports/tyger-student/export_mlx.py [--student bench-results/student/student.pt]
      [--tap l4-streaming] [--shards bench-results/tap4-shards/val] [--frames 248]
      [--group 16] [--no-quantize] [--out bench-results/student-mlx]
Output: <out>/StudentStep{,Int8}.safetensors + parity.md
"""
import argparse
import importlib.machinery
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]

FP32_GATE = 1e-4
INT8_GATE = 2e-3  # per-slot probs; the teacher's qstep envelope
TRAIT_THRS = {5: 0.4, 6: 0.4, 7: 0.85}  # yield/bc/p_end in 8-vector slot order

_qs = None


def _quantize_step():
    global _qs
    if _qs is None:
        _qs = importlib.machinery.SourceFileLoader(
            "quantize_step", str(ROOT / "ports" / "tyger-onnx" / "quantize_step.py")).load_module()
    return _qs


def quant_targets(state_dict):
    """export.py's quantization targets in torch layout: (out, in), contraction axis 1
    (GRU W/R and every adapter projection; heads/norms/emb/energy bias stay fp32)."""
    out = []
    for k, v in state_dict.items():
        if k.startswith("core.weight_"):
            assert v.ndim == 2, (k, v.shape)          # (3H, H)
            out.append(k)
        elif k.startswith("adapters.") and k.endswith((".user.weight", ".agent.weight")):
            assert v.ndim == 2 and v.shape[0] < v.shape[1], (k, v.shape)   # (width, 1024)
            out.append(k)
    return out


def export(model, path, group=16):
    """Write the step's weights as safetensors: int8 q/scale/zp for the target
    tensors (row space (out*G, g) + shape), fp32 for everything else."""
    from safetensors.numpy import save_file

    sd = {k: v.detach().cpu().numpy() for k, v in model.state_dict().items()}
    targets = set(quant_targets(sd)) if group else set()
    arrays = {}
    for k, v in sd.items():
        if k in targets:
            q, scale, zp = _quantize_step().quantize(v.astype(np.float32), group, 1)
            arrays[f"{k}.q"], arrays[f"{k}.scale"], arrays[f"{k}.zp"] = q, scale, zp
            arrays[f"{k}.shape"] = np.array(v.shape, np.int64)
        else:
            arrays[k] = v.astype(np.float32)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    save_file(arrays, str(path), metadata={
        "format": "student-step-mlx-1", "group": str(group),
        "quantized": ",".join(sorted(targets))})
    return path


def _weights(arrays):
    """safetensors dict -> {param: dequantised fp32 torch-layout array}."""
    w = {}
    for k in list(arrays):
        if k.endswith(".q"):
            name = k[:-2]
            q, scale, zp = arrays[k], arrays[f"{name}.scale"], arrays[f"{name}.zp"]
            deq = (q.astype(np.float32) - zp.astype(np.float32)[:, None]) * scale[:, None]
            w[name] = deq.reshape(tuple(arrays[f"{name}.shape"]))
        elif not k.endswith((".scale", ".zp", ".shape")):
            w[k] = arrays[k]
    return w


class MLXStep:
    """The pruned SharedLatentStudent as MLX ops, one frame at a time (the live path)."""

    def __init__(self, weights, width, layers, heads):
        import mlx.core as mx

        self.mx = mx
        self.w, self.width, self.layers = weights, width, layers
        self.mw = {k: mx.array(v) for k, v in weights.items()}  # the runtime's load step
        mx.eval(*self.mw.values())
        self.heads = heads  # [(head_id, kind, size)] in seam order
        # shared checkpoints carry per-tap adapters; the single-tap Student has proj_*
        prefix = next((k.split(".")[1] for k in weights if k.startswith("adapters.")), None)
        self.user = f"adapters.{prefix}.user" if prefix else "proj_user"
        self.agent = f"adapters.{prefix}.agent" if prefix else "proj_agent"

    def _lin(self, x, name):
        return x @ self.mw[f"{name}.weight"].T + self.mw[f"{name}.bias"]

    def _gru(self, x, h, layer):
        mx = self.mx
        d = self.width
        wi = self.mw[f"core.weight_ih_l{layer}"]
        wh = self.mw[f"core.weight_hh_l{layer}"]
        bi = self.mw[f"core.bias_ih_l{layer}"]
        bh = self.mw[f"core.bias_hh_l{layer}"]
        xr, xz, xn = (x @ wi[i * d:(i + 1) * d].T + bi[i * d:(i + 1) * d] for i in range(3))
        hr, hz, hn = (h @ wh[i * d:(i + 1) * d].T + bh[i * d:(i + 1) * d] for i in range(3))
        r = mx.sigmoid(xr + hr)
        z = mx.sigmoid(xz + hz)
        n = mx.tanh(xn + r * hn)
        return (1 - z) * n + z * h

    def step(self, hu, ha, act_db, prev_state, state):
        mx = self.mx
        act = np.clip((float(act_db) + 50.0) / 25.0, -3.0, 3.0)
        z = (self._lin(mx.array(hu.astype(np.float32)), self.user)
             + self._lin(mx.array(ha.astype(np.float32)), self.agent)
             + self._lin(mx.array(np.array([act], np.float32)), "proj_energy")
             + self.mw["state_emb.weight"][int(prev_state)])
        x = mx.fast.layer_norm(z, self.mw["in_norm.weight"], self.mw["in_norm.bias"], 1e-5)
        new = []
        for i in range(self.layers):
            x = self._gru(x, mx.array(state[i, 0].astype(np.float32)), i)
            new.append(x[None, None, :])
        h = mx.fast.layer_norm(x, self.mw["out_norm.weight"], self.mw["out_norm.bias"], 1e-5)
        parts = []
        for hid, kind, _size in self.heads:
            o = self._lin(h, f"heads.{hid}")
            parts.append(o if kind == "choice" else mx.sigmoid(o))
        out = mx.concatenate(parts, axis=-1)
        st = mx.concatenate(new, axis=0)
        mx.eval(out, st)
        return np.asarray(out, np.float64), np.asarray(st, np.float32)


def load_step(path, width=None, layers=None, heads=None):
    """-> step(hu, ha, act_db, prev_state, state) -> (out8, state). Width/layers/heads
    come from the artifact itself (shape keys) unless supplied."""
    from safetensors import safe_open

    from registry import seam_heads

    with safe_open(str(path), framework="np") as f:
        arrays = {k: f.get_tensor(k) for k in f.keys()}
    w = _weights(arrays)
    width = width or int(w["in_norm.weight"].shape[0])
    layers = layers or len([k for k in w if k.startswith("core.weight_ih_l")])
    heads = heads or [(h.id, h.kind, h.size) for h in seam_heads()]
    mlx_step = MLXStep(w, width, layers, heads)
    return mlx_step.step


def main():
    import torch

    from data import iter_shards
    from export import load_student
    from registry import seam_heads

    ap = argparse.ArgumentParser()
    ap.add_argument("--student", default=str(ROOT / "bench-results/student/student.pt"))
    ap.add_argument("--tap", default=None,
                    help="shared checkpoints: adapter to prune to (default: the checkpoint's deploy tap)")
    ap.add_argument("--shards", default=None, help="real frames for the parity gate")
    ap.add_argument("--frames", type=int, default=248)
    ap.add_argument("--group", type=int, default=16)
    ap.add_argument("--no-quantize", action="store_true")
    ap.add_argument("--out", default=str(ROOT / "bench-results/student-mlx"))
    args = ap.parse_args()

    model, tap = load_student(args.student, tap=args.tap)
    width, layers = model.width, model.layers
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    if args.shards:
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

    import runners

    ref = runners.torch_step(model)

    def gate(path, label, limit):
        step = load_step(path)
        outs_t, outs_m, st_t = [], [], np.zeros((layers, 1, width), np.float32)
        st_ref = np.zeros((layers, 1, width), np.float32)
        for hu, ha, act, prev in rng:
            o_t, st_ref = ref(hu, ha, act, prev, st_ref)
            o_m, st_t = step(hu, ha, act, prev, st_t)
            outs_t.append(o_t)
            outs_m.append(o_m)
        a_t, a_m = np.stack(outs_t), np.stack(outs_m)
        probs = float(np.abs(a_t[:, 4:] - a_m[:, 4:]).max())
        logits = float(np.abs(a_t[:, :4] - a_m[:, :4]).max())
        flips = int((a_t[:, :4].argmax(1) != a_m[:, :4].argmax(1)).sum())
        thr = {s: int(((a_t[:, s] >= t) != (a_m[:, s] >= t)).sum()) for s, t in TRAIT_THRS.items()}
        state_d = float(np.abs(st_t - st_ref).max())
        ms, p95 = runners.ms_per_frame(step, rng[0][0], rng[0][1], rng[0][2], rng[0][3],
                                      np.zeros((layers, 1, width), np.float32))
        ok = probs <= limit and flips == 0 and all(v == 0 for v in thr.values())
        print(f"{label}: probs max|d| {probs:.2e} (gate {limit:.0e}), state-logits {logits:.2e}, "
              f"argmax flips {flips}, threshold flips {thr}, state max|d| {state_d:.2e}, "
              f"{ms:.3f} ms/frame (p95 {p95:.3f})  {'PASS' if ok else 'FAIL'}", flush=True)
        return probs, logits, flips, thr, state_d, ms, ok

    lines = [f"# StudentStep MLX parity ({src})", "",
             f"checkpoint: {args.student}  |  {width}x{layers} GRU"
             + (f"  |  adapter: {tap}" if tap else ""), ""]
    fp32_path = out / "StudentStep.safetensors"
    export(model, fp32_path, group=0)
    w, lg, fl, tfl, st, ms, ok = gate(fp32_path, "fp32 vs torch", FP32_GATE)
    lines += [f"- **fp32**: probs max|d| {w:.2e}, state-logits {lg:.2e}, argmax flips {fl}, "
              f"threshold flips {tfl}, state max|d| {st:.2e}, {ms:.3f} ms/frame",
              f"- size: StudentStep.safetensors {fp32_path.stat().st_size / 1e6:.2f} MB"]
    ok_all = ok
    if not args.no_quantize:
        int8_path = out / "StudentStepInt8.safetensors"
        export(model, int8_path, group=args.group)
        w8, lg8, fl8, tfl8, st8, ms8, ok8 = gate(int8_path, "int8 vs torch", INT8_GATE)
        lines += [f"- **int8 group-{args.group}**: probs max|d| {w8:.2e}, state-logits {lg8:.2e}, "
                  f"argmax flips {fl8}, threshold flips {tfl8}, state max|d| {st8:.2e}, "
                  f"{ms8:.3f} ms/frame",
                  f"- size: StudentStepInt8.safetensors {int8_path.stat().st_size / 1e6:.2f} MB"]
        ok_all = ok_all and ok8
    (out / "parity.md").write_text("\n".join(lines) + "\n")
    print(f"wrote {out / 'parity.md'}")
    raise SystemExit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
