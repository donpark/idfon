"""Batched ears and the silent-ear cache on the 320 ms streaming prefix (#132).

Two tricks borrowed from tyger-s2s's ears engine (`asr.py:15,27-32,65-68`,
`constants.py: L15`), measured on *our* streaming prefix rather than assumed:

  batching     two ears in one call: batch 2 with two independent cache sets.
               `asr_tap.StreamingTapEncoder(batch=2)` is the same math; the export
               is `export_asr_tap.py --prefix-only --batch 2`. Equality is the
               gate: per ear, per chunk, batched vs two un-batched calls.
  silence      they encode an all-zero window once per length and reuse it. In a
               windowed pass that is the same input every hop; in a streaming
               pass the cache advances every chunk, so "silence in" is not
               obviously "same outputs out". This feeds K chunks of digital
               silence and reports (a) tap rows across chunks, (b) cache
               convergence, (c) whether holding chunk 1's cache/taps is valid —
               including a reactivation test: skip the silent middle, then feed
               speech and compare against a continuously-fed stream.

Cost is reported per 320 ms period for (i) two un-batched predictions, (ii) one
batched prediction, (iii) one prediction while the other ear is silent. Host
timings are macOS/ANE; the iPhone number does not exist yet (see the doc section).

Usage (artifacts are gitignored, written beside the shipping ones):

  ports/tyger-student/.venv/bin/python ports/tyger-student/batched_ears.py --export
  ports/tyger-student/.venv/bin/python ports/tyger-student/batched_ears.py --equality --silence --cost
  ports/tyger-student/.venv/bin/python ports/tyger-student/batched_ears.py --selfcheck

  --export writes `bench-results/asr-prefix-320/` (fp32 and fp16-int8w, b1/b2).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

SR = 16_000
MEL_PER_FRAME = 8           # 80 ms
PROMPT = 101
TAP_INDEX = 4
CHUNK_MS = 320
KEEP = 4                    # released rows per 320 ms chunk
TOTAL_MEL = 41              # 32 new + 9 pre-encode context
SILENCE_TOL = 2e-3          # the #102 feature envelope (fp16 export noise)
OUT_DIR = Path("bench-results/asr-prefix-320")

SINGLE = OUT_DIR / "encoder_tap_42-13_320ms_fp16_int8w_l4b1.mlpackage"
BATCHED = OUT_DIR / "encoder_tap_42-13_320ms_fp16_int8w_l4b2.mlpackage"
SINGLE_FP32 = OUT_DIR / "encoder_tap_42-13_320ms_fp32_l4b1.mlpackage"
BATCHED_FP32 = OUT_DIR / "encoder_tap_42-13_320ms_fp32_l4b2.mlpackage"

FIXTURE = Path("ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch0.wav")
FIXTURE_FALLBACK = Path(
    "/Users/don/dev/idfon/ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch0.wav")
CAPTURE = Path("/Users/don/Library/Application Support/Idfon/turn-captures/"
               "turn-2026-10-25T23:13:14Z.wav")


# --------------------------------------------------------------------------- #
# stats
# --------------------------------------------------------------------------- #
def cos_maxd(a, b):
    """-> (cosine, max|d|, relative L2, bitwise-equal) over flattened arrays."""
    a = np.asarray(a, np.float64).ravel()
    b = np.asarray(b, np.float64).ravel()
    den = max(np.linalg.norm(a) * np.linalg.norm(b), 1e-12)
    return {
        "cos": float(a @ b / den),
        "max_abs": float(np.abs(a - b).max()),
        "rel_l2": float(np.linalg.norm(a - b) / max(np.linalg.norm(b), 1e-12)),
        "exact": bool(np.array_equal(a, b)),
    }


def first_stable(seq, ref, tol):
    """First index from which every later item is within `tol` max|d| of `ref`.

    `seq` is a list of arrays; `ref` the final one. The final item cannot certify
    itself, so stability must hold through the penultimate item; None otherwise."""
    for k in range(len(seq) - 1):
        if all(np.abs(seq[j] - ref).max() <= tol for j in range(k, len(seq) - 1)):
            return k
    return None


def first_exact(seq, ref):
    return first_stable(seq, ref, 0.0)


def silence_mel(proc):
    """Digital silence through the real processor: [128, TOTAL_MEL] (channels-first).

    The extractor's final frame is a padding artefact (0.0, not the log-mel floor),
    so take the window before it: a genuinely constant input, which is the
    strongest case for the reuse shortcut."""
    x = np.zeros(4 * SR, np.float32)
    feats = proc(x, sampling_rate=SR, return_tensors="pt")["input_features"].numpy()
    w = feats[0, -TOTAL_MEL - 5:-5].T.astype(np.float32)
    assert np.array_equal(w, np.repeat(w[:, :1], TOTAL_MEL, axis=1)), "silence not constant"
    return w, feats


def mel_of(proc, wav):
    return proc(np.asarray(wav, np.float32), sampling_rate=SR,
                return_tensors="pt")["input_features"].numpy()


def windows(feats, n_chunks, offset=0):
    """[channels-first 128 x TOTAL_MEL] chunks, same grid as `reference_windows`."""
    out = []
    for i in range(n_chunks):
        end = TOTAL_MEL + (offset + i) * (TOTAL_MEL - 9)
        out.append(feats[0, end - TOTAL_MEL:end].T.astype(np.float32))
    return out


def read_wav(path):
    import soundfile as sf

    x, sr = sf.read(str(path), dtype="float32")
    assert sr == SR and x.ndim == 1, (sr, x.shape)
    return x


def read_stereo(path):
    with wave.open(str(path)) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (2, 2, SR), path
        raw = w.readframes(w.getnframes())
    x = np.frombuffer(raw, np.int16).reshape(-1, 2).astype(np.float32) / 32768.0
    return np.ascontiguousarray(x[:, 0]), np.ascontiguousarray(x[:, 1])


# --------------------------------------------------------------------------- #
# Core ML plumbing
# --------------------------------------------------------------------------- #
def resolve(path):
    """Artifacts are gitignored: a fresh worktree sees the main checkout's copy."""
    p = Path(path)
    if p.exists():
        return p
    alt = Path("/Users/don/dev/idfon") / p
    return alt if alt.exists() else p


