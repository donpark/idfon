"""Incremental EncoderL15 — the S3 KV-cache study (scheme B).

Scheme A (the reference semantics tyger-s2s validated) re-encodes the 8 s window every
hop. Scheme B keeps per-layer K/V caches + causal-conv caches and encodes only the new
frames; the conv stem still runs per hop (cheap, and identical to A's on the same mel),
so the isolated variable is exactly the documented one — "incremental ≠ re-encode":

  1. deep-layer attention context is stream history instead of truncated to the 8 s
     window, and cached frames keep the representations computed at their own frontier
     while A recomputes every frame under the current window;
  2. same mel, same stem, same newest-aligned rel-pos, same 56-frame attention mask.

parity5.py measures the per-head score deltas and rules-decision agreement that follow.
"""
import mlx.core as mx

from encoder import (CONV_K, HEAD_DIM, HEADS, HIDDEN, WINDOW, Block, EncoderL15)  # noqa: E402


class BlockIncr(Block):
    """One transformer block stepped over new frames only, with caches."""

    KV_CTX = 64  # > 56-frame attention lookback + the new frames

    def step(self, x, cache, pos_emb, mask):
        n = x.shape[1]
        x = x + 0.5 * self.ff1(self._norm("norm_feed_forward1", x))
        x = x + self._attn_step(self._norm("norm_self_att", x), cache, pos_emb, mask)
        xn = self._norm("norm_conv", x)
        cx = xn if cache["cx"] is None else mx.concatenate([cache["cx"], xn], axis=1)
        h = self.conv(cx)
        cache["cx"] = cx[:, -(CONV_K - 1):]
        x = x + h[:, -n:]
        x = x + 0.5 * self.ff2(self._norm("norm_feed_forward2", x))
        return self._norm("norm_out", x)

    def _attn_step(self, x, cache, pos_emb, mask):
        a = self.attn
        b, n, _ = x.shape
        q = (x @ a.q).reshape(b, n, HEADS, HEAD_DIM).transpose(0, 2, 1, 3)
        k = (x @ a.k).reshape(b, n, HEADS, HEAD_DIM).transpose(0, 2, 1, 3)
        v = (x @ a.v).reshape(b, n, HEADS, HEAD_DIM).transpose(0, 2, 1, 3)
        k = k if cache["k"] is None else mx.concatenate([cache["k"], k], axis=2)
        v = v if cache["v"] is None else mx.concatenate([cache["v"], v], axis=2)
        cache["k"], cache["v"] = k[:, :, -self.KV_CTX:], v[:, :, -self.KV_CTX:]
        rel_k = (pos_emb.astype(a.rel_k.dtype) @ a.rel_k).reshape(b, -1, HEADS, HEAD_DIM).transpose(0, 2, 3, 1)
        # _rel_shift folds the rel grid by query rows == sequence length, so the query
        # side must span the combined length; placeholder rows are discarded after the shift
        qp = mx.zeros((b, HEADS, k.shape[2] - n, HEAD_DIM), dtype=q.dtype)
        qfull = mx.concatenate([qp, q], axis=2)
        bd = a._rel_shift((qfull + a.bias_v) @ rel_k)[:, :, :, : k.shape[2]][:, :, -n:] * a.scaling
        bd = mx.where(mask, bd, mx.array(-mx.inf, bd.dtype))
        scores = (q + a.bias_u) @ k.transpose(0, 1, 3, 2) * a.scaling + bd
        out = mx.softmax(scores.astype(mx.float32), axis=-1).astype(v.dtype) @ v
        return (out.transpose(0, 2, 1, 3).reshape(b, n, HIDDEN)) @ a.o


class EncoderL15Incr(EncoderL15):
    """EncoderL15 that emits only the newest frames per call."""

    def __init__(self, bundle_dir, layers=15, precision="fp32"):
        super().__init__(bundle_dir, layers, precision)
        self.blocks = [BlockIncr(self.w, i) for i in range(layers)]
        self.reset()

    def reset(self):
        self.caches = [{"k": None, "v": None, "cx": None} for _ in self.blocks]

    def step(self, features, n_new):
        """Full-window mel (exactly what scheme A encodes) -> the newest n_new frames."""
        h = self.sub(features.astype(self.dtype))
        return self.step_h(h[:, -min(n_new, h.shape[1]):])

    def step_h(self, x):
        """Stem rows -> block-stepped outputs (chunk of new frames)."""
        n = x.shape[1]
        c = 0 if self.caches[0]["k"] is None else self.caches[0]["k"].shape[2]
        t = c + n
        pos_emb = self.positions(t)[None]
        idx = mx.arange(t)
        diff = idx[:, None] - idx[None, :]
        mask = ((diff >= 0) & (diff <= WINDOW - 1))[-n:]
        for blk, cache in zip(self.blocks, self.caches):
            x = blk.step(x, cache, pos_emb, mask)
        return x.astype(mx.float32)
