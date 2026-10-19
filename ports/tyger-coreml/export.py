"""Export the tyger decision path to Core ML (the S4 shipping runtime).

Two static graphs, mirroring the Python chain 1:1 so the acceptance stack diffs each
level (docs/voice-tyger-ondevice.md):

  TygerEncoder  mel window (1, 801, 128) -> hidden L15 (1, 101, 1024)
                [called twice per hop: user + agent windows]
  TygerStep     hu (1,1,1024), ha (1,1,1024), act_db (1,1), prev_state (1,1),
                state (3,1,768) -> 8-vector (1,1,8), new state (3,1,768)
                [called 4x per hop; energy normalisation ((db+50)/25 clamp) is baked
                 in here — it is head_step semantics in the reference]

Semantics = the full-window re-encode (the KV study showed incremental caching fails
the per-head budget). Window is static 800 mel frames = the steady-state 8 s window;
startup (growing windows) needs enumerated shapes and is a documented follow-up.

Usage:  TYGER_S2S=... python export.py [--precision float16|float32] [--only enc|step]
Output: bench-results/coreml/*.mlpackage (gitignored, ~0.8 GB fp16)
"""
import argparse
import os
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE", os.path.expanduser(
    "~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6"))
sys.path.insert(0, S2S)

from app.plugins.ears.tyger.bundle import load as bundle_load  # noqa: E402
from app.plugins.ears.tyger.constants import L15  # noqa: E402

OUT = Path(__file__).resolve().parents[2] / "bench-results" / "coreml"
MEL_FRAMES = 801  # proc yields 8 s * 16 kHz / 160 + 1 = 801 mel frames -> 101 stem frames


class EncWrap(nn.Module):
    def __init__(self, asr):
        super().__init__()
        self.enc = asr.encoder

    def forward(self, feats):
        eo = self.enc(input_features=feats, attention_mask=None,
                      num_lookahead_tokens=0, output_hidden_states=True)
        return eo.hidden_states[L15]


class StepWrap(nn.Module):
    def __init__(self, tt):
        super().__init__()
        self.tt = tt

    def forward(self, hu, ha, act_db, prev_state, state):
        act = ((act_db + 50) / 25).clamp(-3, 3)  # head_step semantics, kept in-graph
        out, state = self.tt(hu, ha, act, prev_state, state)
        return out, state


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--precision", default="float16", choices=["float16", "float32"])
    ap.add_argument("--only", default="both", choices=["both", "enc", "step"])
    args = ap.parse_args()

    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch.ops import _cast_to, _get_inputs
    from coremltools.converters.mil.frontend.torch.utils import NUM_TO_DTYPE_STRING
    from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op

    @register_torch_op
    def new_ones(context, node):
        # torch's causal-mask builder calls new_ones(..., dtype=bool); mirror their `ones` op
        inputs = _get_inputs(context, node)
        shape = inputs[1]
        if isinstance(shape, list):
            shape = mb.concat(values=shape, axis=0)
        res = mb.fill(shape=shape, value=1.0)
        if len(inputs) > 2 and inputs[2] is not None:
            res = _cast_to(res, NUM_TO_DTYPE_STRING[inputs[2].val], node.name)
        context.add(res, node.name)


    asr, proc, tt, _cfg = bundle_load(Path(BUNDLE))
    asr.eval()
    tt.eval()
    OUT.mkdir(parents=True, exist_ok=True)
    prec = ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32
    print(f"precision: {args.precision}, out: {OUT}")

    if args.only in ("both", "enc"):
        enc = EncWrap(asr).eval()
        ex = torch.zeros(1, MEL_FRAMES, 128)
        with torch.no_grad():
            ref = enc(ex)
        print(f"encoder: feats (1, {MEL_FRAMES}, 128) -> {tuple(ref.shape)}")
        ml = ct.convert(torch.jit.trace(enc, ex),
                        inputs=[ct.TensorType(name="feats", shape=ex.shape)],
                        compute_precision=prec, compute_units=ct.ComputeUnit.ALL)
        ml.save(OUT / "TygerEncoder.mlpackage")

    if args.only in ("both", "step"):
        step = StepWrap(tt).eval()
        hua = torch.zeros(1, 1, 1024)
        act = torch.zeros(1, 1)
        prev = torch.zeros(1, 1, dtype=torch.long)
        state = torch.zeros(3, 1, 768)
        with torch.no_grad():
            out, st = step(hua, hua, act, prev, state)
        print(f"step: -> out {tuple(out.shape)}, state {tuple(st.shape)}")
        ml = ct.convert(torch.jit.trace(step, (hua, hua, act, prev, state), strict=False),
                        inputs=[ct.TensorType(name="hu", shape=hua.shape),
                                ct.TensorType(name="ha", shape=hua.shape),
                                ct.TensorType(name="act_db", shape=act.shape),
                                ct.TensorType(name="prev_state", shape=prev.shape, dtype=np.int32),
                                ct.TensorType(name="state", shape=state.shape)],
                        compute_precision=prec, compute_units=ct.ComputeUnit.ALL)
        ml.save(OUT / "TygerStep.mlpackage")

    for p in sorted(OUT.glob("*.mlpackage")):
        size = sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1e9
        print(f"  {p.name}: {size:.2f} GB")


if __name__ == "__main__":
    main()