def load(path, units="ane"):
    import coremltools as ct

    cu = ct.ComputeUnit.CPU_AND_NE if units == "ane" else ct.ComputeUnit.CPU_ONLY
    return ct.models.MLModel(str(resolve(path)), compute_units=cu)


def zero_caches(batch, depth=4, left=42):
    return (np.zeros((batch, depth, left, 1024), np.float32),
            np.zeros((batch, depth, 1024, 8), np.float32),
            np.ones((batch,), np.int32))


def call(ml, mel_batch, caches, prompt=PROMPT):
    """One cache-aware call. mel_batch [B,128,TOTAL_MEL] -> tap [B,KEEP,1024]."""
    ch, ct_, cl = caches
    out = ml.predict({
        "mel": np.ascontiguousarray(mel_batch, np.float32),
        "mel_length": np.full((mel_batch.shape[0],), TOTAL_MEL, np.int32),
        "cache_channel": ch,
        "cache_time": ct_,
        "cache_len": cl,
        "prompt_id": np.full((mel_batch.shape[0],), prompt, np.int32),
    })
    tap = np.asarray(out["tap_l4"], np.float32).transpose(0, 2, 1)  # [B,KEEP,1024]
    return tap, (out["cache_channel_out"], out["cache_time_out"],
                 np.asarray(out["cache_len_out"], np.int32))


def stream(ml, mels, batch=1, caches=None):
    """Thread caches over a list of mel chunks; returns taps [N,B,KEEP,1024] and caches."""
    caches = caches or zero_caches(batch)
    taps = []
    for mel in mels:
        # a 2-D item is one chunk for every slot; a 3-D item is already batched
        m = mel if mel.ndim == 3 else np.repeat(mel[None], batch, axis=0)
        tap, caches = call(ml, m, caches)
        taps.append(tap)
    return np.stack(taps), caches


