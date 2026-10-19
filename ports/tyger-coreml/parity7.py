"""parity7 — the shipping tier's guard: scaled decision agreement.

Runs the full shipping contract (TygerEncoderDyn at startup + TygerEncoder fp16 at
steady state + fp32 step) against the fp32 reference chain over many real
conversations, through the same rules.py, and reports decision agreement — the
metric the fp16 tier was accepted under (docs/voice-tyger-ondevice.md, "Guard
conditions"). No GPU box needed: both chains run on this Mac's Core ML.

Usage:
  TYGER_S2S=... python parity7.py [--sessions 8] [--minutes 3] [--dataset ...]
"""
import argparse
import importlib.machinery
import os
import sys
from pathlib import Path

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE", os.path.expanduser(
    "~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6"))
MODELS = Path(HERE).resolve().parents[1] / "bench-results" / "coreml"
sys.path.insert(0, S2S)
sys.path.insert(0, os.path.join(S2S, "scripts"))

import coremltools as ct  # noqa: E402
import torch  # noqa: E402
from datasets import load_dataset  # noqa: E402
from transformers import AutoModel  # noqa: E402

from app.plugins.ears.tyger import rules  # noqa: E402
from app.plugins.ears.tyger.constants import SR  # noqa: E402
from app.plugins.ears.tyger.session import EarsSession  # noqa: E402

HOP_FRAMES = 4
WIN_S = 8
HOP = HOP_FRAMES * SR * 80 // 1000
HEADS8 = ("state0", "state1", "state2", "state3", "hazard", "yield", "bc", "ep")


class Enc:
    """fp32 reference encoder, or the shipping contract (dyn while the window grows)."""

    def __init__(self, fixed, dyn=None):
        self.fixed, self.dyn = fixed, dyn

    def predict(self, feats):
        model = self.dyn if (self.dyn is not None and feats.shape[1] < 801) else self.fixed
        return list(model.predict({"feats": feats}).values())[0][0]


class Chain:
    def __init__(self, enc, step, feats):
        self.enc, self.step, self.feats = enc, step, feats
        self.reset()

    def reset(self):
        self.sess = EarsSession(0)
        self.state = np.zeros((3, 1, 768), dtype=np.float32)
        self.outs, self.events = [], []
        self.frame = 0

    def feed(self, win_u, win_a, mode):
        hu, ha = self.enc.predict(self.feats(win_u)), self.enc.predict(self.feats(win_a))
        act = rules.frame_energy(win_u)
        for i in range(-min(HOP_FRAMES, len(hu), len(ha), len(act)), 0):
            self.frame += 1
            out = self.step.predict({
                "hu": hu[i][None, None], "ha": ha[i][None, None],
                "act_db": np.array([[float(act[i])]], dtype=np.float32),
                "prev_state": np.array([[int(self.sess.prev_state)]], dtype=np.int32),
                "state_workaround": self.state,
            })
            vals = list(out.values())
            self.state = vals[1]
            o = np.asarray(vals[0][0, 0], dtype=np.float64)
            evs, _final, _reset = rules.on_frame(self.sess, mode, o, float(act[i]), left=-i - 1)
            self.outs.append(o)
            for e in evs:
                if e["kind"] != "FRAME":
                    self.events.append((self.frame, e["kind"]))

    def dump(self, path):
        np.savez(path, outs=np.asarray(self.outs), events=np.asarray(self.events, dtype=object), allow_pickle=True)


