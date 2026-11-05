"""The playback ear (#132/#102): can `ha` come from the streaming ASR encoder?

Today `hu = encode(mic)` and `ha = encode(playback)` both go through the private
106M-param L4 cut, so deleting the cut needs both ears moved. The mic ear is
measured; the playback ear is a different audio stream (the agent's own TTS
voice) and needs its own encoder cache. This measures whether a streaming pass
of the tap-declaring ASR encoder reproduces the cut's playback rows, what the
second cache set costs, and what a restart does to the frame grid.

Four measurements, none of which changes a threshold, rule or model:

  parity   tap rows over the playback channel vs the *stored* windowed cut rows
           (`ha_l4` in `bench-results/live-shipping`) per frame: cosine p50/p05
           and rel-L2 p50, per session, at the harness's measured grid offset.
  cost     one loaded artifact, two cache sets: per-chunk time for one stream vs
           two, the 560 ms budget with the turn steps, and the RSS delta of the
           second cache set (macOS process RSS; NOT an iPhone number).
  timing   a playback frame's `ha` availability: today (hop boundary, hu encoded
           before ha) vs streaming (chunk boundary, same serial order), per
           session, reported apart from the mic ear.
  reset    restart the playback stream at agent-utterance starts: row error vs
           the continuous stream by chunk-after-reset, duplicated frames, and
           the frame-origin drift a consumer gets if it carries one origin.

The shipping-intended shape is one loaded artifact with one cache set per ear,
both streams fed continuously (silence included) - the shape today's windowed
path already has (`TurnRuntime` appends both hops every 320 ms). A second
manager instance is measured only for what it would duplicate in RSS.

Usage (artifacts are gitignored; paths are the maintainer layout):

  ports/tyger-student/.venv/bin/python ports/tyger-student/playback_ear.py \
      --sessions 2026-10-25T23:13:14Z,2026-10-26T20:17:43Z,2026-10-26T21:13:38Z \
      --out bench-results/playback-ear.json

  --selfcheck   grid/drift/stat arithmetic only, no models
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from tap_latency import (  # noqa: E402
    CHUNK_FRAMES,
    CHUNK_MEL,
    DEFAULT_SESSIONS,
    FRAME_SAMPLES,
    HOP_FRAMES,
    PRE_ENCODE,
    SR,
    TOTAL_MEL,
    WINDOW_S,
    StreamingTap,  # noqa: F401  (the class whose shape this replicates)
    WindowedEncoder,
    _mel_of,
    frame_energy,
    read_capture,
)

ARTIFACTS = {
    # the artifact the published per-frame tap numbers used (56/0 reference pass)
    "reference-56-0": "bench-results/asr-tap-ref56/encoder_tap_fp16_int8w.mlpackage",
    # the corrected, shipping-intended pass (post mask fix); cache depth 42
    "shipping-42-13": "bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage",
}
STEP_MODEL = "bench-results/student-l4-coreml/StudentStep.mlpackage"
WINDOWED_DIR = "bench-results/coreml-l4"
RESTART_SILENCE_FRAMES = 12      # >= 1 s of silence before an utterance counts as a restart
RESTART_CHUNKS = 8              # measure the first 8 chunks of a restarted stream
STUDY_FRAMES = 240              # steps timed on this many real rows
MEL_PER_FRAME = 8               # 80 ms frame = 8 x 10 ms mel frames


# --------------------------------------------------------------------------- #
# small helpers
# --------------------------------------------------------------------------- #
def pct(xs, p):
    return float(np.percentile(xs, p)) if len(xs) else None


def stat(xs):
    xs = np.asarray(xs, np.float64)
    if not len(xs):
        return {"n": 0}
    return {"n": int(len(xs)), "mean": round(float(xs.mean()), 2),
            "p50": round(pct(xs, 50), 2), "p95": round(pct(xs, 95), 2),
            "max": round(float(xs.max()), 2)}


def rss_mb():
    """Process RSS from `ps` (macOS). Deliberately not a device number."""
    out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())])
    return int(out.strip()) / 1024.0


def cache_bytes(depth):
    """Analytic fp32 bytes of one ear's cache set (channel + time + len)."""
    return 4 * (24 * depth * 1024 + 24 * 1024 * 8 + 1)