# --------------------------------------------------------------------------- #
# batching equality
# --------------------------------------------------------------------------- #
def equality(single_path, batched_path, mels_a, mels_b):
    ml1, ml2 = load(single_path), load(batched_path)
    ta, _ = stream(ml1, mels_a)
    tb, _ = stream(ml1, mels_b)
    tabs, _ = stream(ml2, [np.stack([a, b]) for a, b in zip(mels_a, mels_b)], batch=2)
    per = []
    worst = {"cos": 1.0, "max_abs": 0.0, "rel_l2": 0.0, "exact": True}
    for k in range(len(mels_a)):
        for ear, single in (("a", ta[k, 0]), ("b", tb[k, 0])):
            s = cos_maxd(tabs[k, int(ear == "b")], single)
            per.append({"chunk": k, "ear": ear, **s})
            worst["cos"] = min(worst["cos"], s["cos"])
            worst["max_abs"] = max(worst["max_abs"], s["max_abs"])
            worst["rel_l2"] = max(worst["rel_l2"], s["rel_l2"])
            worst["exact"] &= s["exact"]
    return {"single": str(resolve(single_path)), "batched": str(resolve(batched_path)),
            "chunks": len(mels_a), "worst": worst, "per_chunk": per}


# --------------------------------------------------------------------------- #
# silent-ear study
# --------------------------------------------------------------------------- #
def silent_study(ml, sil_mel, speech_mel, k_chunks=24, tol=SILENCE_TOL):
    """Feed K chunks of silence; then test reuse on reactivation."""
    taps, _ = stream(ml, [sil_mel] * k_chunks)
    taps = taps[:, 0]                     # [K,KEEP,1024]
    # re-run to keep per-chunk cache snapshots (the loop above only kept the last)
    caches = zero_caches(1)
    snaps, chs, cts, cls = [], [], [], []
    for _ in range(k_chunks):
        _, caches = call(ml, sil_mel[None], caches)
        snaps.append((caches[0].copy(), caches[1].copy(), caches[2].copy()))
        chs.append(caches[0][0].copy())
        cts.append(caches[1][0].copy())
        cls.append(int(caches[2][0]))

    final_tap = taps[-1]
    tap_to_final = [cos_maxd(taps[i], final_tap) for i in range(k_chunks)]
    tap_to_prev = [cos_maxd(taps[i], taps[i - 1]) for i in range(1, k_chunks)]
    tap1 = taps[1]
    tap_to_chunk1 = [cos_maxd(taps[i], tap1) for i in range(k_chunks)]
    ch_to_final = [cos_maxd(chs[i], chs[-1]) for i in range(k_chunks)]
    ct_to_final = [cos_maxd(cts[i], cts[-1]) for i in range(k_chunks)]

    stable = first_stable([*taps], final_tap, tol)
    exact = first_exact([*taps], final_tap)
    # a cosine criterion is scale-free (fp16 resolution is ~1e-2 at these norms)
    stable_cos = next(
        (k for k in range(k_chunks - 1)
         if all(cos_maxd(taps[j], final_tap)["cos"] >= 0.9999
                for j in range(k, k_chunks - 1))), None)
    ch_stable = first_stable([*chs], chs[-1], tol)
    ct_stable = first_stable([*cts], cts[-1], tol)

    # Reactivation: hold chunk 1's cache through the silent middle, then feed speech,
    # vs feed every silent chunk and then the same speech. If silence is a fixed
    # point the two speech taps are identical; if not, the shortcut changes features.
    _, cache1 = call(ml, sil_mel[None], zero_caches(1))          # chunk 0
    tap1b, cache1 = call(ml, sil_mel[None], cache1)              # chunk 1
    tap_skip, _ = call(ml, speech_mel[None], cache1)             # jump to speech
    tap_cont, _ = call(ml, speech_mel[None], caches)             # continuous silence
    at = stable if stable is not None else k_chunks - 1
    tap_from_stable, _ = call(ml, speech_mel[None], snaps[at])
    reactivation = {
        "skip_from_chunk1_vs_continuous": cos_maxd(tap_skip[0], tap_cont[0]),
        "skip_from_stable_chunk_vs_continuous": cos_maxd(tap_from_stable[0], tap_cont[0]),
        "stable_chunk_used": at,
        "silent_chunk0_vs_chunk1": cos_maxd(taps[0], taps[1]),
        "chunk1_cache_vs_final": {
            "channel": cos_maxd(chs[1], chs[-1]),
            "time": cos_maxd(cts[1], cts[-1]),
        },
        "stable_cache_vs_final": {
            "channel": cos_maxd(chs[at], chs[-1]),
            "time": cos_maxd(cts[at], cts[-1]),
        },
    }
    return {
        "chunks": k_chunks, "tol": tol, "cache_len": cls,
        "tap": {
            "chunk0_vs_final": tap_to_final[0],
            "chunk1_vs_final": cos_maxd(taps[1], final_tap),
            "first_stable_vs_final": stable,
            "first_cos_9999_vs_final": stable_cos,
            "first_bitwise_vs_final": exact,
            "first_stable_vs_chunk1": first_stable([*taps], tap1, tol),
            "per_chunk_vs_final": [
                {"chunk": i, **tap_to_final[i]} for i in range(k_chunks)],
            "per_chunk_vs_prev": [
                {"chunk": i + 1, **tap_to_prev[i]} for i in range(k_chunks - 1)],
            "per_chunk_vs_chunk1": [
                {"chunk": i, **tap_to_chunk1[i]} for i in range(k_chunks)],
        },
        "cache": {
            "first_stable_channel": ch_stable,
            "first_stable_time": ct_stable,
            "channel_per_chunk_vs_final": [
                {"chunk": i, **ch_to_final[i]} for i in range(k_chunks)],
            "time_per_chunk_vs_final": [
                {"chunk": i, **ct_to_final[i]} for i in range(k_chunks)],
        },
        "reactivation": reactivation,
        "taps": taps,
    }


