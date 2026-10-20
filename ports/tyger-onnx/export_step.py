"""Export the tyger turn-taker STEP to ONNX, and dump oracle pairs for the Node parity gate.

This is slice 1 of the eve TS agent's decision model (the "spirit of tyger-s2s, our form"):
`ports/tyger-onnx/` makes the model runnable in-process in the TypeScript agent via
onnxruntime-node. The contract mirrors ports/tyger-coreml/export.py's StepWrap 1:1, so the
ONNX graph and the CoreML graph are the same thing:

  TygerStep   hu (1,1,1024), ha (1,1,1024), act_db (1,1), prev_state (1,1 int64),
              state (3,1,768) -> out (1,1,8), state (3,1,768)

Energy normalisation ((act_db+50)/25 clamp) is baked in: head_step semantics.

Also writes step-oracle.json: sampled frames of real conversation audio
(ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch{0,1}.wav) run through the torch
oracle with the GRU state threaded exactly as ReferenceEars.head_step does, each frame
dumped with its own state_in/out so the JS gate replays frames independently.

Usage:  TYGER_S2S=... .venv/bin/python ports/tyger-onnx/export_step.py
Output: bench-results/onnx/TygerStep.onnx + bench-results/onnx/step-oracle.json (gitignored)
"""
import importlib.machinery
import json
import os
import sys
from pathlib import Path

import numpy as np
import torch

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE", os.path.expanduser(
    "~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6"))
sys.path.insert(0, S2S)
sys.path.insert(0, os.path.join(S2S, "scripts"))

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "bench-results" / "onnx"
RUNTIME = ROOT / "ports" / "tyger-swift" / "Tests" / "TygerVoiceTests" / "runtime"


