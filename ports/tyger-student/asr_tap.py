"""Declared-tap Core ML export of the Nemotron 3.5 streaming ASR encoder (#102 Leg 1).

The ASR runs a cache-aware streaming encoder whose layer-4 hidden state the turn
student wants. Core ML exposes *declared* outputs only, so `tap_l4` must be a real
model output of the ASR's own streaming pass -- not a hook, not a windowed
re-encode.

What this module does: reimplement the encoder's streaming pass as a graph with
**explicit tensor caches** in FluidAudio's contract, then check it against the
torch pass that produced `bench-results/tap4-shards` (the adapter's calibration
target). The model I/O is fixed by the shipping manager, not invented here:

  Sources/FluidAudio/ASR/Parakeet/Streaming/Nemotron/StreamingNemotronMultilingualAsrManager+Pipeline.swift
  Sources/FluidAudio/ASR/Parakeet/Streaming/EncoderCacheManager.swift
  (metadata.json of FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML)

  in  mel             fp32 [1,128,65]   (56 chunk + 9 pre-encode context)
      mel_length      int32 [1]         (65)
      cache_channel   fp32 [1,24,56,1024]  per-layer attention inputs, right-aligned
      cache_time      fp32 [1,24,1024,8]   per-layer conv1d cache (post-GLU)
      cache_len       int32 [1]         valid cached frames (manager seeds 1)
      prompt_id       int32 [1]         LangID one-hot index (128 prompts)
  out encoded         fp32 [1,1024,7]   prompt-conditioned frames the decoder reads
      tap_l4          fp32 [1,1024,7]   raw layer-4 hidden state, same 7 frames
      cache_channel_out / cache_time_out / cache_len_out

Cache size 56 is the reference pass's left context (HF `sliding_window=57`,
`num_lookahead_tokens=0`); the shipping bundle uses 42 + NeMo att_context [42,13]
-- see `docs/voice-tyger-streaming-plan.md` for which pass the adapter is fitted on.

The conv2d caches: the torch streaming pass threads `NemotronAsrStreamingEncoderCausalConvPaddingCache`,
which FluidAudio's contract cannot carry (no input tensor for it). They are *derivable*:
each stage's cache frame is a fixed slice of that stage's input on the current call
(8 / 3 / 1 for the stem and the two depthwise stages, measured identical to 0.0
fp32). Baking that is what "is_first_chunk=False" means: every chunk runs the
steady-state conv framing, including the first.

Usage:
  TYGER_ASR=nvidia/nemotron-3.5-asr-streaming-0.6b \
    ports/tyger-student/.venv/bin/python ports/tyger-student/asr_tap.py --selfcheck
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

SR = 16_000
CHUNK_MEL = 56  # 560 ms tier
PRE_ENCODE = 9
TOTAL_MEL = CHUNK_MEL + PRE_ENCODE  # 65
SUBSAMPLE = 8  # 3 x stride-2 convs
NEW_FRAMES = CHUNK_MEL // SUBSAMPLE  # 7 new encoder frames per 560 ms chunk
CHUNK_FRAMES = NEW_FRAMES + 1  # 8 rows out: the first is context-only and gets dropped
CONV_CACHE = 8  # conformer depthwise conv left context (kernel 9 - 1)
KEEP = NEW_FRAMES  # rows kept per chunk, as featurize_tap.tap() does
DEFAULT_MODEL = "nvidia/nemotron-3.5-asr-streaming-0.6b"
# stage -> index of this stage's input frame that equals the previous call's conv2d cache
CONV2D_CACHE_FRAME = (8, 3, 1)


def rel_shift(attn_scores: torch.Tensor, heads: int, q: int, p: int) -> torch.Tensor:
    """Transformer-XL relative-position shift (HF `_rel_shift`). Static dims on purpose:
    tensor-derived ints become aten::Int(size) nodes the Core ML frontend cannot fold."""
    attn_scores = F.pad(attn_scores, (1, 0))
    attn_scores = attn_scores.reshape(1, heads, -1, q)
    return attn_scores[:, :, 1:].reshape(1, heads, q, p)


class StreamingTapEncoder(nn.Module):
    """The ASR encoder as a static-shape graph: caches in, encoded + tap_l4 out."""

    def __init__(self, model, cache_size: int = 56, tap_index: int = 4):
        super().__init__()
        self.model = model
        self.enc = model.encoder
        self.cache_size = cache_size
        self.tap_index = tap_index  # hidden_states[tap_index] == output of layer tap_index-1
        assert self.enc.config.num_hidden_layers == 24
        probe = torch.zeros(1, CHUNK_FRAMES, self.enc.config.hidden_size)
        self.register_buffer("pos_emb", self.enc.encode_positions(probe, cached_frames=cache_size))
        eye = torch.eye(self.model.config.num_prompts)
        self.register_buffer("prompt_eye", eye)
        self.register_buffer("mel_pos", torch.arange(TOTAL_MEL, dtype=torch.float32))

    # ---- subsampling: the streaming conv framing, with derivable conv2d caches ----
    def _subsample(self, mel: torch.Tensor, mel_length: torch.Tensor) -> torch.Tensor:
        sub = self.enc.subsampling
        x = mel.transpose(1, 2).unsqueeze(1)  # [1,1,65,128]
        t = self.mel_pos[None, None, :, None]
        x = x * (t < mel_length.float()[:, None, None, None]).to(x.dtype)

        stages = [sub.conv_in] + [layer.depthwise_conv for layer in sub.layers]
        pointwise = [None] + [layer.pointwise_conv for layer in sub.layers]
        for conv, pw, k in zip(stages, pointwise, CONV2D_CACHE_FRAME):
            x = F.pad(x, conv.freq_pad)  # freq axis only; the time cache replaces the left pad
            x = torch.cat([x[:, :, k : k + 1, :], x], dim=2)
            # F.conv2d, not conv(x): the module's forward would pad again (cache=None path)
            x = F.conv2d(x, conv.weight, conv.bias, conv.stride, 0, conv.dilation, conv.groups)
            if pw is not None:
                x = pw(x)
            x = F.relu(x)
        return sub.linear(x.transpose(1, 2).flatten(2))

    def _attention(self, attn, h, cache_ch, cache_len):
        C, T = self.cache_size, CHUNK_FRAMES
        heads, kv_heads, hd_ = attn.config.num_attention_heads, attn.config.num_key_value_heads, attn.head_dim
        keys = torch.cat([cache_ch, h], dim=1)  # [1,C+T,D]
        q = attn.q_proj(h).view(1, T, heads, hd_).transpose(1, 2)
        k = attn.k_proj(keys).view(1, C + T, kv_heads, hd_).transpose(1, 2)
        v = attn.v_proj(keys).view(1, C + T, kv_heads, hd_).transpose(1, 2)

        q_u = q + attn.bias_u.view(1, -1, 1, attn.head_dim)
        q_v = q + attn.bias_v.view(1, -1, 1, attn.head_dim)
        rel = attn.relative_k_proj(self.pos_emb).view(1, -1, heads, hd_)
        bd = q_v @ rel.permute(0, 2, 3, 1)
        bd = rel_shift(bd, heads, T, 2 * (C + T) - 1)[..., : C + T] * attn.scaling

        # float comparisons: coremltools cannot fold int64 ranges into int32 constants
        qi = torch.arange(T, device=h.device, dtype=torch.float32)[:, None]
        kv = torch.arange(C + T, device=h.device, dtype=torch.float32)[None, :]
        mask = (kv >= qi) & (kv <= C + qi) & (kv >= C - cache_len.float())
        bd = bd.masked_fill(~mask[None, None], float("-inf"))

        scores = (q_u @ k.transpose(2, 3)) * attn.scaling + bd
        probs = F.softmax(scores, dim=-1, dtype=torch.float32).to(q.dtype)
        out = (probs @ v).transpose(1, 2).reshape(1, T, heads * hd_)
        return attn.o_proj(out)

    def _conv(self, conv, h, cache_t):
        y = F.glu(conv.pointwise_conv1(h.transpose(1, 2)), dim=1)  # [1,D,T]
        # F.conv1d, not conv.depthwise_conv(...): its forward would left-pad 8 more frames
        z = F.conv1d(torch.cat([cache_t, y], dim=2), conv.depthwise_conv.weight,
                     conv.depthwise_conv.bias, 1, 0, 1, conv.depthwise_conv.groups)
        z = conv.norm(z.transpose(1, 2))
        z = conv.activation(z.transpose(1, 2))
        z = conv.pointwise_conv2(z).transpose(1, 2)
        return z, y[:, :, -CONV_CACHE:]

    def forward(self, mel, mel_length, cache_channel, cache_time, cache_len, prompt_id):
        h = self._subsample(mel, mel_length) * self.enc.input_scale
        new_ch, new_t = [], []
        tap = None
        for i, block in enumerate(self.enc.layers):
            residual = h
            h = residual + 0.5 * block.feed_forward1(block.norm_feed_forward1(h))
            attn_in = block.norm_self_att(h)
            h = h + self._attention(block.self_attn, attn_in, cache_channel[:, i], cache_len)
            conv_out, y = self._conv(block.conv, block.norm_conv(h), cache_time[:, i])
            h = h + conv_out
            h = h + 0.5 * block.feed_forward2(block.norm_feed_forward2(h))
            h = block.norm_out(h)
            new_ch.append(torch.cat([cache_channel[:, i], attn_in], dim=1)[:, -self.cache_size :])
            new_t.append(y)
            if i + 1 == self.tap_index:  # hidden_states[4] = output of layer 3
                tap = h
        cache_channel_out = torch.stack(new_ch, dim=1)
        cache_time_out = torch.stack(new_t, dim=1)

        kept = h[:, 1:]  # drop the context row -> 7 new frames (featurize_tap.tap())
        onehot = self.prompt_eye.index_select(0, prompt_id.to(torch.int32))
        fused = self.model.prompt_projector(
            torch.cat([kept, onehot[:, None, :].expand(-1, KEEP, -1)], dim=-1)
        )
        cache_len_out = torch.clamp(cache_len.float() + CHUNK_FRAMES, max=self.cache_size).to(torch.int32)
        lengths = mel_length
        for _ in range(3):
            lengths = torch.div(lengths.float() + 2, 2, rounding_mode="floor") + 1
        encoded_length = torch.clamp(lengths.to(torch.int32) - 1, min=0)
        return (
            fused.transpose(1, 2),
            tap[:, 1:].transpose(1, 2),
            cache_channel_out,
            cache_time_out,
            cache_len_out,
            encoded_length,
        )


# --------------------------------------------------------------------------- #
# torch reference pass: exactly featurize_tap.tap(), but per chunk and with the
# prompt projector for `encoded`. This is the pass tap4-shards records.
# --------------------------------------------------------------------------- #
def reference_windows(feats: torch.Tensor):
    for end in range(PRE_ENCODE + CHUNK_MEL, feats.shape[1] + 1, CHUNK_MEL):
        yield feats[:, end - TOTAL_MEL : end]


def reference_chunks(model, feats, prompt_id=None, lookahead=0, tap_index=4):
    """-> (encoded [N,7,1024], tap [N,7,1024]) from the torch streaming pass."""
    from transformers.cache_utils import DynamicCache
    from transformers.models.nemotron_asr_streaming.modeling_nemotron_asr_streaming import (
        NemotronAsrStreamingEncoderCausalConvPaddingCache,
    )

    enc = model.encoder
    cache = DynamicCache(config=enc.config)
    padding_cache = NemotronAsrStreamingEncoderCausalConvPaddingCache()
    pids = torch.tensor([model.config.default_prompt_id if prompt_id is None else prompt_id])
    enc_rows, tap_rows = [], []
    with torch.no_grad():
        for win in reference_windows(feats):
            out = enc(
                input_features=win,
                use_cache=True,
                past_key_values=cache,
                padding_cache=padding_cache,
                num_lookahead_tokens=lookahead,
                output_hidden_states=True,
            )
            hidden = out.last_hidden_state  # [1,T,1024]
            onehot = F.one_hot(pids, num_classes=model.config.num_prompts).to(hidden.dtype)
            onehot = onehot[:, None, :].expand(-1, hidden.shape[1], -1)
            encoded = model.prompt_projector(torch.cat([hidden, onehot], dim=-1))
            enc_rows.append(encoded[0][1:])
            tap_rows.append(out.hidden_states[tap_index][0][1:])
    return [r.numpy() for r in enc_rows], [r.numpy() for r in tap_rows]


def wrapper_chunks(wrapper, feats, prompt_id=None, cache_size=56):
    """Run the exported graph's forward chunk by chunk with threaded caches."""
    mel_length = torch.tensor([TOTAL_MEL], dtype=torch.int32)
    pid = torch.tensor([wrapper.model.config.default_prompt_id if prompt_id is None else prompt_id])
    ch = torch.zeros(1, 24, cache_size, 1024)
    ct_ = torch.zeros(1, 24, 1024, 8)
    cl = torch.tensor([1], dtype=torch.int32)
    enc_rows, tap_rows = [], []
    with torch.no_grad():
        for win in reference_windows(feats):
            # the wrapper's `mel` is the manager's layout [1,128,65]; the processor is time-first
            encoded, tap, ch, ct_, cl, _ = wrapper(win.transpose(1, 2).contiguous(), mel_length, ch, ct_, cl, pid)
            enc_rows.append(encoded[0].transpose(0, 1).numpy())
            tap_rows.append(tap[0].transpose(0, 1).numpy())
    return enc_rows, tap_rows


