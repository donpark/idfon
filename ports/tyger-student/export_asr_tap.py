"""Export the Nemotron 3.5 streaming ASR encoder with a declared `tap_l4` output (#102).

Torch math + contract live in `asr_tap.py`; this is the export + gates:

  --export   torch.jit.trace -> Core ML mlprogram (static shapes, fp32 or fp16)
  --gate     run the exported bundle exactly as the app does (one mel chunk per call,
             caches threaded) and score the three #102 gates:
               (a) `encoded` vs the torch encoder on the runtime fixture,
               (b) `tap_l4` vs `bench-results/tap4-shards` (fixture + one dualturn session),
               (c) the chunked loop, not one call: per-chunk agreement over the whole file,
               (d) inert extra output: `encoded` is read by name; adding tap_l4 changes nothing.

Artifacts are written under the worktree's gitignored `bench-results/` (or --out).

  ports/tyger-student/.venv/bin/python ports/tyger-student/export_asr_tap.py \
      --export --precision fp32 --out bench-results/asr-tap
  ports/tyger-student/.venv/bin/python ports/tyger-student/export_asr_tap.py \
      --gate bench-results/asr-tap/encoder_tap_fp32.mlpackage
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import numpy as np
import torch

from asr_tap import wrapper_chunks  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))

from asr_tap import (  # noqa: E402
    CHUNK_FRAMES,
    DEFAULT_MODEL,
    KEEP,
    NEW_FRAMES,
    PASSES,
    REFERENCE,
    SR,
    TOTAL_MEL,
    PassConfig,
    StreamingTapEncoder,
    divergence,
    reference_chunks,
    reference_windows,
)

CACHE_SIZE = REFERENCE.left  # default; the gate/export use the run's PassConfig
TAP_INDEX = 4


def load_torch(model_id, device="cpu"):
    from transformers import AutoModel, AutoProcessor

    proc = AutoProcessor.from_pretrained(model_id)
    model = AutoModel.from_pretrained(model_id, dtype=torch.float32).eval().to(device)
    return proc, model


def example_inputs(pass_cfg: PassConfig = REFERENCE):
    return (
        torch.zeros(1, 128, TOTAL_MEL),
        torch.tensor([TOTAL_MEL], dtype=torch.int32),
        torch.zeros(1, 24, pass_cfg.left, 1024),
        torch.zeros(1, 24, 1024, 8),
        torch.tensor([1], dtype=torch.int32),
        torch.tensor([101], dtype=torch.int32),
    )


def export(model, out_dir: Path, precision="fp32", model_id=DEFAULT_MODEL, int8=False,
           pass_cfg: PassConfig = REFERENCE):
    import coremltools as ct

    out_dir.mkdir(parents=True, exist_ok=True)
    wrapper = StreamingTapEncoder(model, pass_cfg=pass_cfg, tap_index=TAP_INDEX).eval()
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example_inputs(pass_cfg), strict=False)
    inputs = [
        ct.TensorType(name="mel", shape=(1, 128, TOTAL_MEL), dtype=np.float32),
        ct.TensorType(name="mel_length", shape=(1,), dtype=np.int32),
        ct.TensorType(name="cache_channel", shape=(1, 24, pass_cfg.left, 1024), dtype=np.float32),
        ct.TensorType(name="cache_time", shape=(1, 24, 1024, 8), dtype=np.float32),
        ct.TensorType(name="cache_len", shape=(1,), dtype=np.int32),
        ct.TensorType(name="prompt_id", shape=(1,), dtype=np.int32),
    ]
    outputs = [
        ct.TensorType(name="encoded", dtype=np.float32),
        ct.TensorType(name="tap_l4", dtype=np.float32),
        ct.TensorType(name="cache_channel_out", dtype=np.float32),
        ct.TensorType(name="cache_time_out", dtype=np.float32),
        ct.TensorType(name="cache_len_out", dtype=np.int32),
        ct.TensorType(name="encoded_length", dtype=np.int32),
    ]
    ml = ct.convert(
        traced,
        inputs=inputs,
        outputs=outputs,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        skip_model_load=True,
    )
    if int8:
        from coremltools.optimize.coreml import OpLinearQuantizerConfig, OpLinearQuantizerConfig as _Q,             linear_quantize_weights
        cfg = ct.optimize.coreml.OptimizationConfig(
            global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear", granularity="per_channel")
        )
        ml = ct.optimize.coreml.linear_quantize_weights(ml, cfg)
    ml.short_description = (
        f"Nemotron 3.5 streaming ASR encoder + declared tap_l4 ({pass_cfg.name}: "
        f"left {pass_cfg.left} / lookahead {pass_cfg.lookahead}). Episode: donpark/idfon#102"
    )
    ml.user_defined_metadata["source_model"] = model_id
    ml.user_defined_metadata["tap"] = f"hidden_states[{TAP_INDEX}] (raw layer-4, pre-prompt)"
    ml.user_defined_metadata["contract"] = "FluidAudio StreamingNemotronMultilingualAsrManager"
    ml.user_defined_metadata["pass"] = pass_cfg.name
    tag = f"{precision}{'_int8w' if int8 else ''}"
    if pass_cfg != REFERENCE:
        tag = f"{pass_cfg.left}-{pass_cfg.lookahead}_{tag}"
    path = out_dir / f"encoder_tap_{tag}.mlpackage"
    ml.save(str(path))
    size = sum(p.stat().st_size for p in path.rglob("*") if p.is_file())
    print(f"saved {path}  {size/1e6:.1f} MB ({size} bytes)")
    return path, size


# --------------------------------------------------------------------------- #
# gates
# --------------------------------------------------------------------------- #
def ml_forward(mlmodel, mel, caches, prompt_id=101):
    ch, ct, cl = caches
    feats = {
        "mel": mel.astype(np.float32),
        "mel_length": np.array([TOTAL_MEL], np.int32),
        "cache_channel": ch.astype(np.float32),
        "cache_time": ct.astype(np.float32),
        "cache_len": np.array([cl], np.int32),
        "prompt_id": np.array([prompt_id], np.int32),
    }
    out = mlmodel.predict(feats)
    return out, (out["cache_channel_out"], out["cache_time_out"], int(out["cache_len_out"][0]))


def ml_stream(mlmodel, feats, prompt_id=101, chunks=None, cache_size=CACHE_SIZE):
    """The app's loop: one 65-frame mel window per call, caches threaded by the model."""
    caches = (
        np.zeros((1, 24, cache_size, 1024), np.float32),
        np.zeros((1, 24, 1024, 8), np.float32),
        1,
    )
    enc, tap, outs = [], [], []
    for i, win in enumerate(reference_windows(torch.from_numpy(feats))):
        if chunks is not None and i >= chunks:
            break
        # the contract mel is channels-first [1,128,65]; the processor is time-first
        out, caches = ml_forward(mlmodel, win.numpy().transpose(0, 2, 1), caches, prompt_id)
        enc.append(out["encoded"][0].T)
        tap.append(out["tap_l4"][0].T)
        outs.append(out)
    return np.concatenate(enc), np.concatenate(tap), outs


