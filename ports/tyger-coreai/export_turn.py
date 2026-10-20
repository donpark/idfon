"""Export the tyger decision path to Core AI (.aimodel) — the OS 27+ voice tier
(user ruling 2026-10-19; docs/voice-tyger-ondevice.md).

Two graphs, same contract as ports/tyger-coreml/export.py so the acceptance
stack diffs each level:

  encoder  mel window (1, T, 128) -> hidden L15 (1, ?, 1024)   [dynamic T = the
             startup contract: true growing windows, mel lengths 8k-7]
  step     hidden_user/hidden_agent (1,1,1024) + energy_db (1,1) + state_id (1,1)
           + gru_state (3,1,768) -> decision_vector (1,1,8) + gru_state_next

I/O names are long and descriptive on purpose: the on-device AOT loader rejects
bundles with terse input names (coreai-model-zoo `conversion/nemotron_asr`).

The wrappers (EncWrap/StepWrap) are reused from ports/tyger-coreml/export.py.
Gates run on this Mac through coreai.runtime (cpu + gpu); the device AOT step is
`xcrun coreai-build compile`.

Usage:  TYGER_S2S=... .venv/bin/python export_turn.py [--only enc|step|gate]
Output: bench-results/coreai/*.aimodel (gitignored)
"""
import argparse
import asyncio
import importlib.machinery
import os
import shutil
import sys
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE", os.path.expanduser(
    "~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6"))
OUT = HERE.parents[1] / "bench-results" / "coreai"
WAV = HERE.parents[1] / "ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch0.wav"

# the wrappers live in the Core ML export (same cut, same semantics)
sys.path.insert(0, S2S)
CE = importlib.machinery.SourceFileLoader(
    "ce", str(HERE.parent / "tyger-coreml" / "export.py")).load_module()

import coreai.runtime as rt  # noqa: E402
from coreai_models.export.macos import export_to_coreai  # noqa: E402


class EncIO32(torch.nn.Module):
    """fp16 compute behind fp32 I/O — the fp16 rung's boundary ergonomics (the
    app and the gates keep feeding fp32, like the CoreML fp16 pair)."""

    def __init__(self, inner):
        super().__init__()
        self.inner = inner

    def forward(self, feats):
        return self.inner(feats.to(torch.float16)).to(torch.float32)


class StepIO32(torch.nn.Module):
    def __init__(self, inner):
        super().__init__()
        self.inner = inner

    def forward(self, hu, ha, act_db, prev_state, state):
        out, nxt = self.inner(hu.to(torch.float16), ha.to(torch.float16),
                              act_db.to(torch.float16), prev_state, state.to(torch.float16))
        return out.to(torch.float32), nxt.to(torch.float32)


def export_encoder(asr, dtype, prec):
    enc = CE.EncWrap(asr).to(dtype).eval()
    if prec == "float16":
        enc = EncIO32(enc)  # fp16 compute behind fp32 I/O
    ex = {"feats": torch.zeros(1, 33, 128)}
    # mel lengths are 8k-7 (33, 41, ..., 801): the derived dim the startup
    # contract needs (same expression as the Core ML enc-dyn export)
    mel = torch.export.Dim("_mel", min=5, max=101)
    dyn = {"feats": {1: 8 * mel - 7}}
    print("[export] encoder (dynamic mel 8k-7) -> Core AI ...", flush=True)
    prog = export_to_coreai(
        enc, ex, dynamic_shapes=dyn,
        input_names=("mel_features",), output_names=("encoder_hidden_state",))
    path = OUT / f"tyger_encoder_{prec}.aimodel"
    shutil.rmtree(path, ignore_errors=True)
    prog.save_asset(path, rt.AIModelAssetMetadata())
    return path


def export_step(tt, dtype, prec):
    step = CE.StepWrap(tt).to(dtype).eval()
    if prec == "float16":
        step = StepIO32(step)  # fp16 compute behind fp32 I/O
    ex = {
        "hu": torch.zeros(1, 1, 1024),
        "ha": torch.zeros(1, 1, 1024),
        "act_db": torch.zeros(1, 1),
        "prev_state": torch.zeros(1, 1, dtype=torch.int32),
        "state": torch.zeros(3, 1, 768),
    }
    print("[export] step -> Core AI ...", flush=True)
    prog = export_to_coreai(
        step, ex, dynamic_shapes=None,
        input_names=("hidden_user", "hidden_agent", "energy_db", "state_id", "gru_state"),
        output_names=("decision_vector", "gru_state_next"))
    path = OUT / f"tyger_step_{prec}.aimodel"
    shutil.rmtree(path, ignore_errors=True)
    prog.save_asset(path, rt.AIModelAssetMetadata())
    return path


