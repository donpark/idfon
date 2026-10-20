"""Overnight decision-parity prep (TS chain vs the fp32 oracle over the corpus).

Decodes the dualturn-otospeech corpus's 24 val sessions (3 min each, both
channels) to 16 kHz wavs, and extracts the fp32 oracle's decision events from
the accepted CoreAI guard run's dumps (/tmp/parity7-dump-coreai/sXX_ref.npz).

Writes (bench-results/sessions/, gitignored):
  sXX-ch0.wav sXX-ch1.wav   16 kHz float32 (ch0 = user, ch1 = agent)
  ref-events.json           { sXX: [[frame, kind], ...] }   (1-based frames)

Usage: TYGER_S2S=... .venv/bin/python ports/tyger-onnx/sessions-prep.py
"""
import json
import os
import sys
from pathlib import Path

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
sys.path.insert(0, S2S)
sys.path.insert(0, os.path.join(S2S, "scripts"))

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "bench-results" / "sessions"
REF_DUMP = Path("/tmp/parity7-dump-coreai")
DATASET = "anyreach-ai/dualturn-otospeech-turn-taking"
SESSIONS = 24
MINUTES = 3.0


def main():
    import numpy as np
    import soundfile as sf
    import torch
    import importlib.machinery
    from datasets import load_dataset
    from transformers import AutoModel

    te = importlib.machinery.SourceFileLoader(
        "te", str(ROOT / "scripts" / "tyger-eval.py")).load_module()

    OUT.mkdir(parents=True, exist_ok=True)
    ref_events = {}
    for s in range(SESSIONS):
        npz = REF_DUMP / f"s{s:02d}_ref.npz"
        if not npz.exists():
            raise SystemExit(f"missing oracle dump {npz} — regenerate with parity7 --cand coreai --dump")
        ev = np.load(npz, allow_pickle=True)["events"]
        ref_events[f"s{s:02d}"] = [[int(f), str(k)] for f, k in ev]
    (OUT / "ref-events.json").write_text(json.dumps(ref_events))
    print(f"wrote ref-events.json ({sum(len(v) for v in ref_events.values())} events)")

    rows = iter(load_dataset(DATASET, split="val", streaming=True))
    mimi = AutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()
    for s in range(SESSIONS):
        row = next(rows)
        T = int(row["num_frames"])
        limit = min(T, int(MINUTES * 60 * 12.5))
        for ch in ("ch0", "ch1"):
            out = OUT / f"s{s:02d}-{ch}.wav"
            if out.exists():
                continue
            codes = np.array(row[f"codes_{ch}"], dtype=np.int16).reshape(T, 8)[:limit]
            wav = te.resample16k(te.decode_channel(mimi, codes))
            sf.write(out, wav, 16000, subtype="FLOAT")
        print(f"[{s + 1}/{SESSIONS}] {row['session_id'][:12]}… {limit / 12.5:.0f}s decoded", flush=True)
    print("prep done")


if __name__ == "__main__":
    main()
