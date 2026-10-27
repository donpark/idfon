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
import json
import os
import shutil
import subprocess
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


def step_model(tt, prec):
    """The step graph for a rung (export and gate share one builder).

    Both rungs run the step fp32: at 53 MB it is 6% of the pair, and a fp16
    step (fuse in half, even with the GRU+heads exempt) buys ~26 MB while
    adding decision drift — measured 2026-10-27, the margin-cliff night.
    """
    return CE.StepWrap(tt).to(torch.float32).eval()


class EncMixed(torch.nn.Module):
    """The fp16 encoder rung's real form: fp16 bulk with the sensitive front
    exempt — stem + block 0 stay fp32. This is the only exemption config ever
    to pass the score budget (MLX int8-g16 evidence); a fp16 step-GRU exemption
    alone (2026-10-27) still killed every endpoint because fp16 hidden drift
    feeds the GRU garbage. Seam: casts at the block-0/block-1 boundary."""

    def __init__(self, asr):
        super().__init__()
        self.front = CE.EncFrontWrap(asr)  # shares enc; used for its mask/pos ctx
        self.enc = asr.encoder
        self.tail = torch.nn.ModuleList(list(asr.encoder.layers[1:15]))
        for layer in self.tail:
            layer.half()

    def forward(self, feats):
        e = self.enc
        x = e.subsampling(feats, None, padding_cache=None) * e.input_scale
        mask, allm, pos = self.front.ctx(x)
        x = e.layers[0](x, attention_mask=mask, all_masked_rows=allm,
                        position_embeddings=pos, past_key_values=None,
                        padding_cache=None, use_cache=False)
        x16 = x.to(torch.float16)
        pos16 = pos.to(torch.float16)
        for layer in self.tail:
            x16 = layer(x16, attention_mask=mask, all_masked_rows=allm,
                        position_embeddings=pos16, past_key_values=None,
                        padding_cache=None, use_cache=False)
        return x16.to(torch.float32)


def enc_model(asr, prec):
    """The encoder for a rung (export and gate share one builder)."""
    if prec == "float16":
        return EncMixed(asr.eval())
    return CE.EncWrap(asr).to(torch.float32).eval()


def export_encoder(asr, dtype, prec):
    enc = enc_model(asr, prec)
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
    step = step_model(tt, prec)
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


def compile_asset(path, arch):
    """AOT-compile `path` into `<name>.compiled.aimodel/<name>.<arch>.aimodelc`.
    Swift loaders prefer that container: loading a source .aimodel makes the
    runtime attempt an ANE compile per load — one mpsgraph workdir plus a
    feed to the daemon ANE caches that only a reboot flushes (the 2026-10-27
    disk incident; the attempt repeats forever because the ANE compile never
    succeeds for these graphs). ALWAYS pass --architecture: an unscoped compile
    builds every supported arch (22 for macOS, 9 for iOS) and each arch child
    copies the weights (~50 MB for the step, ~787 MB for the encoder). Ship
    macOS and iOS targets only; add archs as devices are confirmed (2026-10-27
    ruling). Skips the compile when the container already holds a fresh child
    for `arch` (its metadata sourceHash equals the source main.hash) — the
    same unchanged model never pays a recompile. Stale children (older exports)
    are removed; fresh children of other archs survive."""
    out = path.with_name(path.stem + ".compiled.aimodel")
    want = (path / "main.hash").read_bytes().hex().upper()

    def fresh(kid):
        try:
            have = json.loads((kid / "metadata.json").read_text()).get("sourceHash", "")
        except (OSError, ValueError):
            return False
        return have.upper() == want

    for old in sorted(out.glob("*.aimodelc")):
        if not fresh(old):
            shutil.rmtree(old, ignore_errors=True)
    kid = out / f"{path.stem}.{arch}.aimodelc"
    if kid.exists():
        print(f"[compile] {kid.name} up to date")
        return
    subprocess.run(["xcrun", "coreai-build", "compile", str(path),
                    "--output", str(out), "--platform", "macOS",
                    "--preferred-compute", "gpu", "--architecture", arch],
                   check=True)
    sz = sum(f.stat().st_size for f in out.rglob("*") if f.is_file()) / 1e6
    print(f"[compile] {kid.name} ({sz:.1f} MB)")


