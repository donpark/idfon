"""parity6 — the S4 Core ML acceptance.

Runs the exported Core ML graphs (TygerEncoder + TygerStep, the ANE shipping path)
against the torch oracle (ReferenceEars) on real conversation audio, with identical
windows, mel, rules.py and GRU-state threading. Acceptance: per-head |Δscore| ≤ 0.02.

Scope = the steady-state contract: 8 s sliding windows (the static 800-mel shape the
graphs export). Both chains reset at the first compared hop, so the carried state is
shared; startup (growing windows → enumerated shapes) is a documented follow-up.

Usage: TYGER_S2S=... python parity6.py [--minutes 1.0]
"""
import argparse
import importlib.machinery
import os
import sys
import time
from pathlib import Path

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE", os.path.expanduser(
    "~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6"))
MODELS = Path(HERE).resolve().parents[1] / "bench-results" / "coreml"
sys.path.insert(0, S2S)
sys.path.insert(0, os.path.join(S2S, "scripts"))

import torch  # noqa: E402
from datasets import load_dataset  # noqa: E402
from transformers import AutoModel  # noqa: E402

from app.plugins.ears.tyger import rules  # noqa: E402
from app.plugins.ears.tyger.constants import SR  # noqa: E402
from app.plugins.ears.tyger.session import EarsSession  # noqa: E402
from validate.reference import ReferenceEars  # noqa: E402

HOP_FRAMES = 4
WIN_S = 8
HOP = HOP_FRAMES * SR * 80 // 1000
HEADS8 = ("state0", "state1", "state2", "state3", "hazard", "yield", "bc", "ep")