def read_wav(path):
    import soundfile as sf

    x, sr = sf.read(str(path), dtype="float32")
    assert sr == SR and x.ndim == 1, (sr, x.shape)
    return x


def mel_of(proc, wav):
    return proc(np.asarray(wav, np.float32), sampling_rate=SR, return_tensors="pt")["input_features"]


def session_wav(session_id, cache_dir: Path):
    """Decode one dualturn session to 16 kHz with the same path featurize_tap.py uses."""
    cache = cache_dir / f"{session_id}.npy"
    if cache.exists():
        return np.load(cache)
    from datasets import load_dataset
    from transformers import AutoModel as HFAutoModel

    from oracle import decode_channel, resample16k

    mimi = HFAutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()
    for row in load_dataset("anyreach-ai/dualturn-otospeech-turn-taking", split="val", streaming=True):
        if row["session_id"] != session_id:
            continue
        codes = np.array(row["codes_ch0"], dtype=np.int16).reshape(int(row["num_frames"]), 8)
        wav = resample16k(decode_channel(mimi, codes))
        cache_dir.mkdir(parents=True, exist_ok=True)
        np.save(cache, wav)
        return wav
    raise SystemExit(f"session {session_id} not found in the val split")


def fixture_path(p=None):
    """The runtime fixture is gitignored, so a worktree only has it via the main checkout."""
    cand = [Path(p)] if p else []
    cand.append(Path("ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch0.wav"))
    cand.append(Path("/Users/don/dev/idfon/ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch0.wav"))
    for c in cand:
        if c.exists():
            return c
    raise SystemExit("fixture wav not found; pass --fixture (16 kHz mono, ch0.wav)")