def new_caches(depth):
    c = [np.zeros((1, 24, depth, 1024), np.float32),
         np.zeros((1, 24, 1024, 8), np.float32), 1]
    # touch the pages: an RSS delta must not be a lazy-mapping artefact
    c[0].fill(0.0)
    c[1].fill(0.0)
    return tuple(c)


def encode_with(model, mel65, caches):
    """One cache-aware call on a shared model; returns (rows [7,1024], s, caches)."""
    ch, cht, cl = caches
    feats = {
        "mel": np.ascontiguousarray(mel65.transpose(0, 2, 1), np.float32),
        "mel_length": np.array([TOTAL_MEL], np.int32),
        "cache_channel": ch,
        "cache_time": cht,
        "cache_len": np.array([cl], np.int32),
        "prompt_id": np.array([101], np.int32),
    }
    t0 = time.perf_counter_ns()
    out = model.predict(feats)
    dt = (time.perf_counter_ns() - t0) / 1e9
    return (np.asarray(out["tap_l4"][0], np.float32).T,
            dt, (out["cache_channel_out"], out["cache_time_out"],
                 int(out["cache_len_out"][0])))


def cos_rel(a, b):
    a = a.astype(np.float64)
    b = b.astype(np.float64)
    cos = float(a @ b / max(np.linalg.norm(a) * np.linalg.norm(b), 1e-12))
    rel = float(np.linalg.norm(a - b) / max(np.linalg.norm(b), 1e-12))
    return cos, rel


