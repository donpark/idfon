"""MLX port of the Nemotron streaming encoder to layer 15 (docs/voice-tyger-ondevice.md, S1).

Faithful translation of transformers' `NemotronAsrStreamingEncoder` (their modular
source), offline mode only (full window, no caches) — the parity case. The decision
path stops at `hidden_states[15]`, so layers 15-23 and the RNN-T are not ported
(397M of the 652M bundle: encoder→L15 378M + front + the 14M GRU).

Weights load 1:1 from the bundle's `model.safetensors` (`nemotron.encoder.*`).
Parity is proven by `parity.py` against the torch encoder on identical features.

Known deliberate simplifications (S1): batch 1, fp32, no streaming caches (the
incremental-KV lever is S3). The attention mask mirrors their `chunked_limited`
mask for whatever lookahead the caller passes (0 matches ReferenceEars).
"""
import math
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
from safetensors import safe_open

HIDDEN = 1024
HEADS = 8
HEAD_DIM = 128
FF = 4096
CONV_K = 9
WINDOW = 57  # sliding_window: left context = WINDOW - 1
SUB_CHANNELS = 256
SUB_K = 3
SUB_S = 2
SUB_FACTOR = 8
REL_BASE = 10000.0


def load_encoder_weights(bundle_dir, layers=15):
    """{name: mx.array} for the subsampling stack + the first `layers` blocks,
    torch layouts converted to mlx's."""
    path = Path(bundle_dir) / "model.safetensors"
    out = {}
    with safe_open(path, framework="np") as f:
        for k in f.keys():
            if not k.startswith("nemotron.encoder."):
                continue
            name = k[len("nemotron.encoder."):]
            if name.startswith("layers."):
                if int(name.split(".")[1]) >= layers:
                    continue
            t = f.get_tensor(k)
            if name.endswith(("q_proj.weight", "k_proj.weight", "v_proj.weight", "o_proj.weight",
                              "relative_k_proj.weight", "linear1.weight", "linear2.weight")) or name.endswith("subsampling.linear.weight"):
                t = t.T  # torch Linear (out, in) -> mlx Linear (in, out)
            elif name.endswith(("pointwise_conv1.weight", "pointwise_conv2.weight")):
                t = t[:, :, 0].T  # torch Conv1d (out, in, 1) -> mlx Linear (in, out)
            elif name.endswith("conv.depthwise_conv.weight"):
                t = t[:, 0, :][:, :, None]  # torch (C, 1, K) -> mlx Conv1d (C, K, 1), groups=C
            elif name.startswith("subsampling.") and name.endswith("depthwise_conv.weight"):
                t = t[:, 0, :, :, None]  # torch (C, 1, 3, 3) -> mlx Conv2d (C, 3, 3, 1), groups=C
            elif name.endswith(("conv_in.weight", "pointwise_conv.weight")):
                t = t.transpose(0, 2, 3, 1)  # torch Conv2d (o, i, kh, kw) -> mlx (o, kh, kw, i)
            out[name] = mx.array(t)
    return out


class FeedForward:
    def __init__(self, w, p):
        self.w1 = w[f"{p}.linear1.weight"]
        self.w2 = w[f"{p}.linear2.weight"]

    def __call__(self, x):
        return (nn.silu(x @ self.w1)) @ self.w2


class Attention:
    """Parakeet relative-position attention: Shaw terms (a)+(c) plus Transformer-XL
    terms (b)+(d) with bias_u/bias_v, rel-shifted, sliced to the key length."""

    def __init__(self, w, p):
        self.q = w[f"{p}.q_proj.weight"]
        self.k = w[f"{p}.k_proj.weight"]
        self.v = w[f"{p}.v_proj.weight"]
        self.o = w[f"{p}.o_proj.weight"]
        self.rel_k = w[f"{p}.relative_k_proj.weight"]
        self.bias_u = w[f"{p}.bias_u"][None, :, None, :]  # (1, heads, 1, head_dim)
        self.bias_v = w[f"{p}.bias_v"][None, :, None, :]
        self.scaling = HEAD_DIM ** -0.5

    @staticmethod
    def _rel_shift(a):
        # (B, H, Q, P): pad right by 1, fold into rows, drop the first row
        b, h, q, p = a.shape
        a = mx.pad(a, [(0, 0), (0, 0), (0, 0), (1, 0)])  # torch pad((1, 0)): LEFT pad
        a = a.reshape(b, h, p + 1, q)[:, :, 1:]
        return a.reshape(b, h, q, p)

    def __call__(self, x, pos_emb, mask):
        b, t, _ = x.shape
        q = (x @ self.q).reshape(b, t, HEADS, HEAD_DIM).transpose(0, 2, 1, 3)
        k = (x @ self.k).reshape(b, t, HEADS, HEAD_DIM).transpose(0, 2, 1, 3)
        v = (x @ self.v).reshape(b, t, HEADS, HEAD_DIM).transpose(0, 2, 1, 3)
        rel_k = (pos_emb @ self.rel_k).reshape(b, -1, HEADS, HEAD_DIM).transpose(0, 2, 3, 1)  # (B,H,D,2T-1)
        bd = self._rel_shift((q + self.bias_v) @ rel_k)[:, :, :, : t] * self.scaling
        bd = mx.where(mask, bd, mx.array(-mx.inf, bd.dtype))
        scores = (q + self.bias_u) @ k.transpose(0, 1, 3, 2) * self.scaling + bd
        out = mx.softmax(scores.astype(mx.float32), axis=-1) @ v
        return (out.transpose(0, 2, 1, 3).reshape(b, t, HIDDEN)) @ self.o


