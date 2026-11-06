#!/usr/bin/env python3
"""`encoded` parity gate for the ASR encoder export (#132).

The 42/13 export was gated on `tap_l4` (layer 4) and on `encoded` only at the
reference 56/0 pass. This gate asks the missing question at the artifact's own
pass: does the 24-layer, prompt-projected tensor the decoder reads match the
torch graph, chunk by chunk, with the same caches?

Reference arms (`--reference`):
  fp32        the torch wrapper at the same pass/tier (the graph's own float math)
  int8-enc    the wrapper with int8-simulated encoder weights only, which is what
              `export_asr_tap.py --ref int8` did when it recorded cos_min 0.073
  int8-all    the wrapper with the same weight grid on the prompt projector too
              (the Core ML int8 pass quantizes the whole program, not the encoder)

Reported per arm and tensor: cosine p50/p05/min, max|d| over all rows, the same
per chunk bucket, the worst rows with their norms, and a +-1 row-shift scan (a
framing/row-origin error shows up as "cos is higher one row over"). Caches are
compared per layer, so a divergence can be attributed to the stack above the tap
or to the prompt projector rather than to "the export".

Usage:
  $PY ports/tyger-student/encoded_gate.py \
      --artifact bench-results/asr-encoded-parity/encoder_tap_42-13_fp32.mlpackage \
      --artifact bench-results/asr-encoded-parity/encoder_tap_42-13_fp16.mlpackage \
      --reference fp32 --json bench-results/asr-encoded-parity/gate_fp32ref.json
"""
from __future__ import annotations

import argparse
import copy
import gc
import json
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from asr_tap import (  # noqa: E402
    DEFAULT_MODEL,
    PASSES,
    SR,
    TIERS,
    StreamingTapEncoder,
    quantize_weights_int8_,
    reference_windows,
)

KEEP = None  # set from the tier


def load(model_id, device):
    from transformers import AutoModel, AutoProcessor

    proc = AutoProcessor.from_pretrained(model_id)
    model = AutoModel.from_pretrained(model_id, dtype=torch.float32).eval().to(device)
    return proc, model


def wrapper_pass(wrapper, feats, prompt_id):
    """Run the torch wrapper chunk by chunk; keep the caches too."""
    tier = wrapper.tier
    mel_length = torch.tensor([tier.total_mel], dtype=torch.int32)
    pid = torch.tensor([prompt_id])
    ch = torch.zeros(1, 24, wrapper.cache_size, 1024)
    ct_ = torch.zeros(1, 24, 1024, 8)
    cl = torch.tensor([1], dtype=torch.int32)
    enc, tap, chs = [], [], []
    with torch.no_grad():
        for win in reference_windows(feats, tier):
            e, t, ch, ct_, cl, _ = wrapper(win.transpose(1, 2).contiguous(), mel_length,
                                           ch, ct_, cl, pid)
            enc.append(e[0].transpose(0, 1).numpy())
            tap.append(t[0].transpose(0, 1).numpy())
            chs.append(ch[0].numpy())  # [24, C, 1024]
    return np.concatenate(enc), np.concatenate(tap), np.concatenate(chs)


def artifact_pass(mlmodel, feats, prompt_id, cache_size, tier):
    """The app's loop (one tier-sized window per call), keeping the caches."""
    total = tier.total_mel
    ch = np.zeros((1, 24, cache_size, 1024), np.float32)
    ct_ = np.zeros((1, 24, 1024, 8), np.float32)
    cl = 1
    enc, tap, chs, lens = [], [], [], []
    for win in reference_windows(torch.from_numpy(feats), tier):
        out = mlmodel.predict({
            "mel": win.numpy().transpose(0, 2, 1).astype(np.float32),
            "mel_length": np.array([total], np.int32),
            "cache_channel": ch,
            "cache_time": ct_,
            "cache_len": np.array([cl], np.int32),
            "prompt_id": np.array([prompt_id], np.int32),
        })
        enc.append(out["encoded"][0].T)
        tap.append(out["tap_l4"][0].T)
        ch = out["cache_channel_out"]
        ct_ = out["cache_time_out"]
        cl = int(out["cache_len_out"][0])
        chs.append(ch[0])
        lens.append(cl)
    return (np.concatenate(enc), np.concatenate(tap), np.concatenate(chs),
            np.array(lens))


