"""Quantization-aware training (epic #132 P4): project the quantized tensors onto
the int8 group-`group` grid so training runs on the weights the export ships.

The scheme mirrors ports/tyger-onnx/quantize_step.py's `quantize()` exactly
(per-output-unit groups along the contraction axis, asymmetric uint8 with the
one-sided-group rescale; deq = (q - zp) * scale). `fake_quant` is the torch
round-trip; `selfcheck_parity()` proves it is bit-identical to the numpy path,
so the QAT model and the exported int8 artifact live on the same grid.

Projection happens after each optimizer step (projected-gradient QAT): every
forward uses grid-valued weights, gradients are plain autograd on the raw
parameters, and the exported weights ARE the trained weights (re-quantization
is idempotent). Targeted tensors match export.py's quantization targets:
GRU W/R (rows = output units, contraction axis 1) and the per-tap fuse
projections (1024, width; contraction axis 0). Biases, heads, norms and the
state embedding stay fp32 — the teacher's P0 rule.
"""
import importlib.machinery
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]


def fake_quant(w, group, axis):
    """torch round-trip of quantize_step.quantize: -> dequantized weights, same shape."""
    b = w if axis == 1 else w.T                      # (out, in): rows = output units
    out, inn = b.shape
    g = group or inn
    bb = b.reshape(out * (inn // g), g)
    mx, mn = bb.amax(dim=1, keepdim=True), bb.amin(dim=1, keepdim=True)
    scale = (mx - mn) / 255.0
    zero = scale <= 0
    scale = torch.where(zero, torch.ones_like(scale), scale)
    zp = -mn / scale
    scale = torch.where(zp < 0, mx / 255.0, scale)   # one-sided groups rescale, not clip
    scale = torch.where(zp > 255, -mn / 255.0, scale)
    scale = torch.where(zero, torch.ones_like(scale), scale)
    zp = torch.clamp(torch.round(zp) - 128.0, -128, 127)
    q = torch.clamp(torch.round(bb / scale) + zp, -128, 127)
    deq = (q - zp) * scale
    return deq.reshape(b.shape).T.contiguous() if axis == 0 else deq.reshape(w.shape)


def target_params(model):
    """-> [(param, contraction axis)] — export.py's quantization targets."""
    out = []
    for name, p in model.named_parameters():
        if name.startswith("core.weight_"):            # GRU W/R: (3h, in/h), rows = output units
            out.append((p, 1))
        elif (name.startswith("adapters.") and name.endswith((".user.weight", ".agent.weight"))
              and p.shape[0] == 1024):                 # fuse projections: (in, out)
            out.append((p, 0))
    return out


def project(model, group):
    """Quantize-dequantize every targeted parameter in place (post-step projection)."""
    with torch.no_grad():
        for p, axis in target_params(model):
            p.copy_(fake_quant(p, group, axis))


def selfcheck_parity():
    """fake_quant must be bit-identical to quantize_step's numpy path — including the
    one-sided (all-positive/all-negative) and all-zero group rescale branches."""
    qs = importlib.machinery.SourceFileLoader(
        "quantize_step", str(ROOT / "ports" / "tyger-onnx" / "quantize_step.py")).load_module()
    g = torch.Generator().manual_seed(0)
    b = torch.randn(48, 32, generator=g) * 0.2                       # row space: (out, in)
    b = torch.cat([b, torch.rand(16, generator=g).expand(48, 16) + 1e-3,     # all-positive group
                   -torch.rand(16, generator=g).expand(48, 16) - 1e-3,       # all-negative group
                   torch.zeros(48, 16)], dim=1)                              # all-zero group
    for axis in (1, 0):
        w = b if axis == 1 else b.T
        for group in (8, 16, 0):
            mine = fake_quant(w, group, axis).numpy()
            q, scale, zp = qs.quantize(w.numpy().astype(np.float32), group, axis)
            ref = (q.astype(np.float32) - zp.astype(np.float32)[:, None]) * scale[:, None]
            ref = ref.reshape(b.shape)
            ref = ref if axis == 1 else ref.T
            assert np.array_equal(mine, ref), (axis, group, float(np.abs(mine - ref).max()))
    return "ok"