def host_arch():
    """This machine's arch token (e.g. h16s), read from an existing container.
    coreai-build has no host query, and an unscoped compile is never the
    fallback."""
    kids = sorted(OUT.glob("*.compiled.aimodel/*.aimodelc"))
    if not kids:
        raise SystemExit("no compiled container to read the arch token from — pass --arch")
    return kids[0].name.split(".")[-2]


def scratch_sweep(max_age_s=3600):
    """Age-gated sweep of runtime compile scratch (the apps' ScratchSweep does
    the same at launch): mpsgraph-* workdirs under
    $TMPDIR/com.apple.MetalPerformanceShadersGraph/ and *_main.ir dumps."""
    import glob
    import time
    tmp = os.environ.get("TMPDIR", "/tmp")
    now = time.time()
    targets = glob.glob(os.path.join(tmp, "com.apple.MetalPerformanceShadersGraph", "*"))
    targets += glob.glob(os.path.join(tmp, "*_main.ir"))
    n = 0
    for t in targets:
        if now - os.path.getmtime(t) <= max_age_s:
            continue
        if os.path.isdir(t):
            shutil.rmtree(t, ignore_errors=True)
        else:
            try:
                os.remove(t)
            except OSError:
                pass
        n += 1
    if n:
        print(f"[scratch] swept {n} stale compile-scratch items")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="both", choices=["both", "enc", "step", "gate"])
    ap.add_argument("--precision", default="float32", choices=["float32", "float16"])
    ap.add_argument("--arch", default=None,
                    help="arch token for the AOT compile (default: read from an "
                         "existing compiled container, e.g. h16s)")
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
            enc = enc_model(asr, args.precision)
            feeds, wants = [], []
            with torch.no_grad():
                for mel in mels:
                    x = torch.from_numpy(mel)
                    feeds.append({"mel_features": mel.astype(np.float32)})
                    wants.append({"encoder_hidden_state": enc(x).numpy().astype(np.float32)})
            ok = asyncio.run(gate(p, feeds, wants))
            print(f"[gate] encoder {'PASS' if ok else 'FAIL'}")
    if args.only in ("both", "step", "gate"):
        p = step_path or OUT / f"tyger_step_{args.precision}.aimodel"
        if p.exists():
            step = step_model(tt, args.precision)
            rng = np.random.default_rng(0)
            hu = rng.normal(size=(1, 1, 1024)).astype(np.float32)
            ha = rng.normal(size=(1, 1, 1024)).astype(np.float32)
            feed = {"hidden_user": hu, "hidden_agent": ha,
                    "energy_db": np.array([[-30.0]], np.float32),
                    "state_id": np.array([[0]], np.int32),
                    "gru_state": np.zeros((3, 1, 768), np.float32)}
            with torch.no_grad():
                out, st = step(torch.from_numpy(hu), torch.from_numpy(ha),
                               torch.tensor([[-30.0]]),
                               torch.tensor([[0]], dtype=torch.int32),
                               torch.zeros(3, 1, 768))
            wants = [{"decision_vector": out.numpy().astype(np.float32),
                      "gru_state_next": st.numpy().astype(np.float32)}]
            ok = asyncio.run(gate(p, [feed], wants))
            print(f"[gate] step {'PASS' if ok else 'FAIL'}")

    # AOT-compile what we exported so every Swift loader finds a fresh compiled
    # container (a stale one would silently run the previous export's weights).
    if args.only in ("both", "enc", "step"):
        arch = args.arch or host_arch()
        for p in (enc_path, step_path):
            if p is not None:
                compile_asset(p, arch)
    scratch_sweep()


if __name__ == "__main__":
    main()
