"""MLX int4 smoke: the quantised chain's per-frame 8-vectors vs the torch
oracle (expectations.json, 248 frames of real conversation, prev_state 0) —
the cheap drift check before the 24-session decision guard.

  TYGER_S2S=~/dev/tyger-s2s ~/dev/tyger-s2s/.venv/bin/python ports/tyger-mlx/smoke-int4.py
"""
import json
import os
import sys
from pathlib import Path

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE", os.path.expanduser(
    "~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6"))
sys.path.insert(0, S2S)
sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "ports" / "tyger-swift" / "Tests" / "TygerVoiceTests" / "runtime"


def main():
    import numpy as np
    import soundfile as sf
    os.environ["TYGER_MLX_PRECISION"] = "int4"
    from mlx_ears import MlxEars
    from app.plugins.ears.tyger import rules
    from app.plugins.ears.tyger.constants import SR

    want = json.loads((RUNTIME / "expectations.json").read_text())["frames"]
    wavs = {ch: sf.read(RUNTIME / f"{ch}.wav", dtype="float32")[0] for ch in ("ch0", "ch1")}
    ears = MlxEars(BUNDLE)
    hop = 5120
    n_hops = min(len(wavs["ch0"]), len(wavs["ch1"])) // hop
    got = []
    for h in range(n_hops):
        s = (h + 1) * hop
        wins = {ch: wavs[ch][max(0, s - 8 * SR):s] for ch in ("ch0", "ch1")}
        hu, ha = ears.encode_l15(wins["ch0"]), ears.encode_l15(wins["ch1"])
        act = rules.frame_energy(wins["ch0"])
        for i in range(-min(4, len(hu), len(ha), len(act)), 0):
            got.append(np.asarray(ears.head_step(hu[i], ha[i], float(act[i]), 0), dtype=np.float64))
    n = min(len(got), len(want))
    d = np.abs(np.array(got[:n]) - np.array(want[:n]))
    names = ["state0", "state1", "state2", "state3", "hazard", "yield", "bc", "p_end"]
    print(f"frames {n}")
    for j, name in enumerate(names):
        print(f"  {name:8s} max {d[:, j].max():.4f}  mean {d[:, j].mean():.4f}")


if __name__ == "__main__":
    main()
