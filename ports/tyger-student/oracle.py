"""The tyger-s2s oracle seam: everything featurize.py and gate.py need from the
tyger-s2s clone and its bundle — the reference chain (encode L15 -> step the
turn-taker), the turn rules the shipped ports mirror, and the Mimi corpus decode
helpers. One import point, one env contract:

  TYGER_S2S     the tyger-s2s clone (default ~/dev/github/tyger-s2s)
  TYGER_BUNDLE  a local bundle dir. Known-good on this machine:
                ~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6

The feed contract (both consumers): per 320 ms hop, the window is the last 8 s of
each channel; the chain encodes both windows and steps the last min(4, rows) frames
through the turn-taker with the rules' carried prev_state and the per-frame `mode`
track (`mode_track.py`: the shard's track, else the agent channel's energy) —
parity7's contract (ports/tyger-coreml/parity7.py, the shipping guard).
"""
import os
import sys
from pathlib import Path

import numpy as np
import torch

SR = 16_000
FRAME_MS = 80
HOP_FRAMES = 4
HOP = HOP_FRAMES * SR * FRAME_MS // 1000  # 5120 samples = 320 ms
WIN_S = 8
GRID = 12.5  # frames per second


def decode_channel(mimi, codes_t8):
    """Mimi RVQ codes (T, 8) -> 24 kHz float audio."""
    codes = torch.from_numpy(np.asarray(codes_t8).T.copy()).long()[None]  # (1, 8, T)
    with torch.no_grad():
        return mimi.decode(codes).audio_values[0, 0].numpy()


def resample16k(x24, rate=24_000):
    n = int(round(len(x24) * SR / rate))
    return np.interp(np.linspace(0, len(x24), n, endpoint=False), np.arange(len(x24)), x24).astype(np.float32)


class Oracle:
    """The fp32 reference chain (bundle) plus the rules. Load once per process."""

    def __init__(self, device="mps"):
        s2s = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/github/tyger-s2s"))
        if not (Path(s2s) / "app").is_dir():
            sys.exit(f"TYGER_S2S does not look like a tyger-s2s clone: {s2s}")
        sys.path.insert(0, s2s)
        sys.path.insert(0, os.path.join(s2s, "scripts"))
        from app.plugins.ears.tyger import rules
        from app.plugins.ears.tyger.bundle import load as bundle_load
        from app.plugins.ears.tyger.session import EarsSession

        self.rules, self.EarsSession = rules, EarsSession
        self.device = device
        self._bundle_load = bundle_load
        self.asr = self.proc = self.tt = None

    def load_bundle(self):
        bundle = os.environ.get("TYGER_BUNDLE")
        if not bundle or not Path(bundle).is_dir():
            sys.exit("set TYGER_BUNDLE to a local bundle dir (see this file's docstring)")
        self.asr, self.proc, self.tt, _ = self._bundle_load(Path(bundle))
        self.asr = self.asr.to(self.device).eval()
        self.tt = self.tt.to(self.device).eval()
        return self

    @torch.no_grad()
    def encode_hidden(self, wav):
        """(samples,) at 16 kHz -> every encoder layer's rows [(rows, 1024) f32].
        Index 15 is the turn-taker's input (the L15 tap); the layer sweep reads the
        others from the same forward pass."""
        inp = self.proc(np.asarray(wav, np.float32), sampling_rate=SR, return_tensors="pt")
        am = inp.get("attention_mask")
        eo = self.asr.encoder(input_features=inp["input_features"].to(self.device),
                              attention_mask=am.to(self.device) if am is not None else None,
                              num_lookahead_tokens=0, output_hidden_states=True)
        return [h[0].float().cpu().numpy() for h in eo.hidden_states]

    def encode_l15(self, wav):
        """(samples,) at 16 kHz -> the L15 rows the turn-taker reads (rows, 1024)."""
        return self.encode_hidden(wav)[15]

    @torch.no_grad()
    def head_step(self, hu, ha, act_db, prev_state, cache):
        """One frame through the turn-taker, state carried: -> (the 8-vector f64, cache)."""
        act = ((torch.tensor([[float(act_db)]], device=self.device) + 50) / 25).clamp(-3, 3)
        prev = torch.tensor([[int(prev_state)]], dtype=torch.long, device=self.device)
        out, cache = self.tt(torch.as_tensor(hu, device=self.device)[None, None],
                             torch.as_tensor(ha, device=self.device)[None, None],
                             act, prev, cache)
        return out[0, 0].cpu().numpy().astype(np.float64), cache
