"""Mask geometry of both streaming passes (#102), asserted without a model.

The 42/13 defect survived because nothing checked the mask against the documented
pattern: the docstring said "4 blocks of 14, every query in the last block sees all
50 keys" while the code implemented a causal sliding window (43 keys, no lookahead).
These tests state the geometry independently of the implementation.
"""
import unittest
from types import SimpleNamespace

import torch

from asr_tap import CHUNK_FRAMES, REFERENCE, SHIPPING, TIER_320, TIER_560, StreamingTapEncoder


class _Encoder:
    """Enough of the HF encoder for `StreamingTapEncoder.__init__` (no weights needed)."""

    config = SimpleNamespace(num_hidden_layers=24, hidden_size=8)

    def encode_positions(self, probe, cached_frames):
        return torch.zeros(1, probe.shape[1], 4)


MODEL = SimpleNamespace(config=SimpleNamespace(num_prompts=4), encoder=_Encoder())


def keys(pass_cfg, cache_len, tier=TIER_560):
    """-> [T] key counts per query and the [T, C+T] mask."""
    wrapper = StreamingTapEncoder(MODEL, pass_cfg=pass_cfg, tier=tier)
    mask = wrapper.key_mask(torch.tensor([cache_len], dtype=torch.int32))
    return mask.sum(1).tolist(), mask


def sliding_window(pass_cfg, cache_len, tier=TIER_560):
    """The pre-fix causal window, kept as the lookahead-0 reference formula."""
    C, T = pass_cfg.left, tier.chunk_frames
    qi = torch.arange(T, dtype=torch.float32)[:, None]
    kv = torch.arange(C + T, dtype=torch.float32)[None, :]
    return (kv >= qi) & (kv <= C + qi) & (kv >= C - cache_len)


class MaskGeometryTests(unittest.TestCase):
    def test_reference_pass_is_a_57_key_sliding_window(self):
        # HF sliding_window=57 at lookahead 0: query qi sees [qi, left+qi]
        counts, mask = keys(REFERENCE, REFERENCE.left)
        self.assertEqual(counts, [57] * CHUNK_FRAMES)
        for qi in range(CHUNK_FRAMES):
            self.assertEqual(mask[qi].nonzero().flatten().tolist(),
                             list(range(qi, REFERENCE.left + qi + 1)))

    def test_shipping_pass_is_the_documented_block_mask_not_a_sliding_window(self):
        # 42 cache + 8 current: 4 blocks of 14, every query in the last block sees all 50
        counts, mask = keys(SHIPPING, SHIPPING.left)
        self.assertEqual(counts, [50] * CHUNK_FRAMES)
        for qi in range(CHUNK_FRAMES):
            self.assertEqual(mask[qi].nonzero().flatten().tolist(), list(range(0, 50)))
            # the defect: with the causal clamp every query saw keys 0..42+qi, so the
            # furthest visible key equalled the query's own position (no lookahead at all)
            self.assertGreater(mask[qi].nonzero().max().item(), SHIPPING.left + qi - 1)
        # lookahead is real: the last block's queries reach 13 keys past the oldest of them
        first = SHIPPING.left  # position of the first query of the current chunk's block
        self.assertEqual(mask[0].nonzero().max().item() - first, 7)

    def test_lookahead_zero_reduces_to_the_sliding_window(self):
        for pass_cfg in (REFERENCE,):
            for cache_len in (1, 7, 14, pass_cfg.left - 1, pass_cfg.left):
                _, got = keys(pass_cfg, cache_len)
                self.assertTrue(torch.equal(got, sliding_window(pass_cfg, cache_len)))

    def test_320ms_tier_keeps_the_42_13_block_mask(self):
        # 320 ms: 32 new mel -> 4 released rows, 5 rows with the context row. The
        # block mask is unchanged; at this T every query still lands in the last
        # 14-key block, so each sees the whole 42-cache + 5-row window (47 keys).
        tier = TIER_320
        counts, mask = keys(SHIPPING, SHIPPING.left, tier)
        self.assertEqual(counts, [SHIPPING.left + tier.chunk_frames] * tier.chunk_frames)
        for qi in range(tier.chunk_frames):
            self.assertEqual(mask[qi].nonzero().flatten().tolist(),
                             list(range(0, SHIPPING.left + tier.chunk_frames)))
        # reference pass at the same tier is still the 57-key sliding window
        counts, _ = keys(REFERENCE, REFERENCE.left, tier)
        self.assertEqual(counts, [REFERENCE.left + 1] * tier.chunk_frames)
        # and the lookahead-0 identity still holds at the new T
        for cache_len in (1, 7, 14, REFERENCE.left):
            _, got = keys(REFERENCE, cache_len, tier)
            self.assertTrue(torch.equal(got, sliding_window(REFERENCE, cache_len, tier)))

    def test_batched_mask_is_per_stream(self):
        # a B=2 graph must not share one stream's cache length across the batch
        tier = TIER_320
        w1 = StreamingTapEncoder(MODEL, SHIPPING, tier=tier, batch=1)
        w2 = StreamingTapEncoder(MODEL, SHIPPING, tier=tier, batch=2)
        m2 = w2.key_mask(torch.tensor([1, SHIPPING.left], dtype=torch.int32))
        kt = SHIPPING.left + tier.chunk_frames
        self.assertEqual(tuple(m2.shape), (2, tier.chunk_frames, kt))
        self.assertTrue(torch.equal(m2[0], w1.key_mask(torch.tensor([1]))))
        self.assertTrue(torch.equal(m2[1], w1.key_mask(torch.tensor([SHIPPING.left]))))

    def test_partial_cache_drops_unfilled_slots_only(self):
        # the manager seeds cache_len=1; a partial cache must intersect the window,
        # never widen it past the block bounds
        for cache_len, expected in ((1, 9), (14, 22), (28, 36), (42, 50)):
            counts, _ = keys(SHIPPING, cache_len)
            self.assertEqual(counts, [expected] * CHUNK_FRAMES)
        counts, _ = keys(REFERENCE, 1)
        self.assertEqual(counts, [2, 3, 4, 5, 6, 7, 8, 9])


if __name__ == "__main__":
    unittest.main()