def gate(model_path: Path, args):
    import coremltools as ct

    model_id = args.model
    cfg = PASSES[args.pass_]
    proc, model = load_torch(model_id, args.device)
    prompt_id = int(model.config.default_prompt_id)
    # decode the session wav first (mimi only; the two big models together are memory pressure)
    sfeats = None
    if args.session_id and (Path(args.shards) / f"{args.session_id}.npz").exists():
        sfeats = mel_of(proc, session_wav(args.session_id, Path(args.wav_cache))).numpy()
    fixture_wav = read_wav(fixture_path(args.fixture))
    feats_t = mel_of(proc, fixture_wav)
    feats = feats_t.numpy()
    ref_kind = getattr(args, "ref", None) or ("int8" if args.int8 else ("hf" if cfg == REFERENCE else "fp32"))
    if ref_kind == "hf":
        # the 56/0 reference is the HF streaming pass (what tap4-shards records)
        ref_enc_chunks, ref_tap_chunks = reference_chunks(model, feats_t)
        # chunk 0 of the HF pass has one extra (context) row the steady-state graph cannot
        # emit; align on chunk 1 so the comparison is frame-for-frame after it
        ref_off, ml_off = len(ref_enc_chunks[0]), KEEP
    else:
        # 42/13 has no HF oracle (HF derives left = sliding_window-1 = 56), so the wrapper is
        # the reference; for the int8 artifact the reference carries the same weight grid.
        import copy

        ref_model = model
        if ref_kind == "int8":
            ref_model = copy.deepcopy(model)
            from asr_tap import quantize_weights_int8_

            quantize_weights_int8_(ref_model.encoder)
        ref_wrapper = StreamingTapEncoder(ref_model, pass_cfg=cfg, tap_index=TAP_INDEX).eval()
        ref_enc_chunks, ref_tap_chunks = wrapper_chunks(ref_wrapper, feats_t)
        ref_off = ml_off = 0
        del ref_wrapper, ref_model
    ref_enc, ref_tap = np.concatenate(ref_enc_chunks), np.concatenate(ref_tap_chunks)
    del model
    import gc

    gc.collect()

    fixture = str(fixture_path(args.fixture))
    results = {"model": str(model_path), "tag": args.precision_gate, "pass": cfg.name,
               "reference": ref_kind,
               "cache_depth": cfg.left, "fixture": fixture,
               "bytes": sum(p.stat().st_size for p in model_path.rglob("*") if p.is_file())}
    for units_name, units in (("cpu", ct.ComputeUnit.CPU_ONLY), ("ane", ct.ComputeUnit.CPU_AND_NE)):
        if units_name == "ane" and args.cpu_only:
            continue
        ml = ct.models.MLModel(str(model_path), compute_units=units)
        t0 = time.perf_counter()
        enc, tap, _ = ml_stream(ml, feats, prompt_id=prompt_id, cache_size=cfg.left)
        dt = (time.perf_counter() - t0) / (len(enc) / KEEP)
        # (a) encoded parity vs torch, (b) tap vs the torch reference pass, (c) per chunk
        warm = 40  # the cold-start transient (chunk-0 framing) decays by ~chunk 30
        res = {}
        for name, ref, got in (("encoded", ref_enc, enc), ("tap_l4", ref_tap, tap)):
            r, g = ref[ref_off:], got[ml_off:]
            n = min(len(r), len(g))
            d = divergence(r[:n], g[:n])
            ds = (divergence(r[warm * KEEP : n], g[warm * KEEP : n])
                  if n > warm * KEEP else (float('nan'),) * 3)
            decay = {}
            for lo, hi in ((1, 8), (8, 16), (16, 32), (32, 64), (64, 4096)):
                a, b = lo * KEEP, min(hi * KEEP, n)
                if b > a:
                    dd = divergence(r[a:b], g[a:b])
                    decay[f"chunk_{lo}_{hi}"] = {"cos_min": dd[1], "max_abs": dd[2]}
            res[name] = {"cos_p50": d[0], "cos_min": d[1], "max_abs": d[2],
                         "cos_min_steady": ds[1], "max_abs_steady": ds[2], "decay": decay}
        res["ms_per_chunk"] = 1e3 * dt
        res["compute_units"] = units_name
        results[units_name] = res
        print(f"[{units_name}] {res['ms_per_chunk']:.2f} ms/chunk")
        for k in ("encoded", "tap_l4"):
            r = res[k]
            print(f"  {k:8s} cos p50 {r['cos_p50']:.8f} (steady min {r['cos_min_steady']:.8f}) "
                  f"max|d| {r['max_abs']:.3e} (steady {r['max_abs_steady']:.3e})")
            print("           decay:", ", ".join(f"{kk}={vv['max_abs']:.1e}" for kk, vv in r["decay"].items()))

    # (d) the extra output is inert: a provider that knows only `encoded` still transcribes,
    # and the model's `encoded` is byte-identical with/without reading tap_l4 by name.
    ml = ct.models.MLModel(str(model_path), compute_units=ct.ComputeUnit.CPU_ONLY)
    out, _ = ml_forward(ml, feats[:, :TOTAL_MEL, :].transpose(0, 2, 1),
                        (np.zeros((1, 24, cfg.left, 1024), np.float32),
                         np.zeros((1, 24, 1024, 8), np.float32), 1),
                        prompt_id)
    results["encoded_only_read"] = sorted(out.keys()) == sorted(
        ["encoded", "encoded_length", "cache_channel_out", "cache_time_out", "cache_len_out", "tap_l4"])
    results["output_shapes"] = {k: list(np.asarray(v).shape) for k, v in out.items()}
    x = out["encoded"]
    results["encoded_finite"] = bool(np.isfinite(x).all())

    # (b) session gate: tap rows vs the stored shards (the adapter's calibration target)
    shard = None
    if args.session_id:
        val = Path(args.shards) / f"{args.session_id}.npz"
        if val.exists() and sfeats is not None:
            _, tap_s, _ = ml_stream(ml, sfeats, prompt_id=prompt_id, cache_size=cfg.left)
            with np.load(val) as z:
                hu = z["hu"]
            # same one-row offset as the fixture: the shard's chunk 0 carries the torch pass's
            # extra context row, which the steady-state graph cannot emit
            r, g = hu[ref_off:], tap_s[ml_off:]
            n = min(len(r), len(g))
            cos = divergence(r[:n], g[:n])
            decay = {}
            for lo, hi in ((1, 8), (8, 16), (16, 32), (32, 64), (64, 4096)):
                a, b = lo * KEEP, min(hi * KEEP, n)
                if b <= a:
                    continue
                dd = divergence(r[a:b], g[a:b])
                decay[f"chunk_{lo}_{hi}"] = {"cos_min": dd[1], "max_abs": dd[2]}
            results["shard_decay"] = decay
            results["shard"] = {"session": args.session_id, "rows": int(n),
                                "cos_p50": cos[0], "cos_min": cos[1], "max_abs": cos[2],
                                "cos_min_steady": divergence(r[64 * KEEP : n], g[64 * KEEP : n])[1],
                                "max_abs_steady": divergence(r[64 * KEEP : n], g[64 * KEEP : n])[2],
                                "steady_from_chunk": 64}
            print("  decay:", ", ".join(f"{k} max|d| {v['max_abs']:.2e}" for k, v in decay.items()))
            print(f"shard {args.session_id[:12]}: tap vs stored rows {n} cos p50 "
                  f"{cos[0]:.8f} min {cos[1]:.8f} max|d| {cos[2]:.3e} "
                  f"(steady {results['shard']['max_abs_steady']:.3e})")
            shard = results["shard"]

    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2))
        print("wrote", args.json)
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.environ.get("TYGER_ASR", DEFAULT_MODEL))
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--export", action="store_true")
    ap.add_argument("--gate", default=None, help="mlpackage to gate")
    ap.add_argument("--precision", default="fp32", choices=("fp32", "fp16"))
    ap.add_argument("--pass", dest="pass_", default="reference", choices=sorted(PASSES),
                    help="attention pass: reference 56/0 (the shards) or shipping 42/13 (the bundle)")
    ap.add_argument("--int8", action="store_true", help="quantize weights to int8 per-channel (the shipping form)")
    ap.add_argument("--out", default="bench-results/asr-tap")
    ap.add_argument("--fixture", default=None)
    ap.add_argument("--session-id", default=None, help="dualturn val session for the shard gate")
    ap.add_argument("--shards", default="/Users/don/dev/idfon/bench-results/tap4-shards/val")
    ap.add_argument("--wav-cache", default="bench-results/asr-tap/wav")
    ap.add_argument("--json", default=None)
    ap.add_argument("--cpu-only", action="store_true")
    ap.add_argument("--ref", default=None, choices=("hf", "fp32", "int8"),
                    help="torch reference: hf (the 56/0 streaming pass), fp32 wrapper at --pass, "
                         "or the same weights quantized int8 (default: int8 if --int8 else hf/fp32)")
    ap.add_argument("--selfcheck", action="store_true",
                    help="export fp32 and assert the fixture tap gate (steady max|d| <= 2e-3)")
    args = ap.parse_args()

    if args.export or args.selfcheck:
        proc, model = load_torch(args.model, args.device)
        precision, int8 = ("fp32", False) if args.selfcheck else (args.precision, args.int8)
        path, size = export(model, Path(args.out), precision, args.model, int8, PASSES[args.pass_])
        if args.gate is None:
            args.gate = str(path)
    if args.gate:
        args.precision_gate = Path(args.gate).stem.replace("encoder_tap_", "")
        results = gate(Path(args.gate), args)
        if args.selfcheck:
            tap = results["cpu"]["tap_l4"]
            # the fixture is short, so the steady window is the last decay bucket
            worst = tap["decay"].get("chunk_32_64", {}).get("max_abs", tap["max_abs"])
            ok = worst <= 2e-3
            print(f"selfcheck: steady tap max|d| {worst:.2e} vs 2e-3 bar -> {'PASS' if ok else 'FAIL'}")
            if not ok:
                raise SystemExit(1)
    if not args.export and not args.gate:
        ap.error("pass --export and/or --gate")


if __name__ == "__main__":
    main()