def cos_rows(a, b):
    a, b = np.asarray(a, np.float64), np.asarray(b, np.float64)
    return (a * b).sum(1) / (np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1) + 1e-12)


def stats(a, b, shift=0):
    """Row-wise cosine; shift > 0 compares a[i] with b[i + shift] (b trimmed)."""
    if shift > 0:
        b = b[shift:]
    elif shift < 0:
        a = a[-shift:]
    n = min(len(a), len(b))
    a, b = a[:n], b[:n]
    c = cos_rows(a, b)
    return {
        "rows": int(n),
        "cos_p50": float(np.percentile(c, 50)),
        "cos_p05": float(np.percentile(c, 5)),
        "cos_min": float(c.min()),
        "max_abs": float(np.abs(a.astype(np.float64) - b).max()),
    }


def table(name, a, b, keep):
    print(f"  {name}")
    buckets = ((1, 8), (8, 16), (16, 32), (32, 64), (64, 10 ** 9))
    print("    bucket       rows   cos p50     cos p05     cos min    max|d|")
    for lo, hi in ((0, 10 ** 9),) + buckets:
        x, y = lo * keep, min(hi * keep, len(a), len(b))
        if y <= x:
            continue
        s = stats(a[x:y], b[x:y])
        label = "all" if lo == 0 else f"chunks {lo:>3d}..{hi if hi < 10**9 else 'end'}"
        print(f"    {label:<12s} {s['rows']:6d}  {s['cos_p50']:.8f}  {s['cos_p05']:.8f}  "
              f"{s['cos_min']:.8f}  {s['max_abs']:.3e}")
    print("    row shift (same #rows, aligned differently):")
    for sh in (-1, 0, 1):
        s = stats(a, b, sh)
        print(f"      shift {sh:+d}: cos p50 {s['cos_p50']:.8f} min {s['cos_min']:.8f} "
              f"max|d| {s['max_abs']:.3e}")
    c = cos_rows(a[:min(len(a), len(b))], b[:min(len(a), len(b))])
    order = np.argsort(c)[:4]
    na = np.linalg.norm(a[:len(c)], axis=1)
    nb = np.linalg.norm(b[:len(c)], axis=1)
    print("    worst rows (row, cos, |ref|, |got|):",
          ", ".join(f"({int(i)}, {c[i]:.4f}, {na[i]:.3g}, {nb[i]:.3g})" for i in order))
    # per position within a chunk (row i mod keep) — a row-origin error is periodic
    pos = [stats(a[p::keep], b[p::keep])["cos_p05"] for p in range(keep)]
    print("    cos p05 by row-in-chunk:", " ".join(f"{p}:{v:.5f}" for p, v in enumerate(pos)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--artifact", action="append", default=[], required=True)
    ap.add_argument("--reference", default="fp32", choices=("fp32", "int8-enc", "int8-all"))
    ap.add_argument("--pass", dest="pass_", default="shipping", choices=sorted(PASSES))
    ap.add_argument("--chunk-ms", type=int, default=560, choices=sorted(TIERS))
    ap.add_argument("--fixture", default=None)
    ap.add_argument("--prompt-id", type=int, default=None)
    ap.add_argument("--drop-context-row", action="store_true",
                    help="reference wrapper uses the published conversion's framing (7 rows/call)")
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    import coremltools as ct
    import soundfile as sf

    from export_asr_tap import fixture_path, mel_of

    cfg = PASSES[args.pass_]
    tier = TIERS[args.chunk_ms]
    keep = tier.keep
    proc, model = load(args.model, args.device)
    prompt_id = int(model.config.default_prompt_id if args.prompt_id is None else args.prompt_id)
    wav = sf.read(str(fixture_path(args.fixture)), dtype="float32")[0]
    assert wav.ndim == 1
    feats_t = mel_of(proc, wav)
    feats = feats_t.numpy()
    n_chunks = max(0, (feats.shape[1] - tier.total_mel) // tier.mel_frames + 1)
    print(f"fixture {len(wav)/SR:.1f}s -> mel {feats.shape}, {n_chunks} chunks, "
          f"pass {cfg.name}, tier {tier.ms} ms, prompt {prompt_id}")

    ref_model = model
    if args.reference != "fp32":
        ref_model = copy.deepcopy(model)
        # the recorded gate quantized only `model.encoder`; `int8-all` is what Core ML does
        quantize_weights_int8_(ref_model if args.reference == "int8-all" else ref_model.encoder)
    ref = StreamingTapEncoder(ref_model, pass_cfg=cfg, tier=tier,
                              drop_context=args.drop_context_row).eval()
    ref_enc, ref_tap, ref_ch = wrapper_pass(ref, feats_t, prompt_id)
    del ref, ref_model
    gc.collect()
    print(f"torch reference: {len(ref_enc)} chunks, {len(ref_enc)*keep} rows")

    out = {"reference": args.reference, "pass": cfg.name, "chunk_ms": tier.ms,
           "row_convention": "drop-context" if args.drop_context_row else "keep-context",
           "prompt_id": prompt_id, "fixture": str(fixture_path(args.fixture)),
           "chunks": n_chunks, "artifacts": {}}
    for path in args.artifact:
        ml = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
        enc, tap, ch, lens = artifact_pass(ml, feats, prompt_id, cfg.left, tier)
        print(f"\n== {Path(path).name}")
        rows = tier.chunk_frames - (1 if args.drop_context_row else 0)
        print(f"  cache_len_out: first {lens[:8].tolist()} last {int(lens[-1])} "
              f"(torch wrapper adds {rows}/call)")
        res = {"bytes": sum(p.stat().st_size for p in Path(path).rglob("*") if p.is_file()),
               "chunk_frames": tier.chunk_frames}
        for name, a, b in (("encoded", ref_enc, enc), ("tap_l4", ref_tap, tap)):
            table(name, a, b, keep)
            res[name] = {k: stats(a, b, s) for k, s in
                         (("shift0", 0), ("shift_m1", -1), ("shift_p1", 1))}
            res[name]["buckets"] = {
                f"chunk_{lo}_{hi if hi < 10**9 else 'end'}":
                    stats(a[lo * keep:min(hi * keep, len(a))],
                          b[lo * keep:min(hi * keep, len(a))])
                for lo, hi in ((1, 8), (8, 16), (16, 32), (32, 64), (64, 10 ** 9))
                if min(hi * keep, len(a), len(b)) > lo * keep
            }
        # per layer: the attention-input cache is what each layer computed; if it
        # matches through layer 24 the stack is right and only the projector can differ
        n = min(len(ref_ch), len(ch))
        print("  cache_channel per layer (cos p05 / max|d|):")
        layers = []
        for i in range(24):
            a = ref_ch[:n, i]
            b = ch[:n, i]
            c = cos_rows(a.reshape(len(a), -1), b.reshape(len(b), -1))
            layers.append({"layer": i, "cos_p50": float(np.median(c)),
                           "cos_min": float(c.min()),
                           "max_abs": float(np.abs(a - b).max())})
            if i in (3, 4, 11, 19, 23):
                print(f"    layer {i:2d}: cos p50 {np.median(c):.8f} min {c.min():.8f} "
                      f"max|d| {np.abs(a - b).max():.3e}")
        res["cache_channel_by_layer"] = layers
        out["artifacts"][str(path)] = res
        del ml
        gc.collect()

    if args.json:
        Path(args.json).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json).write_text(json.dumps(out, indent=2))
        print("\nwrote", args.json)


if __name__ == "__main__":
    main()