class ConvModule:
    """pointwise1 -> GLU -> causal depthwise k=9 -> LayerNorm -> silu -> pointwise2."""

    def __init__(self, w, p):
        self.pw1 = w[f"{p}.pointwise_conv1.weight"]
        self.pw2 = w[f"{p}.pointwise_conv2.weight"]
        self.dw = nn.Conv1d(HIDDEN, HIDDEN, CONV_K, groups=HIDDEN, bias=f"{p}.depthwise_conv.bias" in w)
        self.dw.weight = w[f"{p}.depthwise_conv.weight"]
        if f"{p}.depthwise_conv.bias" in w:
            self.dw.bias = w[f"{p}.depthwise_conv.bias"]
        self.nw = w[f"{p}.norm.weight"]
        self.nb = w[f"{p}.norm.bias"]

    def __call__(self, x):
        h = x @ self.pw1
        h = h[..., :HIDDEN] * mx.sigmoid(h[..., HIDDEN:])  # GLU
        h = mx.pad(h, [(0, 0), (CONV_K - 1, 0), (0, 0)])  # causal: left pad only
        h = self.dw(h)
        h = mx.fast.layer_norm(h, self.nw, self.nb, 1e-5)
        h = nn.silu(h)
        return h @ self.pw2


class Block:
    def __init__(self, w, i):
        p = f"layers.{i}"
        self.ff1 = FeedForward(w, f"{p}.feed_forward1")
        self.ff2 = FeedForward(w, f"{p}.feed_forward2")
        self.attn = Attention(w, f"{p}.self_attn")
        self.conv = ConvModule(w, f"{p}.conv")
        self.norms = {n: (w[f"{p}.{n}.weight"], w[f"{p}.{n}.bias"]) for n in
                      ("norm_feed_forward1", "norm_self_att", "norm_conv", "norm_feed_forward2", "norm_out")}

    def _norm(self, name, x):
        return mx.fast.layer_norm(x, *self.norms[name], 1e-5)

    def __call__(self, x, pos_emb, mask):
        x = x + 0.5 * self.ff1(self._norm("norm_feed_forward1", x))
        x = x + self.attn(self._norm("norm_self_att", x), pos_emb, mask)
        x = x + self.conv(self._norm("norm_conv", x))
        x = x + 0.5 * self.ff2(self._norm("norm_feed_forward2", x))
        return self._norm("norm_out", x)


class Subsampling:
    """Causal Conv2d stack (stem + depthwise-separable stages) + linear, offline padding."""

    def __init__(self, w):
        self.w = w

    def _conv(self, h, wt, b, stride, groups=1, k=SUB_K):
        # offline causal padding: (K-1, S-1) on both axes; k=1 pointwise takes none
        h = mx.pad(h, [(0, 0), (k - 1, stride - 1), (k - 1, stride - 1), (0, 0)])
        y = mx.conv2d(h, wt, stride=stride, groups=groups)
        return y + b if b is not None else y

    def __call__(self, x):
        w = self.w
        h = x[..., None]  # (B, T, 128, 1)
        h = nn.relu(self._conv(h, w["subsampling.conv_in.weight"], w["subsampling.conv_in.bias"], SUB_S))
        for i in range(int(math.log2(SUB_FACTOR)) - 1):
            p = f"subsampling.layers.{i}"
            h = self._conv(h, w[f"{p}.depthwise_conv.weight"], w[f"{p}.depthwise_conv.bias"], SUB_S, groups=SUB_CHANNELS)
            h = nn.relu(self._conv(h, w[f"{p}.pointwise_conv.weight"], w[f"{p}.pointwise_conv.bias"], 1, k=1))
        b, t, f, c = h.shape
        # torch: (B, C, F, T) -> transpose(1,2).reshape(B, T, C*F): last axis is (c, f)
        h = h.transpose(0, 1, 3, 2).reshape(b, t, c * f)
        return h @ w["subsampling.linear.weight"] + w["subsampling.linear.bias"]


class EncoderL15:
    """The decision path: features (B, T_mel, 128) -> hidden_states[15] (B, T', 1024)."""

    def __init__(self, bundle_dir, layers=15):
        self.w = load_encoder_weights(bundle_dir, layers)
        self.sub = Subsampling(self.w)
        self.blocks = [Block(self.w, i) for i in range(layers)]
        self.inv_freq = 1.0 / (REL_BASE ** (mx.arange(0, HIDDEN, 2).astype(mx.float32) / HIDDEN))

    def positions(self, t):
        pos = mx.arange(t - 1, -t, -1).astype(mx.float32)
        freqs = pos[:, None] * self.inv_freq[None, :]
        return mx.stack([mx.sin(freqs), mx.cos(freqs)], axis=-1).reshape(t * 2 - 1, HIDDEN)

    def __call__(self, features, lookahead=0):
        h = self.sub(features)
        t = h.shape[1]
        pos_emb = self.positions(t)[None]
        idx = mx.arange(t)
        chunk = lookahead + 1
        qc, kc = idx // chunk, (idx // chunk)[None, :]
        diff = qc[:, None] - kc
        mask = (diff >= 0) & (diff <= (WINDOW - 1) // chunk)  # their chunked_limited mask
        x = h
        for block in self.blocks:
            x = block(x, pos_emb, mask)
        return x