# --------------------------------------------------------------------------- #
# cost
# --------------------------------------------------------------------------- #
def timed(fn, warm=5, n=50):
    for _ in range(warm):
        fn()
    ts = []
    for _ in range(n):
        t0 = time.perf_counter_ns()
        fn()
        ts.append((time.perf_counter_ns() - t0) / 1e6)
    return {"p50": float(np.percentile(ts, 50)), "p95": float(np.percentile(ts, 95)),
            "n": n}


def cost_study(mels_a, mels_b, units="ane"):
    ml1, ml2 = load(SINGLE, units), load(BATCHED, units)
    ca, cb = zero_caches(1), zero_caches(1)
    c2 = zero_caches(2)
    ma, mb = mels_a[0][None], mels_b[0][None]
    mbatch = np.concatenate([ma, mb], axis=0)

    def one_a():
        call(ml1, ma, ca)

    def one_b():
        call(ml1, mb, cb)

    def batch():
        call(ml2, mbatch, c2)

    t1, t2, tb = timed(one_a), timed(one_b), timed(batch)
    two = {"p50": t1["p50"] + t2["p50"], "p95": t1["p95"] + t2["p95"]}
    res = {"units": units, "period_ms": CHUNK_MS,
           "single_a": t1, "single_b": t2, "two_singles": two, "batched": tb,
           "duty": {"two_singles": two["p50"] / CHUNK_MS,
                    "batched": tb["p50"] / CHUNK_MS,
                    "silent_other_ear": t1["p50"] / CHUNK_MS},
           "loadavg": list(os.getloadavg())}
    return res


# --------------------------------------------------------------------------- #
# export / orchestration
# --------------------------------------------------------------------------- #
def export(out=OUT_DIR):
    """The two artifacts the study needs, in the shipping pass and precision."""
    import subprocess

    here = Path(__file__).resolve().parent
    out = Path(out)
    common = ["--export", "--prefix-only", "--depth", "4", "--chunk-ms", "320",
              "--pass", "shipping", "--out", str(out)]
    for precision, int8, batch in (("fp32", False, 1), ("fp32", False, 2),
                                   ("fp16", True, 1), ("fp16", True, 2)):
        cmd = [sys.executable, str(here / "export_asr_tap.py"), *common,
               "--precision", precision, "--batch", str(batch)]
        if int8:
            cmd.append("--int8")
        print("+", " ".join(cmd))
        subprocess.run(cmd, check=True)