def divergence(a: np.ndarray, b: np.ndarray):
    a, b = a.astype(np.float64), b.astype(np.float64)
    cos = (a * b).sum(1) / (np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1) + 1e-12)
    return float(np.median(cos)), float(cos.min()), float(np.abs(a - b).max())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selfcheck", action="store_true", help="wrapper vs the torch streaming pass")
    ap.add_argument("--model", default=os.environ.get("TYGER_ASR", DEFAULT_MODEL))
    ap.add_argument("--cache-size", type=int, default=56)
    ap.add_argument("--fixture", default="ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch0.wav",
                    help="16 kHz mono wav (the runtime fixture; gitignored, read from the main checkout)")
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--dump", default=None, help="npz for the fixture's reference tap rows")
    args = ap.parse_args()
    if not args.selfcheck:
        ap.error("nothing to do: pass --selfcheck (export lives in export_asr_tap.py)")

    import soundfile as sf
    from transformers import AutoModel, AutoProcessor

    proc = AutoProcessor.from_pretrained(args.model)
    model = AutoModel.from_pretrained(args.model, dtype=torch.float32).eval().to(args.device)
    x, sr = sf.read(args.fixture, dtype="float32")
    assert sr == SR and x.ndim == 1, (sr, x.shape)
    feats = proc(np.asarray(x, np.float32), sampling_rate=sr, return_tensors="pt")["input_features"]
    print(f"fixture {len(x)/SR:.1f}s -> mel {tuple(feats.shape)}")

    enc_ref, tap_ref = reference_chunks(model, feats)
    wrapper = StreamingTapEncoder(model, cache_size=args.cache_size).eval()
    enc_w, tap_w = wrapper_chunks(wrapper, feats, cache_size=args.cache_size)
    print(f"chunks: reference {len(enc_ref)}, wrapper {len(enc_w)}; "
          f"rows/chunk ref {[r.shape[0] for r in enc_ref[:3]]} wrapper {[r.shape[0] for r in enc_w[:3]]}")

    def chunk_stats(ref, got, lo, hi):
        a = np.concatenate(ref[lo:hi])
        b = np.concatenate(got[lo:hi])
        m = min(len(a), len(b))
        return divergence(a[:m], b[:m]) + (m,)

    n = min(len(enc_ref), len(enc_w))
    verdict = {}
    for name, ref, got in (("encoded", enc_ref, enc_w), ("tap_l4", tap_ref, tap_w)):
        print(f"{name}:")
        for lo, hi in ((1, 8), (8, 16), (16, 32), (32, 10**9)):
            if hi <= lo or lo >= n:
                continue
            c, cm, d, m = chunk_stats(ref, got, min(lo, n), min(hi, n))
            print(f"  chunks {lo:2d}..{min(hi, n):3d}  rows {m:5d}  cos p50 {c:.8f} "
                  f"min {cm:.8f}  max|d| {d:.3e}")
            verdict[name] = d
    worst = verdict.get("tap_l4", float("inf"))
    print(f"selfcheck: cold-start tap converges to {verdict.get('tap_l4', float('nan')):.2e} "
          f"by the last bucket -> {'PASS' if worst <= 2e-3 else 'FAIL'} (2e-3 bar)")
    if args.dump:
        Path(args.dump).parent.mkdir(parents=True, exist_ok=True)
        np.savez(args.dump, tap_ref=tap_ref, tap_wrapper=tap_w, encoded_ref=enc_ref)
        print("dumped", args.dump)


if __name__ == "__main__":
    main()
