"""MlxEars: the MLX decision chain with `ReferenceEars.feed`'s interface.

Drop-in for tyger-s2s's `scripts/validate/reference.py::ReferenceEars` so
`tyger-eval.py --engine mlx` runs sessions through the ported encoder+GRU and the
*same* `rules.py`, and the per-frame scores can be diffed against the torch
`--dump-scores` reference (docs/voice-tyger-ondevice.md, S2→S3 bridge).

Same contract as ReferenceEars: `feed(sess, user_hop, agent_hop, mode)` takes 320 ms
hops of 16 kHz float audio and returns rules events. The only behavioral difference:
`transcript` on ENDPOINT events is None here — the RNN-T is not ported (the heads never
read it; transcripts come from the configured STT or a later port).
"""
import os
import sys
from pathlib import Path

import numpy as np

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
sys.path.insert(0, S2S)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))

import mlx.core as mx  # noqa: E402

from app.plugins.ears.tyger import rules  # noqa: E402
from app.plugins.ears.tyger.bundle import load as bundle_load  # noqa: E402
from app.plugins.ears.tyger.constants import L15, SR  # noqa: E402

from encoder import EncoderL15  # noqa: E402
from turn_taker import TurnTaker  # noqa: E402

HOP_FRAMES = 4


class MlxEars:
    def __init__(self, bundle_dir, layers=L15):
        _asr, self.proc, _tt, _cfg = bundle_load(Path(bundle_dir))
        self.enc = EncoderL15(bundle_dir, layers=min(layers, 15))
        self.tt = TurnTaker(bundle_dir)
        self.cache = None

    def encode_l15(self, wav):
        """(frames, 1024) from one 16 kHz window — the torch processor computes the
        mel features; the port encodes them (encoder parity is what we measure)."""
        if len(wav) == 0:
            return mx.zeros((0, 1024))
        feats = self.proc(np.asarray(wav, dtype=np.float32), sampling_rate=SR, return_tensors="pt")["input_features"]
        return self.enc(mx.array(feats.numpy()))[0]

    def head_step(self, hu, ha, act_db, prev_state):
        """One frame -> the 8-vector. Energy is normalised here, exactly as their
        ReferenceEars.head_step does outside the model."""
        act = mx.array([[min(3.0, max(-3.0, (float(act_db) + 50) / 25))]])
        out, self.cache = self.tt.step(hu[None, None], ha[None, None], act, mx.array([[int(prev_state)]]), self.cache)
        return np.array(out)[0, 0]

    def feed(self, sess, user_hop, agent_hop, mode):
        if rules.begin_hop(sess, user_hop, agent_hop, mode):
            self.cache = None
        hu, ha = self.encode_l15(sess.win_u), self.encode_l15(sess.win_a)
        act = rules.frame_energy(sess.win_u)
        if rules.switch_mode(sess, mode):
            self.cache = None
        events = []
        for i in range(-min(HOP_FRAMES, len(hu), len(ha), len(act)), 0):
            out = self.head_step(hu[i], ha[i], act[i], sess.prev_state)
            evs, final, reset = rules.on_frame(sess, mode, out, float(act[i]), left=-i - 1)
            if final is not None:
                ev, _wav = final
                ev.pop("seg_texts", None)
                ev["transcript"] = None  # the RNN-T is not ported; the heads never read it
            events += evs
            if reset:
                self.cache = None
        return events
