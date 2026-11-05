"""Pass-config gate for the ASR tap (#102): does the *shipping* attention pass give
the same L4 features as the reference pass the adapter was fitted on?

Two questions, two numbers, never one:

  1. **pass drift**   42/13 (NeMo `att_context_size [42,13]`, what the shipping 3.5
                     multilingual bundle runs) vs 56/0 (what `tap4-shards` records).
  2. **quant drift**  per-channel int8 weights at 42/13 vs fp32 at 42/13 — the weight
                     grid alone, so pass and precision never get conflated.

Decisions are not decided here: `--emit-shards` writes a candidate shard set on the
reference grid, and `tap_gate.py` replays one checkpoint on both sides (the ≥99% bar).

Row convention: `stream_rows()` emits 8 rows for chunk 0 (context + 7 new) and 7 after,
matching `featurize_tap.tap()`. Shard emission pads one row at the front and trims to the
shard's T, because the torch reference's first chunk carries one extra context row that a
steady-framing pass cannot emit (`docs/voice-tyger-streaming-plan.md` § Leg 1).

`--chunk-ms` selects the emitter tier and must match the artifact's own `chunk_ms`
(the sidecar is checked). The frame grid is the same 80 ms row grid at every tier
(tier only changes how many rows one encoder call releases), so a 320 shard is
frame-comparable to a 560 one — verified by a lag scan, not assumed.

Usage:
  $PY ports/tyger-student/pass_gate.py --drift                       # fixture + session rows
  $PY ports/tyger-student/pass_gate.py --drift --int8                # + the weight grid
  $PY ports/tyger-student/pass_gate.py --emit-shards bench-results/tap-shipping/val \
      --pass shipping --sessions 2                                   # then tap_gate.py
  $PY ports/tyger-student/pass_gate.py --emit-shards bench-results/tap-shipping-320 \
      --pass shipping --chunk-ms 320 --artifact .../asr-tap-320/...mlpackage
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from asr_tap import (  # noqa: E402
    DEFAULT_MODEL,
    KEEP,
    PASSES,
    REFERENCE,
    SHIPPING,
    SR,
    TIERS,
    TOTAL_MEL,
    StreamingTapEncoder,
    divergence,
    quantize_weights_int8_,
    reference_windows,
    stream_rows,
)

# `stream_rows` already keeps the reference's row convention (chunk 0 = context + 7 new),
# so the candidate lands on the shard's frame grid with no shift. Measured: pad 0 -> cos
# p50 1.000000 against the stored shard; pad 1 or 2 drop it to 0.999 / 0.910.
REF_GRID_PAD = 0
SESSION = "d622d1e377001bba8c718a2fbdac0b7b"
SHARDS = "/Users/don/dev/idfon/bench-results/tap4-shards/val"


def rel_l2(a, b):
    a, b = np.asarray(a, np.float64), np.asarray(b, np.float64)
    return np.linalg.norm(a - b, axis=1) / np.maximum(np.linalg.norm(b, axis=1), 1e-12)


def table(name, a, b, buckets=((0, 8), (8, 32), (32, 64), (64, 10**9))):
    n = min(len(a), len(b))
    print(f"{name}: rows {n}")
    for lo, hi in buckets:
        x, y = lo * KEEP, min(hi * KEEP, n)
        if y <= x:
            continue
        cos, rel = divergence(a[x:y], b[x:y])[0], float(np.median(rel_l2(a[x:y], b[x:y])))
        print(f"  chunks {lo:4d}..{min(hi, n):5d}  cos p50 {cos:.8f}  "
              f"(min {divergence(a[x:y], b[x:y])[1]:.8f})  relL2 p50 {rel:.4e}  "
              f"max|d| {divergence(a[x:y], b[x:y])[2]:.3e}")
    cos = divergence(a[:n], b[:n])
    print(f"  all rows: cos p50 {cos[0]:.8f}  min {cos[1]:.8f}  relL2 p50 "
          f"{float(np.median(rel_l2(a[:n], b[:n]))):.4e}  max|d| {cos[2]:.3e}  "
          f"mean|d| {float(np.abs(np.asarray(a[:n],np.float64)-np.asarray(b[:n],np.float64)).mean()):.3e}")


def _cached(cache: Path, frames):
    if not cache.exists():
        return None
    wav = np.load(cache)
    need = int(np.ceil(frames * SR * 0.08)) if frames else 0
    if frames and len(wav) < need:  # a stale, shorter cache would silently truncate the shard
        return None
    if frames:  # the pass is causal: only the frames the shard covers matter
        wav = wav[: need + SR]
    return wav


def session_wav_ch1(session_id, cache_dir: Path, _ch0=None, frames=None, split="val"):
    cache = Path(cache_dir) / f"{session_id}-ch1.npy"
    hit = _cached(cache, frames)
    if hit is not None:
        return hit
    from datasets import load_dataset
    from transformers import AutoModel as HFAutoModel

    from oracle import decode_channel, resample16k

    mimi = HFAutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()
    for row in load_dataset("anyreach-ai/dualturn-otospeech-turn-taking", split=split, streaming=True):
        if row["session_id"] != session_id:
            continue
        codes = np.array(row["codes_ch1"], dtype=np.int16).reshape(int(row["num_frames"]), 8)
        if frames:
            codes = codes[:frames]  # only what the shard covers; the pass is causal
        wav = resample16k(decode_channel(mimi, codes))
        Path(cache_dir).mkdir(parents=True, exist_ok=True)
        np.save(cache, wav)
        return wav
    raise SystemExit(f"session {session_id} not found in the {split} split")


def session_wav(session_id, cache_dir: Path, frames=None, split="val"):
    cache = Path(cache_dir) / f"{session_id}.npy"
    hit = _cached(cache, frames)
    if hit is not None:
        return hit
    from datasets import load_dataset
    from transformers import AutoModel as HFAutoModel

    from oracle import decode_channel, resample16k

    mimi = HFAutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()
    for row in load_dataset("anyreach-ai/dualturn-otospeech-turn-taking", split=split, streaming=True):
        if row["session_id"] != session_id:
            continue
        codes = np.array(row["codes_ch0"], dtype=np.int16).reshape(int(row["num_frames"]), 8)
        if frames:
            codes = codes[:frames]  # only what the shard covers; the pass is causal
        wav = resample16k(decode_channel(mimi, codes))
        Path(cache_dir).mkdir(parents=True, exist_ok=True)
        np.save(cache, wav)
        return wav
    raise SystemExit(f"session {session_id} not found in the {split} split")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--drift", action="store_true", help="feature drift tables")
    ap.add_argument("--priming", action="store_true",
                    help="cold-vs-warm convergence: how many chunks until the cache is full")
    ap.add_argument("--int8", action="store_true", help="also simulate int8 weights at 42/13")
    ap.add_argument("--emit-shards", default=None, help="write candidate shards here (for tap_gate.py)")
    ap.add_argument("--pass", dest="pass_", default="shipping", choices=sorted(PASSES))
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--fixture", default=None)
    ap.add_argument("--session-id", default=SESSION)
    ap.add_argument("--wav-cache", default="bench-results/asr-tap/wav")
    ap.add_argument("--shards", default=SHARDS)
    ap.add_argument("--split", default="val", help="dualturn split the shard dir came from (train|val)")
    ap.add_argument("--sessions", type=int, default=1)
    ap.add_argument("--frames", type=int, default=1200,
                    help="emit only the first N shard frames (the shard stays T-long; tap_gate trims to N)")
    ap.add_argument("--artifact", default=None,
                    help="featurize through this .mlpackage (the refit's training source: int8 + fp16 "
                         "exactly as served) instead of the torch simulation")
    ap.add_argument("--chunk-ms", type=int, default=560, choices=sorted(TIERS),
                    help="chunk tier the emitter runs; must match --artifact's tier "
                         "(the shard grid is the same 80 ms rows either way)")
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args()
    if not (args.drift or args.emit_shards or args.priming):
        ap.error("pass --drift, --priming and/or --emit-shards")

    import soundfile as sf
    from transformers import AutoModel, AutoProcessor

    proc = AutoProcessor.from_pretrained(args.model)
    model = AutoModel.from_pretrained(args.model, dtype=torch.float32).eval().to(args.device)
    cfg = PASSES[args.pass_]
    tier = TIERS[args.chunk_ms]
    ref = StreamingTapEncoder(model, pass_cfg=REFERENCE, tier=tier).eval()
    cand = StreamingTapEncoder(model, pass_cfg=cfg, tier=tier).eval()
    print(f"passes: reference {REFERENCE.name} cache {REFERENCE.left}, candidate {cfg.name} "
          f"cache {cfg.left}, group {cfg.group}")

    def rows(wrapper, wav):
        return stream_rows(wrapper, proc, wav)

    if args.drift:
        fx = [Path("ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch0.wav"),
              Path("/Users/don/dev/idfon/ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch0.wav")]
        fx = next((p for p in ([Path(args.fixture)] if args.fixture else []) + fx if p.exists()), None)
        if fx is None:
            raise SystemExit("fixture wav not found; pass --fixture")
        wav = sf.read(str(fx), dtype="float32")[0]
        a = rows(ref, wav).astype(np.float32)
        b = rows(cand, wav).astype(np.float32)
        print(f"\nfixture {fx.name} ({len(wav)/SR:.0f}s):")
        table(f"  {cfg.name} vs {REFERENCE.name} (tap rows)", b, a)
        if args.int8:
            import copy

            m2 = copy.deepcopy(model)
            quantize_weights_int8_(m2.encoder)
            q = StreamingTapEncoder(m2, pass_cfg=cfg).eval()
            c = rows(q, wav).astype(np.float32)
            table(f"  {cfg.name} int8-weights vs {cfg.name} fp32 (tap rows)", c, b)
            del m2, q

    if args.priming:
        # What does priming buy? Run the same audio cold (the manager seeds cache_len=1) and
        # again after `fills` silent chunks. The caches agree from chunk `fills` on, so priming
        # can only change the first `fills` chunks - and at 42/13 that is 42/7 = 6 chunks.
        fx = [Path("ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch0.wav"),
              Path("/Users/don/dev/idfon/ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch0.wav")]
        fx = next((p for p in ([Path(args.fixture)] if args.fixture else []) + fx if p.exists()), None)
        wav = sf.read(str(fx), dtype="float32")[0]
        feats = proc(np.asarray(wav, np.float32), sampling_rate=SR, return_tensors="pt")["input_features"]
        mel_length = torch.tensor([TOTAL_MEL], dtype=torch.int32)
        pid = torch.tensor([model.config.default_prompt_id])
        fills = int(np.ceil(cfg.left / KEEP))

        def run(prime_chunks):
            ch = torch.zeros(1, 24, cfg.left, 1024)
            ct_ = torch.zeros(1, 24, 1024, 8)
            cl = torch.tensor([1], dtype=torch.int32)
            rows = []
            with torch.no_grad():
                for _ in range(prime_chunks):
                    ch, ct_, cl = cand(torch.zeros(1, 128, TOTAL_MEL), mel_length, ch, ct_, cl, pid)[2:5]
                for win in reference_windows(feats):
                    _, tap, ch, ct_, cl, _ = cand(win.transpose(1, 2).contiguous(), mel_length, ch, ct_, cl, pid)
                    rows.append(tap[0].transpose(0, 1))
            return rows

        cold, primed = run(0), run(fills)
        n = min(len(cold), len(primed))
        print(f"\npriming at {cfg.name}: cache {cfg.left} frames = {fills} chunks; "
              f"cold vs {fills}x-silent primed, per chunk")
        for i in range(min(n, fills + 3)):
            a, b = cold[i], primed[i]
            print(f"  chunk {i:2d}: max|d| {float((a - b).abs().max()):.3e}  "
                  f"cos min {float(torch.nn.functional.cosine_similarity(a, b, dim=1).min()):.8f}")
        for lo, hi in ((fills, fills + 4), (fills + 4, fills + 12), (fills + 12, n)):
            if hi <= lo:
                continue
            d = max(float((cold[i] - primed[i]).abs().max()) for i in range(lo, min(hi, n)))
            print(f"  chunks {lo:2d}..{min(hi, n):3d}: max|d| {d:.3e}")

    if args.emit_shards:
        import copy

        out = Path(args.emit_shards)
        out.mkdir(parents=True, exist_ok=True)
        refs = {p.stem: p for p in sorted(Path(args.shards).glob("*.npz"))}
        from data import load_shard, save_shard

        emitter = cand
        if args.artifact:
            import coremltools as ct

            from export_asr_tap import ml_stream

            mlmodel = ct.models.MLModel(args.artifact, compute_units=ct.ComputeUnit.CPU_AND_NE)
            side = Path(args.artifact).parent / "metadata.json"
            if side.exists():
                have = json.loads(side.read_text()).get("chunk_ms")
                assert have == tier.ms, f"{side}: chunk_ms {have} != --chunk-ms {tier.ms}"

            def rows(wrapper, wav):  # noqa: F811 - the artifact replaces the torch emitter
                feats = proc(np.asarray(wav, np.float32), sampling_rate=SR, return_tensors="pt")
                _, tap, _ = ml_stream(mlmodel, feats["input_features"].numpy(),
                                      prompt_id=int(model.config.default_prompt_id),
                                      cache_size=cfg.left, tier=tier)
                # ml_stream emits only the tier's new rows per chunk; the shard grid carries
                # one extra leading row (the reference's first-chunk context), so shift by one
                return np.concatenate([tap[:1], tap])

        elif args.int8:
            m2 = copy.deepcopy(model)
            quantize_weights_int8_(m2.encoder)
            emitter = StreamingTapEncoder(m2, pass_cfg=cfg).eval()
        done = 0
        order = ([args.session_id] if args.session_id in refs else []) + [s for s in refs if s != args.session_id]
        for sid in order[: args.sessions]:
            frames, labels, events, _meta = load_shard(str(refs[sid]))
            T = min(len(frames["energy"]), args.frames)
            need = T + 8  # inputs are 80 ms code frames; the pass is causal, so the tail is free
            wav = session_wav(sid, Path(args.wav_cache), frames=need, split=args.split)
            rows_u = rows(emitter, wav)
            rows_a = rows(emitter, session_wav_ch1(sid, Path(args.wav_cache), wav, frames=need, split=args.split))
            hu, ha = rows_u[:T], rows_a[:T]
            n = min(T, len(hu), len(ha))
            frames = {k: (v[:n] if isinstance(v, np.ndarray) else v) for k, v in frames.items()}
            frames["hu"], frames["ha"] = hu[:n], ha[:n]
            save_shard(str(out / f"{sid}.npz"), sid, frames,
                       {k: v[:n] for k, v in labels.items()},
                       events=(np.asarray(events[0], np.int32), events[1]) if events is not None else None)
            done += 1
            print(f"  {sid[:16]}… {cfg.name} {tier.ms} ms{' int8' if args.int8 else ''} "
                  f"{n}/{T} frames -> {out}")
        print(f"{done} shard(s) in {out}")


if __name__ == "__main__":
    main()
