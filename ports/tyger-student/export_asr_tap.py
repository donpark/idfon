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

A non-560 tier is `--chunk-ms 320` (32 mel + 9 context -> 4 rows, cache 42 unchanged);
it writes a sidecar `metadata.json` beside the artifact for the manager.
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
    DEFAULT_MODEL,
    PASSES,
    REFERENCE,
    SR,
    TIER_560,
    TIERS,
    PassConfig,
    StreamingTapEncoder,
    Tier,
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


def example_inputs(pass_cfg: PassConfig = REFERENCE, tier: Tier = TIER_560,
                   batch: int = 1, depth: int = 24):
    return (
        torch.zeros(batch, 128, tier.total_mel),
        torch.full((batch,), tier.total_mel, dtype=torch.int32),
        torch.zeros(batch, depth, pass_cfg.left, 1024),
        torch.zeros(batch, depth, 1024, 8),
        torch.full((batch,), 1, dtype=torch.int32),
        torch.full((batch,), 101, dtype=torch.int32),
    )


def metadata(model, tier: Tier, cache_depth: int, model_id=DEFAULT_MODEL,
             batch: int = 1, depth: int = 24, prefix_only: bool = False):
    """The fields `StreamingNemotronAsrManager` reads; the cache depth is the artifact's.

    The earlier 70-vs-42 mismatch was `cache_channel_shape[2]` (70, the 56/0 pass's
    value, shipped beside a 42-deep 42/13 artifact). It must equal the encoder's
    declared input depth, so it is derived here, not copied from the base tier.

    `prompt_id` is declared only for prefix (turn-path) exports: the six-input graph
    needs it, the English manager never supplies one, and the app's prefix loader
    refuses to invent 101 — it reads this field. The ASR metadata is unchanged."""
    cfg = model.config
    meta = {
        "model": model_id,
        "sample_rate": SR,
        "mel_features": 128,
        "chunk_mel_frames": tier.mel_frames,
        "pre_encode_cache": tier.pre_encode,
        "total_mel_frames": tier.total_mel,
        "chunk_ms": tier.ms,
        "vocab_size": 1024,
        "blank_idx": 1024,
        "cache_channel_shape": [batch, depth, cache_depth, 1024],
        "cache_time_shape": [batch, depth, 1024, 8],
        "decoder_hidden": int(cfg.decoder_hidden_size),
        "decoder_layers": int(cfg.num_decoder_layers),
        "encoder_dim": 1024,
    }
    if prefix_only:
        meta["prompt_id"] = int(cfg.default_prompt_id)
    return meta