# --------------------------------------------------------------------------- #
# feature producers
# --------------------------------------------------------------------------- #
def windowed_rows(wav, T, mel_of, enc):
    """Today's path for one ear: 4 rows per 320 ms hop, 8 s (growing) window."""
    rows = np.zeros((T // HOP_FRAMES * HOP_FRAMES, 1024), np.float32)
    times = []
    for gi in range(T // HOP_FRAMES):
        f0 = gi * HOP_FRAMES
        end = (f0 + HOP_FRAMES) * FRAME_SAMPLES
        hist = int(min(WINDOW_S * SR, end))
        r, dt = enc.encode(mel_of(wav[end - hist:end]))
        rows[f0:f0 + HOP_FRAMES] = r[-HOP_FRAMES:]
        times.append(dt)
    return rows, np.asarray(times)


def stream_rows(mel, model, depth, caches=None, first_frame=0, n_chunks=None, T=None):
    """Continuous streaming pass -> (rows by stream row index, per-chunk seconds).

    Stream row i is chunk i//7, row i%7. On the session grid (the measured
    convention) it belongs to frame 7*(i//7)+1+(i%7) for a stream starting at
    frame 0; the stored cut row it reproduces is row i+1.
    """
    caches = caches or new_caches(depth)
    n = n_chunks if n_chunks is not None else T // CHUNK_FRAMES
    rows, times = {}, []
    for gi in range(n):
        w0 = (first_frame + gi * CHUNK_FRAMES) * MEL_PER_FRAME
        r, dt, caches = encode_with(model, mel[:, w0:w0 + TOTAL_MEL], caches)
        for k in range(CHUNK_FRAMES):
            rows[gi * CHUNK_FRAMES + k] = r[k]
        times.append(dt)
    return rows, np.asarray(times), caches


def utterance_spans(energy, T):
    """Frames where the agent channel starts after >= 1 s of silence, and ends."""
    starts, silent = [], 0
    loud = energy[:T] > -45.0
    for i in range(T):
        if loud[i]:
            if silent >= RESTART_SILENCE_FRAMES:
                starts.append(i)
            silent = 0
        else:
            silent += 1
    ends = []
    for i, g0 in enumerate(starts):
        stop = starts[i + 1] if i + 1 < len(starts) else T
        e = g0
        while e + 1 < stop and loud[e + 1]:
            e += 1
        ends.append(e)
    return starts, ends


# --------------------------------------------------------------------------- #
# one session, phase 1 (processor) then phase 2 (tap)
# --------------------------------------------------------------------------- #
def prepare(sid, args, enc, processor):
    """Mel + today's windowed rows for both ears, before any tap prediction.

    Measured earlier: a tap prediction makes later processor calls segfault on
    this host, so every mel call has to happen before the first tap prediction.
    """
    cap = Path(os.path.expanduser(args.captures)) / f"turn-{sid}.wav"
    if not cap.exists():
        raise SystemExit(f"capture not found: {cap}")
    wav_u, wav_a = read_capture(cap)
    T = len(wav_a) // FRAME_SAMPLES
    shard = Path(args.shards) / f"live-turn-{sid}.npz"
    if not shard.exists():
        raise SystemExit(f"shard not found (needed for the cut's playback rows): {shard}")
    z = np.load(shard)
    T = min(T, int(z["energy"].shape[0]))
    if args.limit_frames:
        T = min(T, args.limit_frames)
    energy = frame_energy(wav_u)
    mel_of = _mel_of(processor)
    # full mel: the last chunk's 9 pre-context frames come from past frame T
    mel_u = mel_of(wav_u)
    mel_a = mel_of(wav_a)
    rows_a, hop_a = windowed_rows(wav_a, T, mel_of, enc)
    rows_u, hop_u = windowed_rows(wav_u, T, mel_of, enc)
    return {"session": sid, "T": T, "energy": energy,
            "mel_u": mel_u, "mel_a": mel_a, "hu_today": rows_u, "ha_today": rows_a,
            "ref_a": z["ha_l4"], "ref_u": z["hu_l4"],
            "hop_a": hop_a, "hop_u": hop_u}


def parity(ref, tap_rows, T):
    """Tap stream row i vs a stored cut row i+1 (the measured grid), frame >= 1."""
    n = min(len(tap_rows), len(ref) - 1, T - 1)
    cos, rel, by_k = [], [], {}
    for i in range(n):
        c, r = cos_rel(tap_rows[i], ref[i + 1])
        cos.append(c)
        rel.append(r)
        by_k.setdefault(i % CHUNK_FRAMES, []).append(c)
    ctrl = [cos_rel(tap_rows[i], ref[i])[0] for i in range(n)]
    return {"frames": n,
            "cos_p50": round(float(np.median(cos)), 5),
            "cos_p05": round(float(np.percentile(cos, 5)), 5),
            "cos_min": round(float(np.min(cos)), 5),
            "relL2_p50": round(float(np.median(rel)), 5),
            "offset_control_cos_p50": round(float(np.median(ctrl)), 4),
            "by_row_position_cos_p50": {
                f"k{k}": round(float(np.median(v)), 4) for k, v in sorted(by_k.items())}}


def replay_check(today_rows, ref):
    """The windowed replay must reproduce the stored cut rows (a re-run)."""
    m = min(len(today_rows), len(ref))
    cos = [cos_rel(today_rows[i], ref[i])[0] for i in range(m)]
    return {"frames": m, "cos_p50": round(float(np.median(cos)), 5)}


def timing(prep, times_u, times_a):
    """Per-frame feature-ready minus that frame's audio end, per ear, per path.

    Today: a hop's rows exist at hop end + hu encode + ha encode (serial in
    `TurnRuntime.feed`). Streaming: a chunk's rows exist at chunk end (or the
    previous chunk's finish) + hu encode + ha encode.
    """
    T, today, stream = prep["T"], [], []
    for f in range(len(prep["hop_u"]) * HOP_FRAMES):
        gi = f // HOP_FRAMES
        ready = (gi + 1) * HOP_FRAMES * 0.080 + prep["hop_u"][gi] + prep["hop_a"][gi]
        today.append(ready - (f + 1) * 0.080)
    done = 0.0
    for gi in range(len(times_u)):
        audio_end = (CHUNK_MEL * (gi + 1) + PRE_ENCODE) / 100.0
        ready = max(audio_end, done) + times_u[gi] + times_a[gi]
        for k in range(CHUNK_FRAMES):
            f = 7 * gi + 1 + k
            if f < T:
                stream.append(ready - (f + 1) * 0.080)
        done = ready
    return {"today_ha_delay_ms": stat([x * 1e3 for x in today]),
            "stream_ha_delay_ms": stat([x * 1e3 for x in stream]),
            "today_mic_ha_share_ms": round(float(np.median(prep["hop_u"])) * 1e3, 2),
            "today_playback_encode_ms": stat(prep["hop_a"] * 1e3)}


def reset_study(prep, model, depth, starts, ends, cont_rows):
    """Restart the playback stream at each utterance start; compare to continuous."""
    T = prep["T"]
    used = [g0 for g0 in starts if g0 + RESTART_CHUNKS * CHUNK_FRAMES < T]
    per, by_chunk = [], {}
    for g0 in used:
        fresh, times, _ = stream_rows(prep["mel_a"], model, depth, first_frame=g0,
                                      n_chunks=RESTART_CHUNKS)
        dup = cos_rel(fresh[0], fresh[1])[0]      # chunk 0's context row vs its first row
        cs = []
        for i in range(RESTART_CHUNKS * CHUNK_FRAMES):
            j, _k = divmod(i, CHUNK_FRAMES)
            if g0 + i not in cont_rows:
                continue
            c, _ = cos_rel(fresh[i], cont_rows[g0 + i])
            cs.append(c)
            by_chunk.setdefault(j, []).append(c)
        per.append({"start_frame": g0, "rows": len(cs),
                    "cos_p50": round(float(np.median(cs)), 4),
                    "cos_min": round(float(np.min(cs)), 4),
                    "dup_row0_cos": round(dup, 5),
                    "first_chunk_ms": round(float(times[0]) * 1e3, 2)})
    return {"restarts": len(per), "detail": per,
            "cos_vs_continuous_by_chunk_after_restart": {
                f"chunk{c}": round(float(np.median(v)), 4) for c, v in sorted(by_chunk.items())},
            "frame_origin": frame_origin_study(used, ends)}


def continuous_after_silence(prep, tap_rows, starts):
    """Parity slice: frames right after a silence gap inside the continuous stream."""
    win = {f for g0 in starts
           for f in range(g0, min(prep["T"], g0 + RESTART_CHUNKS * CHUNK_FRAMES))}
    n = min(len(tap_rows), len(prep["ref_a"]) - 1)
    cs, rest = [], []
    for i in range(n):
        c, _ = cos_rel(tap_rows[i], prep["ref_a"][i + 1])
        (cs if (i + 1) in win else rest).append(c)
    return {"frames_after_silence": len(cs),
            "cos_p50": round(float(np.median(cs)), 4) if cs else None,
            "cos_p05": round(float(np.percentile(cs, 5)), 4) if cs else None,
            "steady_cos_p50": round(float(np.median(rest)), 4) if rest else None}


def frame_origin_study(starts, ends):
    """Frame-origin consequences of restarting, arithmetically from the starts.

    A restarted stream's chunk 0 emits 8 rows (a context row plus 7 new ones)
    while its audio is 7 frames, so a consumer that advances its origin by the
    rows it received adds one frame per restart. If playback audio is not fed
    while the agent is silent, the skipped frames are lost from the origin on
    top of that. The first start is the baseline (origin 0).
    """
    if not starts:
        return {"restarts": 0}
    base, a, b, extras, fed = starts[0], [], [], 0, 0
    for i, g0 in enumerate(starts):
        a.append(extras)                        # silence fed: the dup only
        b.append(extras - (g0 - base - fed))    # playback only: minus skipped
        if i < len(ends):
            fed += ends[i] - g0 + 1
        extras += 1
    return {"restarts": len(starts),
            "dup_rows_total": extras,
            "drift_continuous_first_last": [a[0], a[-1]],
            "drift_playback_only_first_last": [b[0], b[-1]],
            "drift_playback_only_ms": round(b[-1] * 80.0, 1),
            "note": "drift in frames; positive = rows placed after their true frame"}


# --------------------------------------------------------------------------- #
# cost: one stream vs two on one loaded artifact
# --------------------------------------------------------------------------- #
def cost_study(prep, model, depth, student):
    T = prep["T"]
    n_chunks = T // CHUNK_FRAMES
    # one stream for the playback ear alone (same rows, artifact and clocks)
    _, one, _ = stream_rows(prep["mel_a"], model, depth, T=T)
    # product shape: one model, two independent cache sets, hu then ha per chunk
    cu, ca = new_caches(depth), new_caches(depth)
    rows_u, rows_a, times_u, times_a = {}, {}, [], []
    for gi in range(n_chunks):
        w0 = gi * CHUNK_MEL
        ru, du, cu = encode_with(model, prep["mel_u"][:, w0:w0 + TOTAL_MEL], cu)
        ra, da, ca = encode_with(model, prep["mel_a"][:, w0:w0 + TOTAL_MEL], ca)
        for k in range(CHUNK_FRAMES):
            rows_u[gi * 7 + k], rows_a[gi * 7 + k] = ru[k], ra[k]
        times_u.append(du)
        times_a.append(da)
    # the turn steps: the real student on real rows
    n = min(STUDY_FRAMES, len(rows_u))
    step_ms = []
    student.reset()
    for i in range(n):
        t0 = time.perf_counter_ns()
        student.step(rows_u[i], rows_a[i], 0.0, 0)
        step_ms.append((time.perf_counter_ns() - t0) / 1e6)
    period_ms = CHUNK_FRAMES * FRAME_SAMPLES / SR * 1e3
    pair = np.asarray(times_u) + np.asarray(times_a)
    budget = float(np.median(pair)) * 1e3 + CHUNK_FRAMES * float(np.median(step_ms))
    return {
        "chunks": n_chunks,
        "one_stream_ms": stat(np.asarray(one) * 1e3),
        "two_streams_each_ms": {"mic": stat(np.asarray(times_u) * 1e3),
                                "playback": stat(np.asarray(times_a) * 1e3)},
        "two_streams_chunk_ms": stat(pair * 1e3),
        "step_ms": stat(step_ms),
        "period_ms": period_ms,
        "budget_ms": {"encode_both": round(float(np.median(pair)) * 1e3, 2),
                      "steps_per_chunk": CHUNK_FRAMES,
                      "steps": round(CHUNK_FRAMES * float(np.median(step_ms)), 2),
                      "total": round(budget, 2),
                      "fraction_of_period": round(budget / period_ms, 3)},
        "memory": {
            "cache_bytes_per_ear_fp32": cache_bytes(depth),
            "cache_mib_per_ear": round(cache_bytes(depth) / 2**20, 2),
            "two_ear_cache_mib": round(2 * cache_bytes(depth) / 2**20, 2),
        },
    }


MEMORY_PROBE = r"""
import json, os, subprocess, sys
import numpy as np, coremltools as ct

def rss():
    return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())]).strip()) / 1024

def caches(depth):
    a = np.zeros((1, 24, depth, 1024), np.float32)
    b = np.zeros((1, 24, 1024, 8), np.float32)
    a.fill(0.0); b.fill(0.0)          # touch the pages
    return (a, b, 1)

path, depth = sys.argv[1], int(sys.argv[2])
model = ct.models.MLModel(path, compute_units=ct.ComputeUnit.CPU_AND_NE)

def call(c):
    out = model.predict({"mel": np.zeros((1, 128, 65), np.float32),
                         "mel_length": np.array([65], np.int32),
                         "cache_channel": c[0], "cache_time": c[1],
                         "cache_len": np.array([1], np.int32),
                         "prompt_id": np.array([101], np.int32)})
    return (out["cache_channel_out"], out["cache_time_out"],
            int(out["cache_len_out"][0]))

one = caches(depth)
one = call(call(one))                 # one ear live, steady state
r1 = rss()
two = caches(depth)
two = call(call(two))                 # second ear live
r2 = rss()
print(json.dumps({"one_ear_rss_mib": round(r1, 1), "two_ears_rss_mib": round(r2, 1),
                  "second_set_rss_delta_mib": round(r2 - r1, 1)}))
"""


def memory_probe(path, depth):
    """One vs two live cache sets, in a clean process (freed pages never return)."""
    import subprocess as sp
    out = sp.check_output([sys.executable, "-c", MEMORY_PROBE, str(path), str(depth)],
                          cwd=str(Path(__file__).resolve().parents[2]), text=True)
    d = json.loads(out.strip().splitlines()[-1])
    d["note"] = "macOS process RSS on an M4 Pro; not an iPhone number"
    return d


def second_instance_rss(path):
    """What a *second manager* would duplicate: a second MLModel on one package."""
    import coremltools as ct
    before = rss_mb()
    m = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_AND_NE)
    depth = int(m.get_spec().description.input[2].type.multiArrayType.shape[2])
    ch, cht, cl = new_caches(depth)
    m.predict({"mel": np.zeros((1, 128, TOTAL_MEL), np.float32),
               "mel_length": np.array([TOTAL_MEL], np.int32),
               "cache_channel": ch, "cache_time": cht,
               "cache_len": np.array([cl], np.int32),
               "prompt_id": np.array([101], np.int32)})
    after = rss_mb()
    return {"second_instance_rss_delta_mib": round(after - before, 1), "path": str(path)}


# --------------------------------------------------------------------------- #
# selfcheck
# --------------------------------------------------------------------------- #
def selfcheck():
    assert cache_bytes(56) == 4 * (24 * 56 * 1024 + 24 * 1024 * 8 + 1)
    # stream row i maps to chunk i//7, row i%7, and reproduces stored row i+1
    for i in (0, 6, 7, 13, 700):
        gi, k = divmod(i, CHUNK_FRAMES)
        assert gi * CHUNK_FRAMES + k == i
        assert 7 * gi + 1 + k == i + 1
    # +90 ms pre-context stamp sits 10 ms past the chunk's own end (the grid cancels)
    assert abs((CHUNK_MEL * 1 + PRE_ENCODE) / 100.0 - 0.65) < 1e-12
    # restart: 8 rows emitted for 7 frames -> one duplicate per restart, and the
    # continuous/playback-only drift bookkeeping
    r = frame_origin_study([100, 300, 700], [150, 400, 800])
    assert r["dup_rows_total"] == 3
    assert r["drift_continuous_first_last"] == [0, 2]
    # playback-only: each restart loses the silent frames it never fed
    assert r["drift_playback_only_first_last"] == [0, -446]
    assert abs(cos_rel(np.array([1.0, 0.0]), np.array([1.0, 0.0]))[0] - 1.0) < 1e-12
    assert pct([1, 2, 3, 4], 50) == 2.5
    assert rss_mb() > 20
    print("selfcheck: cache bytes, grid offset, restart dup/drift, cosine, RSS OK")


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--sessions", default=",".join(DEFAULT_SESSIONS))
    ap.add_argument("--captures", default="~/Library/Application Support/Idfon/turn-captures")
    ap.add_argument("--shards", default="bench-results/live-shipping")
    ap.add_argument("--windowed-dir", default=WINDOWED_DIR)
    ap.add_argument("--step", default=STEP_MODEL)
    ap.add_argument("--artifacts", default=",".join(ARTIFACTS),
                    help=f"tap artifacts to measure: {', '.join(ARTIFACTS)}")
    ap.add_argument("--out", default=None)
    ap.add_argument("--limit-frames", type=int, default=0,
                    help="debug: first N frames of each capture only")
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args()
    if args.selfcheck:
        selfcheck()
        return
    args.artifacts = [a.strip() for a in args.artifacts.split(",") if a.strip()]
    for a in args.artifacts:
        if a not in ARTIFACTS:
            raise SystemExit(f"unknown artifact key {a!r}")

    from transformers import AutoProcessor
    from tap_latency import Student
    processor = AutoProcessor.from_pretrained("nvidia/nemotron-3.5-asr-streaming-0.6b")
    enc = WindowedEncoder(Path(args.windowed_dir))
    student = Student(Path(args.step))   # before any tap prediction (get_spec segfault)
    enc.fixed.predict({"feats": np.zeros((1, 801, 128), np.float16)})
    enc.dyn.predict({"feats": np.zeros((1, 801, 128), np.float32)})

    preps = [prepare(s.strip(), args, enc, processor)
             for s in args.sessions.split(",") if s.strip()]

    out = {"sessions": [], "artifacts": {}}
    for key in args.artifacts:
        import coremltools as ct
        path = ARTIFACTS[key]
        model = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_AND_NE)
        depth = int(model.get_spec().description.input[2].type.multiArrayType.shape[2])
        ch, cht, cl = new_caches(depth)
        model.predict({"mel": np.zeros((1, 128, TOTAL_MEL), np.float32),
                       "mel_length": np.array([TOTAL_MEL], np.int32),
                       "cache_channel": ch, "cache_time": cht,
                       "cache_len": np.array([cl], np.int32),
                       "prompt_id": np.array([101], np.int32)})
        print(f"\n=== {key}: {path} (cache depth {depth})", flush=True)
        recs = []
        for prep in preps:
            print(f"  {prep['session']} ({prep['T']} frames)", flush=True)
            rows_a, times_a, _ = stream_rows(prep["mel_a"], model, depth,
                                             T=prep["T"])
            rows_u, times_u, _ = stream_rows(prep["mel_u"], model, depth,
                                             T=prep["T"])
            cost = cost_study(prep, model, depth, student)
            par = parity(prep["ref_a"], rows_a, prep["T"])
            par["windowed_replay"] = replay_check(prep["ha_today"], prep["ref_a"])
            mic = parity(prep["ref_u"], rows_u, prep["T"])
            mic["windowed_replay"] = replay_check(prep["hu_today"], prep["ref_u"])
            starts, ends = utterance_spans(prep["energy"], prep["T"])
            reset = reset_study(prep, model, depth, starts, ends, rows_a)
            reset["continuous_after_silence"] = continuous_after_silence(
                prep, rows_a, starts)
            rec = {"session": prep["session"], "frames": prep["T"],
                   "parity_playback": par, "parity_mic": mic,
                   "timing": timing(prep, times_u, times_a),
                   "cost": cost, "reset": reset}
            recs.append(rec)
            print(f"    playback cos p50 {par['cos_p50']} p05 {par['cos_p05']} "
                  f"relL2 {par['relL2_p50']} | mic p50 {mic['cos_p50']} "
                  f"p05 {mic['cos_p05']} | replay {par['windowed_replay']['cos_p50']}",
                  flush=True)
            print(f"    one stream {cost['one_stream_ms']['p50']} ms  two "
                  f"{cost['two_streams_chunk_ms']['p50']} ms  step "
                  f"{cost['step_ms']['p50']} ms  budget "
                  f"{cost['budget_ms']['total']} ms "
                  f"({cost['budget_ms']['fraction_of_period']:.0%} of 560)", flush=True)
            print(f"    ha delay today p50 {rec['timing']['today_ha_delay_ms']['p50']} "
                  f"stream p50 {rec['timing']['stream_ha_delay_ms']['p50']} ms", flush=True)
            print(f"    restarts {reset['restarts']}  cos by chunk "
                  f"{reset['cos_vs_continuous_by_chunk_after_restart']}", flush=True)
            print(f"    after-silence parity {reset['continuous_after_silence']}",
                  flush=True)
        out["artifacts"][key] = {
            "path": path, "cache_depth": depth, "sessions": recs,
            "memory_process_probe": memory_probe(path, depth),
            "second_manager_instance": second_instance_rss(path)}
        out["sessions"].append({"artifact": key, "sessions": [
            {"session": r["session"], "parity_playback": r["parity_playback"],
             "parity_mic": r["parity_mic"],
             "cost": r["cost"]["budget_ms"], "memory": r["cost"]["memory"],
             "timing": r["timing"],
             "reset": {k: r["reset"][k] for k in
                       ("restarts", "cos_vs_continuous_by_chunk_after_restart",
                        "continuous_after_silence", "frame_origin")}} for r in recs]})

    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(out, indent=1))
        print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
