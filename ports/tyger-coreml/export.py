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


class EncFrontWrap(nn.Module):
    """Stem + block 0 (the sensitive head of the encoder, kept fp32): mel -> hidden."""

    def __init__(self, asr):
        super().__init__()
        self.enc = asr.encoder

    def ctx(self, x):
        from transformers.masking_utils import create_bidirectional_mask
        from transformers.models.nemotron_asr_streaming.modeling_nemotron_asr_streaming import (
            chunked_limited_mask_function)
        e = self.enc
        position_ids = torch.arange(x.shape[1], device=x.device).unsqueeze(0)
        mask = create_bidirectional_mask(
            config=e.config, inputs_embeds=x, attention_mask=None, past_key_values=None,
            position_ids=position_ids,
            and_mask_function=chunked_limited_mask_function(*e._resolve_attn_context(0)))
        return mask, torch.all(~mask, dim=-1), e.encode_positions(x, cached_frames=0)

    def forward(self, feats):
        e = self.enc
        x = e.subsampling(feats, None, padding_cache=None) * e.input_scale
        mask, allm, pos = self.ctx(x)
        return e.layers[0](x, attention_mask=mask, all_masked_rows=allm,
                           position_embeddings=pos, past_key_values=None,
                           padding_cache=None, use_cache=False)


class EncTailWrap(nn.Module):
    """Blocks 1..14 (the quantisable bulk): hidden -> hidden L15. Mask and position
    embeddings are shape-derived (verified: encode_positions reads only shape[1]), so
    the tail recomputes them from the hidden length — the split is value-exact."""

    def __init__(self, asr, first=1, cut=15):
        super().__init__()
        self.front = EncFrontWrap(asr)
        self.enc = asr.encoder
        self.layers = nn.ModuleList(list(asr.encoder.layers[first:cut]))  # 1..14 = hidden_states[15]

    def forward(self, x):
        mask, allm, pos = self.front.ctx(x)
        for layer in self.layers:
            x = layer(x, attention_mask=mask, all_masked_rows=allm,
                      position_embeddings=pos, past_key_values=None,
                      padding_cache=None, use_cache=False)
        return x


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
    ap.add_argument("--only", default="both", choices=["both", "enc", "step", "front", "tail", "check"])
    ap.add_argument("--target", default="ios18", choices=["ios17", "ios18"],
                    help="ios18 unlocks per-block/per-grouped-channel quantization")
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
    target = ct.target.iOS18 if args.target == "ios18" else ct.target.iOS17
    print(f"precision: {args.precision}, out: {OUT}")

    if args.only == "check":
        enc_full, front, tail = EncWrap(asr).eval(), EncFrontWrap(asr).eval(), EncTailWrap(asr).eval()
        ex = torch.zeros(1, MEL_FRAMES, 128)
        with torch.no_grad():
            ref = enc_full(ex)
            got = tail(front(ex))
        d = float((ref - got).abs().max())
        print(f"split == full over {tuple(ref.shape)}: max|Δ| {d:.3e}  ({'PASS' if d < 1e-5 else 'FAIL'})")
        sys.exit(0 if d < 1e-5 else 1)

    if args.only in ("both", "front"):
        front = EncFrontWrap(asr).eval()
        ex = torch.zeros(1, MEL_FRAMES, 128)
        with torch.no_grad():
            ref = front(ex)
        print(f"front: -> {tuple(ref.shape)}")
        ml = ct.convert(torch.jit.trace(front, ex),
                        inputs=[ct.TensorType(name="feats", shape=ex.shape)],
                        outputs=[ct.TensorType(name="hidden")],
                        compute_precision=prec, compute_units=ct.ComputeUnit.ALL,
                        minimum_deployment_target=target)
        ml.save(OUT / "TygerFront.mlpackage")

    if args.only in ("both", "tail"):
        tail = EncTailWrap(asr).eval()
        ex = torch.zeros(1, 101, 1024)
        with torch.no_grad():
            ref = tail(ex)
        print(f"tail: -> {tuple(ref.shape)}")
        ml = ct.convert(torch.jit.trace(tail, ex),
                        inputs=[ct.TensorType(name="hidden", shape=ex.shape)],
                        outputs=[ct.TensorType(name="hidden_out")],
                        compute_precision=prec, compute_units=ct.ComputeUnit.ALL,
                        minimum_deployment_target=target)
        ml.save(OUT / "TygerTail.mlpackage")

    if args.only in ("both", "enc"):
        enc = EncWrap(asr).eval()
        ex = torch.zeros(1, MEL_FRAMES, 128)
        with torch.no_grad():
            ref = enc(ex)
        print(f"encoder: feats (1, {MEL_FRAMES}, 128) -> {tuple(ref.shape)}")
        ml = ct.convert(torch.jit.trace(enc, ex),
                        inputs=[ct.TensorType(name="feats", shape=ex.shape)],
                        compute_precision=prec, compute_units=ct.ComputeUnit.ALL,
                        minimum_deployment_target=target)
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
                        compute_precision=prec, compute_units=ct.ComputeUnit.ALL,
                        minimum_deployment_target=target)
        ml.save(OUT / "TygerStep.mlpackage")

    for p in sorted(OUT.glob("*.mlpackage")):
        size = sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1e9
        print(f"  {p.name}: {size:.2f} GB")


if __name__ == "__main__":
    main()
