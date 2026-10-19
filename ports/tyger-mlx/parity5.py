"""parity5 — the S3 incremental-KV study.

Streams a real conversation slice (eval dataset, Mimi-decoded like tyger-eval) hop by
hop through two schemes with identical windows, mel, stem, GRU chain and rules.py:

  A  per-hop window re-encode (the reference semantics tyger-s2s validated)
  B  incremental blocks with per-layer K/V + causal-conv caches (encoder_incr.py),
     one incremental encoder per stream (user + agent)

Reports per-head max|Δ| of the per-frame 8-vectors (acceptance ≤ 0.02), rules-decision
agreement (non-FRAME events), and per-hop wall time of each encoder path.
"""
import argparse
import importlib.machinery
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE", os.path.expanduser(
    "~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6"))
sys.path.insert(0, S2S)
sys.path.insert(0, HERE)

import mlx.core as mx  # noqa: E402
import torch  # noqa: E402
from datasets import load_dataset  # noqa: E402
from transformers import AutoModel  # noqa: E402

from app.plugins.ears.tyger import rules  # noqa: E402
from app.plugins.ears.tyger.bundle import load as bundle_load  # noqa: E402
from app.plugins.ears.tyger.constants import L15, SR  # noqa: E402
from app.plugins.ears.tyger.session import EarsSession  # noqa: E402

from encoder import WINDOW, EncoderL15  # noqa: E402
from encoder_incr import EncoderL15Incr  # noqa: E402
from turn_taker import TurnTaker  # noqa: E402

HOP_FRAMES = 4
HEADS8 = ("state0", "state1", "state2", "state3", "hazard", "yield", "bc", "ep")


class Scheme:
    """One decision path: encoder(s) + GRU + rules session + capture."""

    def __init__(self, incremental):
        self.incr = incremental
        self.enc = EncoderL15Incr(BUNDLE, layers=L15) if incremental else EncoderL15(BUNDLE, layers=L15)
        self.enc_a = EncoderL15Incr(BUNDLE, layers=L15) if incremental else self.enc
        self.tt = TurnTaker(BUNDLE)
        self.sess = EarsSession(0)
        self.gru = None
        self.outs, self.events = [], []
        self.ms = 0.0

    def _reset(self):
        if self.incr:
            self.enc.reset()
            self.enc_a.reset()
        self.gru = None

    def _encode(self, enc, wav):
        feats = proc(wav, sampling_rate=SR, return_tensors="pt")["input_features"]
        x = mx.array(feats.numpy())
        t0 = time.perf_counter()
        h = enc.step(x, HOP_FRAMES) if self.incr else enc(x)
        if not self.incr:
            mx.eval(h)
        self.ms += (time.perf_counter() - t0) * 1000
        return h[0]  # (frames, 1024) like mlx_ears.encode_l15: len() must be frames, not batch

    def feed(self, user_hop, agent_hop, mode):
        if rules.begin_hop(self.sess, user_hop, agent_hop, mode):
            self._reset()
        hu = self._encode(self.enc, self.sess.win_u)
        ha = self._encode(self.enc_a, self.sess.win_a)
        act = rules.frame_energy(self.sess.win_u)
        if rules.switch_mode(self.sess, mode):
            self._reset()
        for i in range(-min(HOP_FRAMES, len(hu), len(ha), len(act)), 0):
            a = mx.array([[(float(act[i]) + 50) / 25]])
            out, self.gru = self.tt.step(hu[i][None, None], ha[i][None, None], a,
                                        mx.array([[int(self.sess.prev_state)]]), self.gru)
            out = np.array(out)[0, 0]
            evs, _final, reset = rules.on_frame(self.sess, mode, out, float(act[i]), left=-i - 1)
            self.outs.append(out)
            self.events.append([(e["kind"], e.get("onset_s"), e.get("turn_s")) for e in evs if e["kind"] != "FRAME"])
            if reset:
                self._reset()