def selfcheck():
    """Arithmetic only: the reuse test must accept a fixed point and reject drift."""
    a = np.ones((4, 1024), np.float32)
    # a fixed point with fp16-sized per-chunk noise: reuse is fine, bitwise is not
    stationary = [a + 1e-5 * (k + 1) for k in range(6)]
    drift = [a * (1.0 + 0.01 * k) for k in range(6)]
    assert first_stable(stationary, stationary[-1], 1e-3) == 0
    assert first_exact(stationary, stationary[-1]) is None
    assert first_stable(drift, drift[-1], 1e-3) is None  # only the final chunk matches
    assert first_stable(drift, drift[-1], 10.0) == 0
    assert cos_maxd(a, a)["exact"] and cos_maxd(a, a)["cos"] > 0.999999
    assert cos_maxd(a, -a)["cos"] < -0.999999
    # independent caches: batch 2 is two rows, not a shared one
    c = zero_caches(2)
    assert c[0].shape == (2, 4, 42, 1024) and c[1].shape == (2, 4, 1024, 8)
    c[0][0].fill(1.0)
    assert c[0][1].sum() == 0.0
    print("selfcheck ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", action="store_true")
    ap.add_argument("--equality", action="store_true")
    ap.add_argument("--silence", action="store_true")
    ap.add_argument("--cost", action="store_true")
    ap.add_argument("--selfcheck", action="store_true")
    ap.add_argument("--torch", action="store_true",
                    help="also compare the Core ML pair with the torch wrappers")
    ap.add_argument("--chunks", type=int, default=12, help="equality chunks (each ear)")
    ap.add_argument("--silent-chunks", type=int, default=24)
    ap.add_argument("--silent-artifact", default=str(SINGLE),
                    help="artifact for the silent study (fp32 control: %s)" % SINGLE_FP32)
    ap.add_argument("--units", default="ane", choices=("ane", "cpu"))
    ap.add_argument("--fixture", default=None)
    ap.add_argument("--out", default=None, help="JSON result path")
    args = ap.parse_args()

    if args.selfcheck:
        selfcheck()
        if not (args.equality or args.silence or args.cost or args.export):
            return
    if args.export:
        export()
        if not (args.equality or args.silence or args.cost):
            return

    results = {}
    if args.equality or args.silence:
        from transformers import AutoProcessor

        proc = AutoProcessor.from_pretrained(
            os.environ.get("TYGER_ASR", "nvidia/nemotron-3.5-asr-streaming-0.6b"))
        fx = Path(args.fixture) if args.fixture else (
            FIXTURE if FIXTURE.exists() else FIXTURE_FALLBACK)
        wav = read_wav(fx)
        if CAPTURE.exists():
            _, wav_b = read_stereo(CAPTURE)
        else:  # fall back to a different slice of the same fixture
            wav_b = wav[5 * SR:]
        feats_a, feats_b = mel_of(proc, wav), mel_of(proc, wav_b)
        mels_a = windows(feats_a, max(args.chunks, 4))
        mels_b = windows(feats_b, max(args.chunks, 4))

        if args.equality:
            results["equality_fp32"] = equality(
                SINGLE_FP32, BATCHED_FP32, mels_a[:args.chunks], mels_b[:args.chunks])
            results["equality_int8w"] = equality(
                SINGLE, BATCHED, mels_a[:args.chunks], mels_b[:args.chunks])
            if args.torch:
                results["torch"] = torch_equality(mels_a[:args.chunks], mels_b[:args.chunks])

        if args.silence:
            sil, _ = silence_mel(proc)
            ml = load(args.silent_artifact, args.units)
            study = silent_study(ml, sil, mels_a[0], args.silent_chunks)
            results["silence"] = {k: v for k, v in study.items() if k != "taps"}

    if args.cost:
        from transformers import AutoProcessor

        proc = AutoProcessor.from_pretrained(
            os.environ.get("TYGER_ASR", "nvidia/nemotron-3.5-asr-streaming-0.6b"))
        fx = Path(args.fixture) if args.fixture else (
            FIXTURE if FIXTURE.exists() else FIXTURE_FALLBACK)
        wav = read_wav(fx)
        wav_b = read_stereo(CAPTURE)[1] if CAPTURE.exists() else wav[5 * SR:]
        mels_a = windows(mel_of(proc, wav), 2)
        mels_b = windows(mel_of(proc, wav_b), 2)
        results["cost"] = cost_study(mels_a, mels_b, args.units)
        results["bytes"] = {p.name: sum(f.stat().st_size for f in resolve(p).rglob("*")
                            if f.is_file())
                            for p in (SINGLE, BATCHED, SINGLE_FP32, BATCHED_FP32)}

    print(json.dumps(results, indent=2, default=float))
    if args.out:
        Path(args.out).write_text(json.dumps(results, indent=2, default=float))
        print("wrote", args.out)