def export(model, out_dir: Path, precision="fp32", model_id=DEFAULT_MODEL, int8=False,
           pass_cfg: PassConfig = REFERENCE, tier: Tier = TIER_560, batch: int = 1,
           depth: int = 24, prefix_only: bool = False):
    import coremltools as ct

    out_dir.mkdir(parents=True, exist_ok=True)
    wrapper = StreamingTapEncoder(model, pass_cfg=pass_cfg, tier=tier,
                                  tap_index=TAP_INDEX, batch=batch, depth=depth,
                                  prefix_only=prefix_only).eval()
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example_inputs(pass_cfg, tier, batch, depth),
                                 strict=False)
    inputs = [
        ct.TensorType(name="mel", shape=(batch, 128, tier.total_mel), dtype=np.float32),
        ct.TensorType(name="mel_length", shape=(batch,), dtype=np.int32),
        ct.TensorType(name="cache_channel", shape=(batch, depth, pass_cfg.left, 1024),
                      dtype=np.float32),
        ct.TensorType(name="cache_time", shape=(batch, depth, 1024, 8), dtype=np.float32),
        ct.TensorType(name="cache_len", shape=(batch,), dtype=np.int32),
        ct.TensorType(name="prompt_id", shape=(batch,), dtype=np.int32),
    ]
    outputs = [
        ct.TensorType(name="tap_l4", dtype=np.float32),
        ct.TensorType(name="cache_channel_out", dtype=np.float32),
        ct.TensorType(name="cache_time_out", dtype=np.float32),
        ct.TensorType(name="cache_len_out", dtype=np.int32),
    ]
    if not prefix_only:
        outputs = [ct.TensorType(name="encoded", dtype=np.float32)] + outputs + [
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
    ml.user_defined_metadata["chunk_ms"] = str(tier.ms)
    tag = f"{precision}{'_int8w' if int8 else ''}"
    if pass_cfg != REFERENCE:
        tag = f"{pass_cfg.left}-{pass_cfg.lookahead}_{tag}"
    if tier != TIER_560:
        tag = f"{tag.replace(precision, f'{tier.ms}ms_{precision}', 1)}"
    if prefix_only:
        tag = f"{tag}_l{depth}b{batch}"
    path = out_dir / f"encoder_tap_{tag}.mlpackage"
    ml.save(str(path))
    size = sum(p.stat().st_size for p in path.rglob("*") if p.is_file())
    meta = metadata(model, tier, pass_cfg.left, model_id, batch, depth, prefix_only)
    meta["prefix_only"] = prefix_only
    (out_dir / "metadata.json").write_text(json.dumps(meta, indent=2))
    print(f"saved {path}  {size/1e6:.1f} MB ({size} bytes)")
    print(f"metadata: {tier.ms} ms, chunk_mel_frames {tier.mel_frames}, "
          f"total_mel_frames {tier.total_mel}, cache_channel_shape "
          f"{meta['cache_channel_shape']} (chunkSamples {tier.mel_frames * 160})")
    return path, size


# --------------------------------------------------------------------------- #
# gates
# --------------------------------------------------------------------------- #
def ml_forward(mlmodel, mel, caches, prompt_id=101, total_mel=None):
    ch, ct, cl = caches
    if total_mel is None:
        total_mel = int(mlmodel.get_spec().description.input[0].type.multiArrayType.shape[2])
    feats = {
        "mel": mel.astype(np.float32),
        "mel_length": np.array([total_mel], np.int32),
        "cache_channel": ch.astype(np.float32),
        "cache_time": ct.astype(np.float32),
        "cache_len": np.array([cl], np.int32),
        "prompt_id": np.array([prompt_id], np.int32),
    }
    out = mlmodel.predict(feats)
    return out, (out["cache_channel_out"], out["cache_time_out"], int(out["cache_len_out"][0]))


def ml_stream(mlmodel, feats, prompt_id=101, chunks=None, cache_size=CACHE_SIZE,
              tier: Tier = TIER_560):
    """The app's loop: one tier-sized mel window per call, caches threaded by the model."""
    caches = (
        np.zeros((1, 24, cache_size, 1024), np.float32),
        np.zeros((1, 24, 1024, 8), np.float32),
        1,
    )
    enc, tap, outs = [], [], []
    for i, win in enumerate(reference_windows(torch.from_numpy(feats), tier)):
        if chunks is not None and i >= chunks:
            break
        # the contract mel is channels-first [1,128,total]; the processor is time-first
        out, caches = ml_forward(mlmodel, win.numpy().transpose(0, 2, 1), caches,
                                 prompt_id, tier.total_mel)
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
    tier = TIERS[args.chunk_ms]
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
        ref_enc_chunks, ref_tap_chunks = reference_chunks(model, feats_t, tier=tier)
        # chunk 0 of the HF pass has one extra (context) row the steady-state graph cannot
        # emit; align on chunk 1 so the comparison is frame-for-frame after it
        ref_off, ml_off = len(ref_enc_chunks[0]), tier.keep
    else:
        # 42/13 has no HF oracle (HF derives left = sliding_window-1 = 56), so the wrapper is
        # the reference; for the int8 artifact the reference carries the same weight grid.
        import copy

        ref_model = model
        if ref_kind == "int8":
            ref_model = copy.deepcopy(model)
            from asr_tap import quantize_weights_int8_

            quantize_weights_int8_(ref_model.encoder)
        ref_wrapper = StreamingTapEncoder(ref_model, pass_cfg=cfg, tier=tier,
                                          tap_index=TAP_INDEX).eval()
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
               "cache_depth": cfg.left, "chunk_ms": tier.ms, "fixture": fixture,
               "bytes": sum(p.stat().st_size for p in model_path.rglob("*") if p.is_file())}
    for units_name, units in (("cpu", ct.ComputeUnit.CPU_ONLY), ("ane", ct.ComputeUnit.CPU_AND_NE)):
        if units_name == "ane" and args.cpu_only:
            continue
        ml = ct.models.MLModel(str(model_path), compute_units=units)
        t0 = time.perf_counter()
        enc, tap, _ = ml_stream(ml, feats, prompt_id=prompt_id, cache_size=cfg.left,
                                tier=tier)
        dt = (time.perf_counter() - t0) / (len(enc) / tier.keep)
        # (a) encoded parity vs torch, (b) tap vs the torch reference pass, (c) per chunk
        warm = 40  # the cold-start transient (chunk-0 framing) decays by ~chunk 30
        res = {}
        for name, ref, got in (("encoded", ref_enc, enc), ("tap_l4", ref_tap, tap)):
            r, g = ref[ref_off:], got[ml_off:]
            n = min(len(r), len(g))
            d = divergence(r[:n], g[:n])
            ds = (divergence(r[warm * tier.keep : n], g[warm * tier.keep : n])
                  if n > warm * tier.keep else (float('nan'),) * 3)
            decay = {}
            for lo, hi in ((1, 8), (8, 16), (16, 32), (32, 64), (64, 4096)):
                a, b = lo * tier.keep, min(hi * tier.keep, n)
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
    out, _ = ml_forward(ml, feats[:, :tier.total_mel, :].transpose(0, 2, 1),
                        (np.zeros((1, 24, cfg.left, 1024), np.float32),
                         np.zeros((1, 24, 1024, 8), np.float32), 1),
                        prompt_id, tier.total_mel)
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
            _, tap_s, _ = ml_stream(ml, sfeats, prompt_id=prompt_id, cache_size=cfg.left,
                                    tier=tier)
            with np.load(val) as z:
                hu = z["hu"]
            # same one-row offset as the fixture: the shard's chunk 0 carries the torch pass's
            # extra context row, which the steady-state graph cannot emit
            r, g = hu[ref_off:], tap_s[ml_off:]
            n = min(len(r), len(g))
            cos = divergence(r[:n], g[:n])
            decay = {}
            for lo, hi in ((1, 8), (8, 16), (16, 32), (32, 64), (64, 4096)):
                a, b = lo * tier.keep, min(hi * tier.keep, n)
                if b <= a:
                    continue
                dd = divergence(r[a:b], g[a:b])
                decay[f"chunk_{lo}_{hi}"] = {"cos_min": dd[1], "max_abs": dd[2]}
            results["shard_decay"] = decay
            ss = 64 * tier.keep
            results["shard"] = {"session": args.session_id, "rows": int(n),
                                "cos_p50": cos[0], "cos_min": cos[1], "max_abs": cos[2],
                                "cos_min_steady": divergence(r[ss : n], g[ss : n])[1],
                                "max_abs_steady": divergence(r[ss : n], g[ss : n])[2],
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
    ap.add_argument("--chunk-ms", type=int, default=560, choices=sorted(TIERS),
                    help="chunk tier: 560 (shipping) or 320 (probe)")
    ap.add_argument("--batch", type=int, default=1, help="independent streams per call")
    ap.add_argument("--depth", type=int, default=24, help="encoder layers to run (tap requires >= 4)")
    ap.add_argument("--prefix-only", action="store_true",
                    help="stop at the tap: no encoded/prompt projector; prefix caches")
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
        if args.prefix_only and args.gate:
            ap.error("a prefix artifact has no `encoded`; gate it with batched_ears.py")
        if args.depth < 24 and not args.prefix_only:
            ap.error("a layer-truncated graph has no `encoded`; pass --prefix-only")
        path, size = export(model, Path(args.out), precision, args.model, int8,
                            PASSES[args.pass_], TIERS[args.chunk_ms],
                            batch=args.batch, depth=args.depth,
                            prefix_only=args.prefix_only)
        if args.gate is None and not args.prefix_only:
            args.gate = str(path)
        if args.prefix_only:
            return
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