def self_test():
    """Math check: block-stepping on identical context must equal batch to float noise.
    Any divergence here is an implementation bug in the caches, not physics."""
    import mlx.core as mx
    _asr, proc_, _tt, _cfg = bundle_load(BUNDLE)
    enc = EncoderL15(BUNDLE, layers=L15)
    incr = EncoderL15Incr(BUNDLE, layers=L15)
    wav = np.random.default_rng(0).standard_normal(8 * SR).astype(np.float32) * 0.1
    feats = mx.array(proc_(wav, sampling_rate=SR, return_tensors="pt")["input_features"].numpy())
    h = enc.sub(feats.astype(enc.dtype))
    t = h.shape[1]
    pos_emb = enc.positions(t)[None]
    idx = mx.arange(t)
    diff = idx[:, None] - idx[None, :]
    mask = (diff >= 0) & (diff <= WINDOW - 1)
    x = h
    for blk in enc.blocks:
        x = blk(x, pos_emb, mask)
    ref = np.array(x)
    incr.reset()
    got = []
    for s_ in range(0, t, 4):
        got.append(np.array(incr.step_h(h[:, s_:s_ + 4])))
    got = np.concatenate(got, axis=1)
    d = float(np.abs(ref - got).max())
    print(f"self-test: stepped == batch over {t} frames: max|Δ| {d:.3e}  ({'PASS' if d < 1e-4 else 'FAIL'})")
    sys.exit(0 if d < 1e-4 else 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--minutes", type=float, default=1.0)
    ap.add_argument("--skip", type=int, default=0)
    ap.add_argument("--dataset", default="anyreach-ai/dualturn-otospeech-turn-taking")
    ap.add_argument("--split", default="val")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return

    global proc
    te = importlib.machinery.SourceFileLoader(
        "te", os.path.join(HERE, "..", "..", "scripts", "tyger-eval.py")).load_module()
    _asr, proc, _tt, _cfg = bundle_load(BUNDLE)
    mimi = AutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()

    rows = iter(load_dataset(args.dataset, split=args.split, streaming=True))
    for _ in range(args.skip):
        next(rows)
    row = next(rows)
    T = int(row["num_frames"])
    limit = min(T, int(args.minutes * 60 * 12.5))
    print(f"session {row['session_id']}: {limit / 12.5:.0f}s of {row['duration_s']:.0f}s")
    codes = {ch: np.array(row[f"codes_{ch}"], dtype=np.int16).reshape(T, 8)[:limit] for ch in ("ch0", "ch1")}
    wavs = {ch: te.resample16k(te.decode_channel(mimi, codes[ch])) for ch in ("ch0", "ch1")}
    hop = HOP_FRAMES * SR * 80 // 1000
    n_hops = min(len(wavs["ch0"]), len(wavs["ch1"])) // hop

    a, b = Scheme(False), Scheme(True)
    for h in range(n_hops):
        u = wavs["ch0"][h * hop:(h + 1) * hop]
        g = wavs["ch1"][h * hop:(h + 1) * hop]
        a.feed(u, g, "response")
        b.feed(u, g, "response")

    A, B = np.array(a.outs), np.array(b.outs)
    n = min(len(A), len(B))
    A, B = A[:n], B[:n]
    print(f"\nframes compared: {n}; hops: {n_hops}")
    worst = 0.0
    for j, name in enumerate(HEADS8):
        d = float(np.abs(A[:, j] - B[:, j]).max()) if n else 0.0
        worst = max(worst, d)
        print(f"  head {name:7} max|Δ| {d:.4f}")
    d8 = np.abs(A - B) if n else np.zeros((1, 8))
    print(f"per-head max|Δ| {worst:.4f}  ({'PASS' if worst <= 0.02 else 'FAIL'}, budget 0.02)")
    print(f"  across all heads+frames: p50 {np.percentile(d8, 50):.4f}  p95 {np.percentile(d8, 95):.4f}  "
          f"p99 {np.percentile(d8, 99):.4f}")

    ea = [e for hop_evs in a.events for e in hop_evs]
    eb = [e for hop_evs in b.events for e in hop_evs]
    same = sum(1 for x, y in zip(ea, eb) if x == y)
    ka = [k for k, _, _ in ea]
    kb = [k for k, _, _ in eb]
    print(f"rules decisions (non-FRAME): A={len(ea)} B={len(eb)}  aligned-identical {same}")
    print(f"  kinds A: {sorted(set(ka))}  B: {sorted(set(kb))}")

    print(f"encoder time per hop: A (re-encode, both streams) {a.ms / max(n_hops, 1):.1f} ms   "
          f"B (incremental) {b.ms / max(n_hops, 1):.1f} ms")
    ok = worst <= 0.02
    print(f"\nRESULT: {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