def fixture_inputs(asr, proc, dtype):
    """Real gate inputs: one steady-state window + one startup window of the
    fixture conversation, and one step frame taken from the encoder's output."""
    import soundfile as sf
    wav = sf.read(WAV, dtype="float32")[0]
    mels = []
    for n in (8 * 16000, 3 * 16000):
        feats = proc(wav[:n], sampling_rate=16000, return_tensors="pt")["input_features"]
        mels.append(feats.numpy().astype(np.float32))
    return mels


async def gate(path, feeds, wants, units=("gpu", "cpu")):
    ok_all = True
    for unit in units:
        opts = (rt.SpecializationOptions.cpu_only() if unit == "cpu"
                else rt.SpecializationOptions.from_preferred_compute_unit_kind(
                    getattr(rt.ComputeUnitKind, unit)()))
        try:
            m = await rt.AIModel.load(str(path), opts)
        except Exception as e:  # e.g. the CPU specialization fails on big graphs
            print(f"[gate {unit}] SKIP (load: {str(e)[:60]})", flush=True)
            continue
        fn = m.load_function("main")
        for i, (feed, want) in enumerate(zip(feeds, wants)):
            res = await fn({k: rt.NDArray(v) for k, v in feed.items()})
            for name, w in want.items():
                got = res[name].numpy().astype(np.float32)
                d = float(np.abs(got - w).max())
                cos = float(np.dot(got.ravel(), w.ravel()) /
                            (np.linalg.norm(got) * np.linalg.norm(w) + 1e-9))
                ok = d < (5e-2 if "decision" in name else 1e-3) or cos > 0.9999
                ok_all = ok_all and ok
                print(f"[gate {unit} #{i}] {name}: max|Δ| {d:.6f} cos {cos:.6f} "
                      f"-> {'PASS' if ok else 'FAIL'}", flush=True)
    return ok_all


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="both", choices=["both", "enc", "step", "gate"])
    ap.add_argument("--precision", default="float32", choices=["float32", "float16"])
    args = ap.parse_args()

    import torch  # noqa
    asr, proc, tt, _cfg = CE.bundle_load(Path(BUNDLE))
    asr.eval()
    tt.eval()
    dtype = torch.float16 if args.precision == "float16" else torch.float32
    OUT.mkdir(parents=True, exist_ok=True)

    enc_path = step_path = None
    if args.only in ("both", "enc"):
        enc_path = export_encoder(asr, dtype, args.precision)
        sz = sum(f.stat().st_size for f in enc_path.rglob("*") if f.is_file()) / 1e6
        print(f"[save] {enc_path} ({sz:.1f} MB)")
    if args.only in ("both", "step"):
        step_path = export_step(tt, dtype, args.precision)
        sz = sum(f.stat().st_size for f in step_path.rglob("*") if f.is_file()) / 1e6
        print(f"[save] {step_path} ({sz:.1f} MB)")

    # gates: engine vs the same torch wrappers, on real fixture audio
    mels = fixture_inputs(asr, proc, dtype)
    if args.only in ("both", "enc", "gate"):
        p = enc_path or OUT / f"tyger_encoder_{args.precision}.aimodel"
        if p.exists():
            enc = CE.EncWrap(asr).to(dtype).eval()
            feeds, wants = [], []
            with torch.no_grad():
                for mel in mels:
                    x = torch.from_numpy(mel).to(dtype)
                    feeds.append({"mel_features": mel.astype(np.float32)})
                    wants.append({"encoder_hidden_state": enc(x).numpy().astype(np.float32)})
            ok = asyncio.run(gate(p, feeds, wants))
            print(f"[gate] encoder {'PASS' if ok else 'FAIL'}")
    if args.only in ("both", "step", "gate"):
        p = step_path or OUT / f"tyger_step_{args.precision}.aimodel"
        if p.exists():
            step = CE.StepWrap(tt).to(dtype).eval()
            rng = np.random.default_rng(0)
            hu = rng.normal(size=(1, 1, 1024)).astype(np.float32)
            ha = rng.normal(size=(1, 1, 1024)).astype(np.float32)
            feed = {"hidden_user": hu, "hidden_agent": ha,
                    "energy_db": np.array([[-30.0]], np.float32),
                    "state_id": np.array([[0]], np.int32),
                    "gru_state": np.zeros((3, 1, 768), np.float32)}
            with torch.no_grad():
                out, st = step(torch.from_numpy(hu).to(dtype), torch.from_numpy(ha).to(dtype),
                               torch.tensor([[-30.0]], dtype=dtype),
                               torch.tensor([[0]], dtype=torch.int32),
                               torch.zeros(3, 1, 768, dtype=dtype))
            wants = [{"decision_vector": out.numpy().astype(np.float32),
                      "gru_state_next": st.numpy().astype(np.float32)}]
            ok = asyncio.run(gate(p, [feed], wants))
            print(f"[gate] step {'PASS' if ok else 'FAIL'}")


if __name__ == "__main__":
    main()