def aligned_count(a, b, tol):
    """Events of the same kind within `tol` frames = the same decision (threshold crossings
    jitter by a frame under fp16); greedy earliest match. Returns (matches, only_ref, only_cand)."""
    used = set()
    for fa, ka in a:
        for j, (fb, kb) in enumerate(b):
            if j not in used and ka == kb and abs(fa - fb) <= tol:
                used.add(j)
                break
    return len(used), len(a) - len(used), len(b) - len(used)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sessions", type=int, default=8)
    ap.add_argument("--minutes", type=float, default=3.0)
    ap.add_argument("--skip", type=int, default=0)
    ap.add_argument("--tol", type=int, default=2, help="frames (80 ms) within which same-kind events count as one decision")
    ap.add_argument("--dump", default=None, help="directory to save per-session npz (outs + events) for margin analysis")
    ap.add_argument("--dataset", default="anyreach-ai/dualturn-otospeech-turn-taking")
    ap.add_argument("--split", default="val")
    args = ap.parse_args()

    te = importlib.machinery.SourceFileLoader(
        "te", os.path.join(HERE, "..", "..", "scripts", "tyger-eval.py")).load_module()
    step = ct.models.MLModel(str(MODELS / "TygerStep.mlpackage"))
    dyn = ct.models.MLModel(str(MODELS / "TygerEncoderDyn.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    fp16 = ct.models.MLModel(str(MODELS / "TygerEncoder.mlpackage"))
    # reference = the exact fp32 dynamic model at every size; candidate = the shipping
    # contract (dyn while the window grows, fp16 at steady state)
    ref = Chain(Enc(dyn), step, None)
    cand = Chain(Enc(fp16, dyn), step, None)

    def feats(wav):
        return _proc(np.asarray(wav, dtype=np.float32))

    mimi = AutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()

    def _proc(w):
        return _feats_proc(w, sampling_rate=SR, return_tensors="pt")["input_features"].numpy().astype(np.float32)

    global _feats_proc
    from app.plugins.ears.tyger.bundle import load as bundle_load
    _asr, _feats_proc, _tt, _cfg = bundle_load(Path(BUNDLE))
    ref.feats = cand.feats = feats

    rows = iter(load_dataset(args.dataset, split=args.split, streaming=True))
    for _ in range(args.skip):
        next(rows)
    total_frames = agree = 0
    ev_total = ev_same = 0
    worst = np.zeros(8)
    sums = np.zeros(8)
    for s in range(args.sessions):
        try:
            row = next(rows)
        except StopIteration:
            break
        T = int(row["num_frames"])
        limit = min(T, int(args.minutes * 60 * 12.5))
        codes = {ch: np.array(row[f"codes_{ch}"], dtype=np.int16).reshape(T, 8)[:limit] for ch in ("ch0", "ch1")}
        wavs = {ch: te.resample16k(te.decode_channel(mimi, codes[ch])) for ch in ("ch0", "ch1")}
        n_hops = min(len(wavs["ch0"]), len(wavs["ch1"])) // HOP
        ref.reset()
        cand.reset()
        for h in range(n_hops):
            x = (h + 1) * HOP
            win = {ch: wavs[ch][max(0, x - WIN_S * SR):x] for ch in ("ch0", "ch1")}
            ref.feed(win["ch0"], win["ch1"], "response")
            cand.feed(win["ch0"], win["ch1"], "response")
        n = min(len(ref.outs), len(cand.outs))
        A, B = np.array(ref.outs[:n]), np.array(cand.outs[:n])
        d = np.abs(A - B)
        worst = np.maximum(worst, d.max(axis=0) if n else 0)
        sums += d.sum(axis=0) if n else 0
        total_frames += n
        if args.dump:
            os.makedirs(args.dump, exist_ok=True)
            ref.dump(os.path.join(args.dump, f"s{s:02d}_ref.npz"))
            cand.dump(os.path.join(args.dump, f"s{s:02d}_cand.npz"))
        ea, eb = ref.events, cand.events
        m = min(len(ea), len(eb))
        same = sum(1 for i in range(m) if ea[i][1] == eb[i][1])
        al, only_ref, only_cand = aligned_count(ea, eb, args.tol)
        ev_same += al
        ev_total += max(len(ea), len(eb))
        print(f"  [{s + 1}/{args.sessions}] {row['session_id'][:12]}… {limit / 12.5:.0f}s "
              f"frames={n} events ref/cand={len(ea)}/{len(eb)} exact={same} aligned={al} "
              f"only_ref={only_ref} only_cand={only_cand}", flush=True)
        if al < max(len(ea), len(eb)) or same < max(len(ea), len(eb)):
            print(f"      ref  {ea}", flush=True)
            print(f"      cand {eb}", flush=True)

    print(f"\nsessions {args.sessions} × {args.minutes} min — frames {total_frames}")
    for j, name in enumerate(HEADS8):
        print(f"  head {name:7} max|Δ| {worst[j]:.4f}   mean {sums[j] / max(total_frames, 1):.4f}")
    agree_pct = 100.0 * ev_same / max(ev_total, 1)
    print(f"rules decisions (non-FRAME), same kind within ±{args.tol} frames: "
          f"{ev_same}/{ev_total} = {agree_pct:.1f}%")
    ok = agree_pct >= 99.0
    print(f"\nGUARD: {'PASS' if ok else 'FAIL'} (≥99% time-aligned decision agreement)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