def torch_equality(mels_a, mels_b):
    """The same equality on the torch wrappers: batch 2 vs two batch-1 passes."""
    import torch
    from transformers import AutoModel

    from asr_tap import SHIPPING, TIER_320, StreamingTapEncoder

    model = AutoModel.from_pretrained(
        os.environ.get("TYGER_ASR", "nvidia/nemotron-3.5-asr-streaming-0.6b"),
        dtype=torch.float32).eval()

    def run(batch, ear=None):
        w = StreamingTapEncoder(model, SHIPPING, tier=TIER_320, batch=batch,
                                depth=4, prefix_only=True)
        c = (torch.zeros(batch, 4, 42, 1024), torch.zeros(batch, 4, 1024, 8),
             torch.ones(batch, dtype=torch.int32))
        taps = []
        with torch.no_grad():
            for ma, mb in zip(mels_a, mels_b):
                mel = np.stack([ma, mb]) if ear is None else np.stack([
                    ma if ear == 0 else mb] * batch)
                tap, *c = w(torch.from_numpy(mel[:batch]),
                            torch.full((batch,), TOTAL_MEL, dtype=torch.int32),
                            *c, torch.full((batch,), PROMPT, dtype=torch.int32))
                c = tuple(c)
                taps.append(tap.numpy())
        return np.stack(taps)

    single_a, single_b, batched = run(1, 0), run(1, 1), run(2)
    per = []
    worst = {"cos": 1.0, "max_abs": 0.0}
    for k in range(len(mels_a)):
        for ear, single in (("a", single_a[k, 0]), ("b", single_b[k, 0])):
            s = cos_maxd(batched[k, int(ear == "b")], single)
            per.append({"chunk": k, "ear": ear, **s})
            worst["cos"] = min(worst["cos"], s["cos"])
            worst["max_abs"] = max(worst["max_abs"], s["max_abs"])
    # prefix vs full depth: layers above the tap cannot change it
    wf = StreamingTapEncoder(model, SHIPPING, tier=TIER_320, batch=1, depth=24)
    c = (torch.zeros(1, 24, 42, 1024), torch.zeros(1, 24, 1024, 8),
         torch.ones(1, dtype=torch.int32))
    full = []
    with torch.no_grad():
        for ma in mels_a:
            _, tap, ch, cht, cl, _ = wf(
                torch.from_numpy(ma)[None],
                torch.full((1,), TOTAL_MEL, dtype=torch.int32), *c,
                torch.full((1,), PROMPT, dtype=torch.int32))
            c = (ch, cht, cl)
            full.append(tap.numpy()[0])
    depth = max(np.abs(np.stack(full)[k] - single_a[k, 0]).max()
                for k in range(len(mels_a)))
    return {"worst": worst, "per_chunk": per,
            "prefix_vs_full_depth_max_abs": float(depth)}


if __name__ == "__main__":
    main()