class Chain:
    """One decision path: encode both windows, score HOP_FRAMES frames via rules."""

    def __init__(self, kind, ears=None, enc=None, step=None):
        self.kind = kind
        self.ears = ears
        self.enc, self.step = enc, step
        self.reset()

    def reset(self):
        self.sess = EarsSession(0)
        self.state = np.zeros((3, 1, 768), dtype=np.float32)
        self.outs, self.events = [], []
        self.ms = 0.0

    def _encode(self, wav):
        t0 = time.perf_counter()
        if self.kind == "torch":
            h = self.ears.encode_l15(wav)  # torch: head_step takes tensors
        else:
            feats = self.feats(wav)
            h = list(self.enc.predict({"feats": feats}).values())[0][0]
        self.ms += (time.perf_counter() - t0) * 1000
        return h

    def feed(self, win_u, win_a, mode):
        hu, ha = self._encode(win_u), self._encode(win_a)
        act = rules.frame_energy(win_u)
        for i in range(-min(HOP_FRAMES, len(hu), len(ha), len(act)), 0):
            if self.kind == "torch":
                t0 = time.perf_counter()
                out = self.ears.head_step(hu[i], ha[i], float(act[i]), int(self.sess.prev_state))
                self.ms += (time.perf_counter() - t0) * 1000
            else:
                t0 = time.perf_counter()
                out = self.step.predict({
                    "hu": hu[i][None, None], "ha": ha[i][None, None],
                    "act_db": np.array([[float(act[i])]], dtype=np.float32),
                    "prev_state": np.array([[int(self.sess.prev_state)]], dtype=np.int32),
                    "state_workaround": self.state,  # "state" is reserved in Core ML (MLState)
                })
                self.ms += (time.perf_counter() - t0) * 1000
                vals = list(out.values())
                self.state = vals[1]
                out = vals[0][0, 0]
            evs, _final, _reset = rules.on_frame(self.sess, mode, np.asarray(out), float(act[i]), left=-i - 1)
            self.outs.append(np.asarray(out, dtype=np.float64))
            self.events.append([(e["kind"], e.get("onset_s"), e.get("turn_s")) for e in evs if e["kind"] != "FRAME"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=1.0)
    ap.add_argument("--skip", type=int, default=0)
    ap.add_argument("--dataset", default="anyreach-ai/dualturn-otospeech-turn-taking")
    ap.add_argument("--split", default="val")
    ap.add_argument("--enc", default="TygerEncoder.mlpackage",
                    help="encoder model under bench-results/coreml (e.g. TygerEncoderQ8.mlpackage)")
    ap.add_argument("--enc-front", default="",
                    help="split export: fp32 front (stem + layers.0)")
    ap.add_argument("--enc-tail", default="",
                    help="split export: tail (layers.1..14), optionally quantised")
    args = ap.parse_args()

    import coremltools as ct

    te = importlib.machinery.SourceFileLoader(
        "te", os.path.join(HERE, "..", "..", "scripts", "tyger-eval.py")).load_module()
    torch.set_num_threads(4)
    ears = ReferenceEars(BUNDLE, device="cpu")
    if args.enc_tail:
        enc_front = ct.models.MLModel(str(MODELS / args.enc_front))
        enc_tail = ct.models.MLModel(str(MODELS / args.enc_tail))

        class TwoPart:
            def predict(self, d):
                h = list(enc_front.predict({"feats": d["feats"]}).values())[0]
                return {"hidden_out": list(enc_tail.predict({"hidden": h}).values())[0]}
        enc = TwoPart()
    else:
        enc = ct.models.MLModel(str(MODELS / args.enc))
    step = ct.models.MLModel(str(MODELS / "TygerStep.mlpackage"))

    def feats(wav):
        w = np.asarray(wav, dtype=np.float32)
        w = np.concatenate([w, np.zeros(WIN_S * SR - len(w), np.float32)]) if len(w) < WIN_S * SR else w[-WIN_S * SR:]
        f = ears.proc(w, sampling_rate=SR, return_tensors="pt")["input_features"].numpy()
        return f.astype(np.float32)

    rows = iter(load_dataset(args.dataset, split=args.split, streaming=True))
    for _ in range(args.skip):
        next(rows)
    row = next(rows)
    T = int(row["num_frames"])
    limit = min(T, int(args.minutes * 60 * 12.5))
    codes = {ch: np.array(row[f"codes_{ch}"], dtype=np.int16).reshape(T, 8)[:limit] for ch in ("ch0", "ch1")}
    wavs = {ch: te.resample16k(te.decode_channel(AutoModel.from_pretrained(
        "kyutai/mimi", dtype=torch.float32).eval(), codes[ch])) for ch in ("ch0", "ch1")}
    n_hops = min(len(wavs["ch0"]), len(wavs["ch1"])) // HOP
    warm = WIN_S * SR // HOP  # steady-state: window full
    print(f"session {row['session_id'][:12]}…: {limit / 12.5:.0f}s, {n_hops} hops, comparing from hop {warm}")

    a = Chain("torch", ears=ears)
    b = Chain("coreml", enc=enc, step=step)
    b.feats = a.feats = feats
    compared = 0
    for h in range(warm, n_hops):
        s = (h + 1) * HOP
        win = {ch: wavs[ch][s - WIN_S * SR:s] for ch in ("ch0", "ch1")}
        a.feed(win["ch0"], win["ch1"], "response")
        b.feed(win["ch0"], win["ch1"], "response")
        compared += 1

    A, B = np.array(a.outs), np.array(b.outs)
    n = min(len(A), len(B))
    A, B = A[:n], B[:n]
    print(f"frames compared: {n} ({compared} hops, steady-state windows)")
    worst = 0.0
    for j, name in enumerate(HEADS8):
        d = float(np.abs(A[:, j] - B[:, j]).max()) if n else 0.0
        worst = max(worst, d)
        print(f"  head {name:7} max|Δ| {d:.4f}")
    d8 = np.abs(A - B) if n else np.zeros((1, 8))
    print(f"per-head max|Δ| {worst:.4f}  ({'PASS' if worst <= 0.02 else 'FAIL'}, budget 0.02)")
    print(f"  all heads+frames: p50 {np.percentile(d8, 50):.4f}  p95 {np.percentile(d8, 95):.4f}  "
          f"p99 {np.percentile(d8, 99):.4f}")

    ea = [e for he in a.events for e in he]
    eb = [e for he in b.events for e in he]
    same = sum(1 for x, y in zip(ea, eb) if x == y)
    print(f"rules decisions: torch={len(ea)} coreml={len(eb)}  aligned-identical {same}")
    print(f"encode+step per hop (both windows): torch {a.ms / max(compared, 1):.1f} ms   "
          f"coreml {b.ms / max(compared, 1):.1f} ms")
    ok = worst <= 0.02
    print(f"\nRESULT: {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