def main():
    import soundfile as sf
    from app.plugins.ears.tyger import rules
    from app.plugins.ears.tyger.constants import SR
    from validate.reference import ReferenceEars

    StepWrap = importlib.machinery.SourceFileLoader(
        "coreml_export", str(ROOT / "ports" / "tyger-coreml" / "export.py")).load_module().StepWrap

    torch.set_num_threads(4)
    ears = ReferenceEars(Path(BUNDLE), device="cpu")
    tt = ears.turn_taker.eval()
    wrap = StepWrap(tt).eval()

    OUT.mkdir(parents=True, exist_ok=True)
    onnx_path = OUT / "TygerStep.onnx"
    ex = (torch.zeros(1, 1, 1024), torch.zeros(1, 1, 1024), torch.zeros(1, 1),
          torch.zeros(1, 1, dtype=torch.long), torch.zeros(3, 1, 768))
    # sanity: StepWrap == head_step's semantics (the normalisation is in the graph)
    with torch.no_grad():
        o_w, _ = wrap(ex[0], ex[1], ex[2], ex[3], ex[4])
        o_t, _ = tt(ex[0], ex[1], ((ex[2] + 50) / 25).clamp(-3, 3), ex[3], ex[4])
    assert (o_w - o_t).abs().max() < 1e-6, "StepWrap != normalized tt"
    torch.onnx.export(wrap, ex, str(onnx_path),
                      input_names=["hu", "ha", "act_db", "prev_state", "state"],
                      output_names=["out", "state_out"])
    print(f"wrote {onnx_path} ({onnx_path.stat().st_size / 1e6:.1f} MB)")

    # Oracle dump: real frames, state threaded as head_step (prev_state held at 0,
    # like the Swift fixtures — rules threading is covered by the Rust fixtures).
    wavs = {ch: sf.read(RUNTIME / f"{ch}.wav", dtype="float32")[0] for ch in ("ch0", "ch1")}
    hop = 5120
    n_hops = min(len(wavs["ch0"]), len(wavs["ch1"])) // hop
    state = None
    rows, sampled = [], 0
    with torch.no_grad():
        for h in range(n_hops):
            s = (h + 1) * hop
            wins = {ch: wavs[ch][max(0, s - 8 * SR):s] for ch in ("ch0", "ch1")}
            hu, ha = ears.encode_l15(wins["ch0"]), ears.encode_l15(wins["ch1"])
            act = rules.frame_energy(wins["ch0"])
            for i in range(min(len(hu), len(ha), len(act))):
                hu_i, ha_i = hu[i][None, None], ha[i][None, None]
                act_i = torch.tensor([[float(act[i])]])
                prev = torch.zeros(1, 1, dtype=torch.long)
                state_in = state if state is not None else torch.zeros(3, 1, 768)
                # the SAME StepWrap the export used: act_db normalisation is baked in
                # there (head_step semantics), so dump == export, not a parallel path.
                out, state = wrap(hu_i, ha_i, act_i, prev, state_in)
                if sampled < 48 or (i >= len(hu) - 4 and sampled < 96):
                    sampled += 1
                    rows.append({
                        "act_db": round(float(act[i]), 6),
                        "hu": [round(float(v), 6) for v in hu[i].numpy()],
                        "ha": [round(float(v), 6) for v in ha[i].numpy()],
                        "state_in": [round(float(v), 6) for v in state_in.flatten().numpy()],
                        "out": [round(float(v), 7) for v in out[0, 0].numpy()],
                        "state_out": [round(float(v), 6) for v in state.flatten().numpy()],
                    })
    (OUT / "step-oracle.json").write_text(json.dumps({"frames": rows}))
    print(f"wrote step-oracle.json: {len(rows)} frames over {n_hops} hops")

    if "--dyn" in sys.argv:
        # The encoder for the TS engine: masked, DYNAMIC mel (the 8k-7 startup law),
        # via torch.export + the dynamo ONNX path. Requires the tyger-s2s venv's
        # transformers patch (attention head-merge reshape: clone(memory_format=
        # contiguous_format) before reshape — torch.export refuses the transposed
        # view and contiguous() is elided in decomposition).
        EncMaskWrap = importlib.machinery.SourceFileLoader(
            "coreml_export", str(ROOT / "ports" / "tyger-coreml" / "export.py")).load_module().EncMaskWrap
        enc = EncMaskWrap(ears.asr).eval()
        mel_dim = 8 * torch.export.Dim("_mel", min=5, max=101) - 7  # mel lengths are 8k-7
        ex = (torch.zeros(1, 33, 128), torch.ones(1, 33, dtype=torch.long))
        ep = torch.export.export(
            enc, ex, dynamic_shapes={"feats": {1: mel_dim}, "mask": {1: mel_dim}}
        ).run_decompositions({})
        dyn_path = OUT / "TygerEncoderDyn.onnx"
        torch.onnx.export(ep, (), str(dyn_path), input_names=["mel", "mask"], output_names=["hidden"])
        print(f"wrote {dyn_path} ({dyn_path.stat().st_size / 1e6:.0f} MB, dynamic mel 8k-7)")

    if "--enc" in sys.argv:
        # The encoder half (638M): mel (1, 801, 128) -> hidden L15 (1, 101, 1024),
        # the full-window re-encode semantics both accepted runtimes use. External
        # weight data (~2.5 GB) lands next to the .onnx.
        EncWrap = importlib.machinery.SourceFileLoader(
            "coreml_export", str(ROOT / "ports" / "tyger-coreml" / "export.py")).load_module().EncWrap
        enc = EncWrap(ears.asr).eval()
        enc_path = OUT / "TygerEncoder.onnx"
        with torch.no_grad():
            ref = enc(torch.zeros(1, 801, 128))
        # dynamo=False: the dynamo/decompose path refuses the attention head-merge
        # reshape after transpose (non-contiguous view); the legacy TS exporter
        # traces the implicit copy fine and the graph is the same semantics.
        torch.onnx.export(enc, (torch.zeros(1, 801, 128),), str(enc_path),
                          input_names=["mel"], output_names=["hidden"], dynamo=False)
        print(f"wrote {enc_path} ({enc_path.stat().st_size / 1e6:.0f} MB, out {tuple(ref.shape)})")
        # a real-window oracle pair for the JS gate
        w = wavs["ch0"][: 8 * SR]
        b = ears.proc(w, sampling_rate=SR, return_tensors="pt")
        with torch.no_grad():
            h = enc(b["input_features"])
        (OUT / "enc-oracle.json").write_text(json.dumps({
            "mel": [round(float(v), 6) for v in b["input_features"][0].reshape(-1).numpy()],
            "mel_shape": list(b["input_features"].shape),
            "hidden": [round(float(v), 6) for v in h[0].reshape(-1).numpy()],
            "hidden_shape": list(h.shape),
        }))
        print("wrote enc-oracle.json")


if __name__ == "__main__":
    main()
