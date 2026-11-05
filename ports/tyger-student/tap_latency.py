"""Tap latency (#102): when does a frame's decision exist on the streaming-tap
path, versus today's windowed path, on the same audio?

Instrumentation only. Nothing here changes a threshold, the rules, or a model.

Why the question exists: today's path encodes an 8 s window per 320 ms hop, so a
frame's features are ready at its hop's boundary. The tap path reads `tap_l4`
from the ASR's cache-aware streaming encoder, which emits **7 frames per 560 ms
chunk at the chunk boundary**. A frame early in a chunk can therefore wait up to
~480 ms after its own audio before its feature exists. The endpoint bars are
stated from audio availability, so this is measured, not assumed.

What is replayed (all three on the same capture, same student, same rules, same
audio timestamps):

  tap      streaming tap artifact, 7-frame chunks, decisions after each chunk
  today    the windowed L4 encoder per 320 ms hop, 4-frame hops (the shipped path)
  cadence  today's windowed features, released at the streaming chunk boundary
           (control: isolates the cadence from the feature/model difference)

Scoring modes for the tap rows (`--scoring`); the rows only exist at the chunk
boundary in every mode, so none of these can beat that delivery:

  chunk      the existing pass: every row of a chunk is scored at its boundary
  per-frame  one student step per row as delivered, begin_hop per 80 ms frame
  tap-hop    rows gated to the shipped 4-frame hop: a row waits for its hop's
             last row (this is what routing tap rows through TurnRuntime.feed
             costs; every chunk boundary does not align with a hop boundary)

`--left-policies` selects the rules' `left` argument for per-frame scoring:
`hop-phase` (3 - f%4, today's value sequence), `zero`, `chunk-countdown`
(frames after this row in its delivery chunk, the existing tap pass's value).
`left` reaches only a BARGE's `onset_s` (crates/idfon-voice/src/turns.rs), so
the policies cannot move a decision; they are measured to show that.

Replay clock: encoder calls are timed with `perf_counter_ns`; the session is
scheduled on a virtual audio clock — group start = max(group audio end, previous
group's decision end), group ready = start + measured encode time. No sleeping,
no dropped audio, one serial pipeline; a backlog shows up as ready times running
past the audio clock. This is the wall clock the product would see, composed from
measured work, not a simulated cost.

Timestamps recorded per 80 ms frame: audio end, feature ready, decision emitted.
Rules are the real Rust state machine (`idfon_voice_turn_*` through the app's
dylib), threaded per frame with the rules' prev_state and resets at BARGE /
ENDPOINT; mode is `listen` on both paths (these captures have no mode track).

Usage (artifacts are gitignored; the paths below are the maintainer layout):

  ports/tyger-student/.venv/bin/python ports/tyger-student/tap_latency.py \
      --sessions 2026-10-25T23:13:14Z,2026-10-26T20:17:43Z,2026-10-26T21:13:38Z \
      --rules-dylib mac/Vendor/libiroh_c_ffi.dylib \
      --out bench-results/tap-latency.json

  --selfcheck   pairing/scheduling checks, no models (assert-based)
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import time
import wave
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

SR = 16000
FRAME_SAMPLES = 1280           # 80 ms
HOP_FRAMES = 4                 # today: 320 ms
CHUNK_FRAMES = 7               # tap: 560 ms
CHUNK_MEL = 56                 # 560 ms of mel at 10 ms
SCORINGS = ("chunk", "per-frame", "tap-hop")
LEFT_POLICIES = ("hop-phase", "zero", "chunk-countdown")
PRE_ENCODE = 9                 # the tap contract's pre-encode context
TOTAL_MEL = CHUNK_MEL + PRE_ENCODE
WINDOW_S = 8.0
MODE = "listen"
DEFAULT_SESSIONS = (
    "2026-10-25T23:13:14Z",    # 112 s, 20 endpoints, 16 backchannels
    "2026-10-26T20:17:43Z",    #  89 s, 16 endpoints, 17 backchannels
    "2026-10-26T21:13:38Z",    # 152 s, 20 endpoints, 16 backchannels
)


def now_s() -> float:
    return time.perf_counter_ns() / 1e9


# --------------------------------------------------------------------------- #
# audio / models
# --------------------------------------------------------------------------- #
def read_capture(path: Path):
    """TurnCapture stereo s16 16 kHz -> (ch0 mic, ch1 agent) f32."""
    with wave.open(str(path)) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (2, 2, SR), path
        raw = w.readframes(w.getnframes())
    x = np.frombuffer(raw, np.int16).reshape(-1, 2).astype(np.float32) / 32768.0
    return np.ascontiguousarray(x[:, 0]), np.ascontiguousarray(x[:, 1])


def frame_energy(wav: np.ndarray) -> np.ndarray:
    """rules.frame_energy: per-80 ms-frame energy in dB (the step's act input)."""
    n = len(wav) // FRAME_SAMPLES
    seg = wav[: n * FRAME_SAMPLES].reshape(n, FRAME_SAMPLES).astype(np.float64)
    mean = (seg * seg).mean(axis=1)
    return (20.0 * np.log10(np.sqrt(mean + 1e-12) + 1e-9)).astype(np.float32)


class WindowedEncoder:
    """Today's feature producer: growing/8 s window -> L4 rows (Core ML L4 cut)."""

    def __init__(self, directory: Path):
        import coremltools as ct
        self.fixed = ct.models.MLModel(str(directory / "TygerEncoderL4.mlpackage"),
                                       compute_units=ct.ComputeUnit.CPU_AND_NE)
        self.dyn = ct.models.MLModel(str(directory / "TygerEncoderL4Dyn.mlpackage"),
                                     compute_units=ct.ComputeUnit.CPU_AND_NE)
        self.fixed_name = self.fixed.get_spec().description.output[0].name
        self.dyn_name = self.dyn.get_spec().description.output[0].name

    def encode(self, mel: np.ndarray):
        """mel [1, t, 128] -> (rows [t//8+1, 1024], seconds spent in the prediction)."""
        if mel.shape[1] == 801:
            feats, model, name = mel.astype(np.float16), self.fixed, self.fixed_name
        else:
            feats, model, name = mel.astype(np.float32), self.dyn, self.dyn_name
        t0 = now_s()
        out = model.predict({"feats": feats})
        dt = now_s() - t0
        rows = np.asarray(out[name], np.float32).reshape(-1, 1024)
        return rows, dt


class StreamingTap:
    """The tap path's feature producer: one cache-aware call per 560 ms chunk."""

    def __init__(self, path: Path):
        import coremltools as ct
        self.model = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_AND_NE)
        spec = self.model.get_spec().description
        self.cache_depth = int(spec.input[2].type.multiArrayType.shape[2])
        self.reset()

    def reset(self):
        # FluidAudio seeds cache_len = 1 (one zero frame); the artifact clamps the depth.
        self.caches = (np.zeros((1, 24, self.cache_depth, 1024), np.float32),
                       np.zeros((1, 24, 1024, 8), np.float32), 1)

    def encode(self, mel65: np.ndarray):
        """mel65 [1, 65, 128] -> (tap rows [7, 1024], seconds spent in the prediction)."""
        ch, cht, cl = self.caches
        feats = {
            "mel": np.ascontiguousarray(mel65.transpose(0, 2, 1), np.float32),
            "mel_length": np.array([TOTAL_MEL], np.int32),
            "cache_channel": ch,
            "cache_time": cht,
            "cache_len": np.array([cl], np.int32),
            "prompt_id": np.array([101], np.int32),
        }
        t0 = now_s()
        out = self.model.predict(feats)
        dt = now_s() - t0
        self.caches = (out["cache_channel_out"], out["cache_time_out"],
                       int(out["cache_len_out"][0]))
        return np.asarray(out["tap_l4"][0], np.float32).T, dt


class Student:
    """The shipped L4 student step (Core ML), carried GRU state, reset at rules resets."""

    def __init__(self, path: Path):
        import coremltools as ct
        self.model = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_AND_NE)
        desc = self.model.get_spec().description
        self.state_name, self.state_shape = None, None
        for i in desc.input:
            shape = tuple(int(x) for x in i.type.multiArrayType.shape)
            if len(shape) == 3 and shape[-1] != 1024:  # (2,1,256) vs hu/ha (1,1,1024)
                self.state_name, self.state_shape = i.name, shape
        if self.state_name is None:
            raise SystemExit(f"{path}: no carried-state input")
        self.state = np.zeros(self.state_shape, np.float32)

    def reset(self):
        self.state[...] = 0

    def step(self, hu, ha, act_db, prev_state) -> np.ndarray:
        feats = {
            "hu": hu.reshape(1, 1, 1024).astype(np.float32),
            "ha": ha.reshape(1, 1, 1024).astype(np.float32),
            "act_db": np.array([[act_db]], np.float32),
            "prev_state": np.array([[prev_state]], np.int32),
            self.state_name: self.state,
        }
        out = self.model.predict(feats)
        eight = None
        for v in out.values():
            a = np.asarray(v, np.float32)
            if a.size == 8:
                eight = a.reshape(8)
            elif a.size == self.state.size:
                self.state = a.reshape(self.state_shape)
        if eight is None:
            raise SystemExit("step model returned no 8-vector")
        return eight


class Rules:
    """The app's Rust rules through the `idfon_voice_turn_*` C ABI."""

    def __init__(self, dylib: Path, thresholds: dict | None = None):
        lib = ctypes.CDLL(str(dylib))
        lib.idfon_voice_turn_new.restype = ctypes.c_void_p
        lib.idfon_voice_turn_new.argtypes = [ctypes.c_char_p]
        lib.idfon_voice_turn_free.argtypes = [ctypes.c_void_p]
        lib.idfon_voice_turn_begin_hop.restype = ctypes.c_uint8
        lib.idfon_voice_turn_begin_hop.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
            ctypes.POINTER(ctypes.c_float), ctypes.c_size_t, ctypes.c_char_p]
        lib.idfon_voice_turn_prev_state.restype = ctypes.c_int32
        lib.idfon_voice_turn_prev_state.argtypes = [ctypes.c_void_p]
        lib.idfon_voice_turn_on_frame.restype = ctypes.c_void_p
        lib.idfon_voice_turn_on_frame.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.c_double,
            ctypes.c_size_t, ctypes.c_char_p,
            ctypes.POINTER(ctypes.POINTER(ctypes.c_float)), ctypes.POINTER(ctypes.c_size_t)]
        lib.idfon_voice_turn_free_audio.argtypes = [ctypes.POINTER(ctypes.c_float),
                                                   ctypes.c_size_t]
        lib.rust_free_string.argtypes = [ctypes.c_void_p]
        self.lib = lib
        raw = json.dumps(thresholds).encode() if thresholds else b""
        sess = lib.idfon_voice_turn_new(raw)
        if not sess:
            raise SystemExit(f"{dylib}: idfon_voice_turn_new rejected {raw!r}")
        self.sess = ctypes.c_void_p(sess)

    @staticmethod
    def _f32(x):
        return np.ascontiguousarray(x, np.float32).ctypes.data_as(
            ctypes.POINTER(ctypes.c_float))

    def begin_hop(self, user: np.ndarray, agent: np.ndarray) -> bool:
        n = min(len(user), len(agent))
        return bool(self.lib.idfon_voice_turn_begin_hop(
            self.sess, self._f32(user[:n]), self._f32(agent[:n]), n, MODE.encode()))

    @property
    def prev_state(self) -> int:
        return int(self.lib.idfon_voice_turn_prev_state(self.sess))

    def on_frame(self, out8: np.ndarray, act_db: float, left: int):
        audio = ctypes.POINTER(ctypes.c_float)()
        alen = ctypes.c_size_t()
        p = self.lib.idfon_voice_turn_on_frame(
            self.sess, self._f32(out8), float(act_db), int(left), MODE.encode(),
            ctypes.byref(audio), ctypes.byref(alen))
        if not p:
            return [], False
        body = json.loads(ctypes.string_at(p))
        self.lib.rust_free_string(p)
        if body.get("final") and audio:
            self.lib.idfon_voice_turn_free_audio(audio, alen.value)
        return [e["kind"] for e in body["events"] if e["kind"] != "FRAME"], bool(body.get("reset"))


# --------------------------------------------------------------------------- #
# replay groups and the decision pass
# --------------------------------------------------------------------------- #
@dataclass
class Group:
    index: int
    first_frame: int            # shard frame index of this group's first row
    audio_end: float            # group's audio end on the session clock (s)
    audio_u: np.ndarray         # raw audio the rules' begin_hop sees
    audio_a: np.ndarray
    hu: np.ndarray              # [n, 1024]
    ha: np.ndarray
    act: np.ndarray             # [n]
    enc_s: float                # measured encoder time for this group
    left: list[int] = field(default_factory=list)


@dataclass
class FrameRec:
    i: int                      # 0-based frame index (the shard grid)
    group: int
    audio_end: float            # end of THIS frame's audio (s)
    group_audio_end: float      # end of its hop/chunk's audio (s)
    feature_ready: float
    decision: float
    events: list = field(default_factory=list)


def decide(groups: list[Group], student: Student, rules: Rules):
    """One pass over groups: encode -> (ready) -> step+rules per frame, serial clock."""
    frames: list[FrameRec] = []
    done = 0.0
    student.reset()  # each replay is one call: the carried state starts at zero
    for g in groups:
        ready = max(g.audio_end, done) + g.enc_s
        if rules.begin_hop(g.audio_u, g.audio_a):
            student.reset()
        t = ready
        for k in range(len(g.hu)):
            prev = rules.prev_state          # read before the step, as TurnEngine does
            t0 = now_s()
            out8 = student.step(g.hu[k], g.ha[k], float(g.act[k]), prev)
            kinds, reset = rules.on_frame(out8, float(g.act[k]), g.left[k])
            t += now_s() - t0
            i = g.first_frame + k
            frames.append(FrameRec(i, g.index, (i + 1) * FRAME_SAMPLES / SR,
                                   g.audio_end, ready, t, kinds))
            if reset:
                student.reset()
        done = t
    return frames


def build_windowed(wav_u, wav_a, energy, T, mel_of, enc: WindowedEncoder):
    """Today's path: 4 frames per 320 ms hop, an 8 s (growing) window per hop."""
    groups: list[Group] = []
    n_groups = T // HOP_FRAMES
    for gi in range(n_groups):
        f0 = gi * HOP_FRAMES
        end_sample = (f0 + HOP_FRAMES) * FRAME_SAMPLES
        hist = int(min(WINDOW_S * SR, end_sample))
        wu, wa = wav_u[end_sample - hist:end_sample], wav_a[end_sample - hist:end_sample]
        rows_u, dt_u = enc.encode(mel_of(wu))
        rows_a, dt_a = enc.encode(mel_of(wa))
        groups.append(Group(
            index=gi,
            first_frame=f0,
            audio_end=end_sample / SR,
            audio_u=wu, audio_a=wa,
            hu=rows_u[-HOP_FRAMES:], ha=rows_a[-HOP_FRAMES:],
            act=energy[f0:f0 + HOP_FRAMES],
            enc_s=dt_u + dt_a,
            left=list(range(HOP_FRAMES - 1, -1, -1)),
        ))
    return groups


def build_streaming(wav_u, wav_a, energy, T, mel_u, mel_a,
                    tap_u: StreamingTap, tap_a: StreamingTap):
    """The tap path: one cache-aware call per 560 ms chunk, both ears.

    Grid (measured against the stored shards: cos p05 0.87 at this offset vs
    0.22 at 0): chunk i's 7 rows are shard frames 7i+1 .. 7i+7. The reference
    grid also carries the first chunk's context row, so chunk 0 releases 8 rows
    (frames 0..7, frame 0 duplicated by convention — the ASR has no row 0). The
    call needs the 65-frame mel window (56 new + 9 pre-encode context), i.e.
    90 ms past the chunk's last new mel frame; that is its timestamp.
    """
    groups: list[Group] = []
    n_groups = T // CHUNK_FRAMES
    tap_u.reset()
    tap_a.reset()
    for gi in range(n_groups):
        w0 = gi * CHUNK_MEL
        rows_u, dt_u = tap_u.encode(mel_u[:, w0:w0 + TOTAL_MEL])
        rows_a, dt_a = tap_a.encode(mel_a[:, w0:w0 + TOTAL_MEL])
        if gi == 0:
            f0, n = 0, CHUNK_FRAMES + 1
            hu = np.concatenate([rows_u[:1], rows_u])
            ha = np.concatenate([rows_a[:1], rows_a])
        else:
            f0, n = gi * CHUNK_FRAMES + 1, CHUNK_FRAMES
            hu, ha = rows_u, rows_a
        end_sample = (f0 + n) * FRAME_SAMPLES
        groups.append(Group(
            index=gi,
            first_frame=f0,
            audio_end=(CHUNK_MEL * (gi + 1) + PRE_ENCODE) / 100.0,  # 65/56 mel at 10 ms
            audio_u=wav_u[f0 * FRAME_SAMPLES:end_sample],
            audio_a=wav_a[f0 * FRAME_SAMPLES:end_sample],
            hu=hu, ha=ha,
            act=energy[f0:f0 + n],
            enc_s=dt_u + dt_a,
            left=list(range(n - 1, -1, -1)),
        ))
    return groups


# --------------------------------------------------------------------------- #
# per-frame / hop-gated scoring of the tap rows
# --------------------------------------------------------------------------- #
def group_of_frame(f: int, last_group: int) -> int:
    """The delivery chunk that contains grid frame f (chunk 0 carries 0..7)."""
    return min(0 if f <= CHUNK_FRAMES else (f - 1) // CHUNK_FRAMES, last_group)


def left_value(policy: str, f: int, group_span: dict) -> int:
    """The rules' `left` for frame f under one policy.

    `group_span[f]` is the last frame of f's delivery chunk, so
    `chunk-countdown` is exactly the existing tap pass's range(n-1, -1, -1).
    """
    if policy == "hop-phase":
        return (HOP_FRAMES - 1) - (f % HOP_FRAMES)
    if policy == "zero":
        return 0
    if policy == "chunk-countdown":
        return group_span[f] - f
    raise SystemExit(f"unknown left policy {policy!r}")


def scoring_units(groups, scoring: str):
    """Groups of rows scored together, in frame order, with their release chunk.

    per-frame: one row per unit, released by its own chunk.
    tap-hop:   one 4-row unit, released only when its last row's chunk has been
               encoded (the TurnRuntime.feed lattice).
    """
    frames = [g.first_frame + k for g in groups for k in range(len(g.hu))]
    last = groups[-1].index
    units = []
    if scoring == "per-frame":
        for f in frames:
            units.append({"frames": [f], "begin": [f],
                          "release": group_of_frame(f, last)})
    elif scoring == "tap-hop":
        hops: dict[int, list[int]] = {}
        for f in frames:
            hops.setdefault(f // HOP_FRAMES, []).append(f)
        for h in sorted(hops):
            fs = hops[h]
            end = HOP_FRAMES * (h + 1) - 1
            units.append({"frames": fs,
                          "begin": list(range(HOP_FRAMES * h,
                                               HOP_FRAMES * h + len(fs))),
                          "release": group_of_frame(end, last)})
    else:
        raise SystemExit(f"unknown scoring mode {scoring!r}")
    return units


def decide_flat(groups, wav_u, wav_a, student, rules, scoring: str,
                left_policy: str):
    """Score rows as they are released; one step per row, rules threaded per frame.

    The encode clock is the same one `decide` uses: a chunk's rows exist at
    `max(chunk audio end, previous decision end) + measured encode`. A unit is
    scored when the chunk containing its last row has been encoded; rows are
    stepped in frame order, so `begin_hop` only ever sees audio that has arrived.
    """
    units = scoring_units(groups, scoring)
    row = {g.first_frame + k: (g.hu[k], g.ha[k], float(g.act[k]))
           for g in groups for k in range(len(g.hu))}
    group_span = {g.first_frame + k: g.first_frame + len(g.hu) - 1
                  for g in groups for k in range(len(g.hu))}
    left = {}
    for u in units:
        for j, f in enumerate(u["frames"]):
            left[f] = (len(u["frames"]) - 1 - j if scoring == "tap-hop"
                       else left_value(left_policy, f, group_span))

    frames: list[FrameRec] = []
    student.reset()
    done = 0.0
    ui = 0
    for g in groups:
        ready = max(g.audio_end, done) + g.enc_s
        due = []
        while ui < len(units) and units[ui]["release"] <= g.index:
            due.append(units[ui])
            ui += 1
        for u in due:
            t = max(ready, done)
            b0, b1 = u["begin"][0], u["begin"][-1] + 1
            if rules.begin_hop(wav_u[b0 * FRAME_SAMPLES:b1 * FRAME_SAMPLES],
                               wav_a[b0 * FRAME_SAMPLES:b1 * FRAME_SAMPLES]):
                student.reset()
            for f in u["frames"]:
                hu, ha, act = row[f]
                prev = rules.prev_state
                t0 = now_s()
                out8 = student.step(hu, ha, act, prev)
                kinds, reset = rules.on_frame(out8, act, left[f])
                t += now_s() - t0
                frames.append(FrameRec(f, g.index, (f + 1) * FRAME_SAMPLES / SR,
                                       g.audio_end, ready, t, kinds))
                if reset:
                    student.reset()
            done = t
    return frames


def build_cadence(wav_u, wav_a, energy, T, hu, ha):
    """Control: today's features, released at the streaming chunk boundary.

    Coverage follows the tap grid exactly (8 rows for chunk 0, 7 after), so the
    rules see the same frame sequence on both sides and the only difference is
    when a group's decisions may start. No encode work is charged here: the
    windowed pass's cost is the compared path's, so this is the conservative
    cadence-only delta.
    """
    groups: list[Group] = []
    n_groups = min(T // CHUNK_FRAMES, (len(hu) - 1) // CHUNK_FRAMES)
    for gi in range(n_groups):
        f0 = 0 if gi == 0 else gi * CHUNK_FRAMES + 1
        n = CHUNK_FRAMES + 1 if gi == 0 else CHUNK_FRAMES
        end_sample = (f0 + n) * FRAME_SAMPLES
        groups.append(Group(
            index=gi,
            first_frame=f0,
            audio_end=(CHUNK_MEL * (gi + 1) + PRE_ENCODE) / 100.0,
            audio_u=wav_u[f0 * FRAME_SAMPLES:end_sample],
            audio_a=wav_a[f0 * FRAME_SAMPLES:end_sample],
            hu=hu[f0:f0 + n], ha=ha[f0:f0 + n],
            act=energy[f0:f0 + n],
            enc_s=0.0,
            left=list(range(n - 1, -1, -1)),
        ))
    return groups


# --------------------------------------------------------------------------- #
# event pairing + aggregation (the existing gate's conventions)
# --------------------------------------------------------------------------- #
def events_of(frames: list[FrameRec]):
    return [(f.i + 1, k, f.decision) for f in frames for k in f.events]


def pair(a, b, tol=2):
    """gate.aligned_count's greedy same-kind match within tol frames.

    a, b: [(frame_1based, kind, decision_t)]. Returns (pairs, only_a, only_b).
    Events are matched by frame (= audio timestamp), never by arrival order.
    """
    used, pairs = set(), []
    for ea in a:
        for j, eb in enumerate(b):
            if j not in used and ea[1] == eb[1] and abs(ea[0] - eb[0]) <= tol:
                used.add(j)
                pairs.append((ea, eb))
                break
    return pairs, len(a) - len(pairs), len(b) - len(pairs)


def _pct(delays):
    if not delays:
        return {"p50": None, "p95": None, "max": None}
    return {"p50": round(float(np.percentile(delays, 50)) * 1e3, 1),
            "p95": round(float(np.percentile(delays, 95)) * 1e3, 1),
            "max": round(max(delays) * 1e3, 1)}


def summary(frames, events, path):
    delays = [f.feature_ready - f.audio_end for f in frames]
    return {
        "path": path,
        "frames": len(frames),
        "groups": frames[-1].group + 1 if frames else 0,
        "events": len(events),
        "endpoints": sum(1 for e in events if e[1] == "ENDPOINT"),
        "feature_delay_ms": _pct(delays),
        # frame 0 is the reference grid's chunk-0 context row, not a streaming
        # row; this is the distribution over the tap's own rows.
        "feature_delay_ms_ge1": _pct([f.feature_ready - f.audio_end for f in frames
                                      if f.i >= 1]),
    }


def delta_row(pairs, kind=None):
    ds = [a[2] - b[2] for a, b in pairs if kind is None or a[1] == kind]
    if not ds:
        return {"n": 0, "median_ms": None, "p50_ms": None, "p95_ms": None, "max_ms": None}
    return {"n": len(ds), "median_ms": round(float(np.median(ds)) * 1e3, 1),
            "p50_ms": round(float(np.percentile(ds, 50)) * 1e3, 1),
            "p95_ms": round(float(np.percentile(ds, 95)) * 1e3, 1),
            "max_ms": round(max(ds) * 1e3, 1)}


def aggregate(per_session):
    """harness.py's aggregation: mean of per-session medians; worst = max median."""
    meds = [s["median_ms"] for s in per_session if s["median_ms"] is not None]
    return {
        "sessions": len(meds),
        "mean_of_medians_ms": round(float(np.mean(meds)), 1) if meds else None,
        "worst_session_ms": round(float(max(meds)), 1) if meds else None,
    }


def boundaries(frames):
    """[[group, audio_end_s, feature_ready_s], ...] — the hop/chunk clock."""
    out, seen = [], set()
    for f in frames:
        if f.group not in seen:
            seen.add(f.group)
            out.append([f.group, round(f.group_audio_end, 4), round(f.feature_ready, 4)])
    return out


# --------------------------------------------------------------------------- #
# one session: prepare (processor + today + control) then the tap pass
# --------------------------------------------------------------------------- #
def _mel_of(processor):
    def f(w):
        return processor(np.asarray(w, np.float32), sampling_rate=SR,
                         return_tensors="pt")["input_features"].numpy()
    return f


def prepare(sid, args, enc, processor, student, rules_dylib):
    """Everything that touches the feature processor, before any tap prediction.

    Measured on this host: a tap prediction corrupts later processor calls
    (segfault inside torch's mel front-end), so the two phases must not
    interleave. Both phases are still one process and one clock per path.
    """
    cap = Path(os.path.expanduser(args.captures)) / f"turn-{sid}.wav"
    if not cap.exists():
        raise SystemExit(f"capture not found: {cap}")
    wav_u, wav_a = read_capture(cap)
    T = len(wav_u) // FRAME_SAMPLES
    shard = Path(args.shards) / f"live-turn-{sid}.npz" if args.shards else None
    if shard is not None and shard.exists():
        T = min(T, int(np.load(shard)["energy"].shape[0]))
    if args.limit_frames:
        T = min(T, args.limit_frames)
    energy = frame_energy(wav_u)
    mel_of = _mel_of(processor)

    groups_today = build_windowed(wav_u, wav_a, energy, T, mel_of, enc)
    today = decide(groups_today, student, Rules(rules_dylib, args.thresholds))
    today_enc_ms = float(np.mean([g.enc_s for g in groups_today])) * 1e3
    hu_today = np.concatenate([g.hu for g in groups_today])
    ha_today = np.concatenate([g.ha for g in groups_today])
    groups_ctrl = build_cadence(wav_u, wav_a, energy, T, hu_today, ha_today)
    ctrl = decide(groups_ctrl, student, Rules(rules_dylib, args.thresholds))

    ev_today, ev_ctrl = events_of(today), events_of(ctrl)
    ctrl_frames = (groups_ctrl[-1].first_frame + len(groups_ctrl[-1].hu) - 1) \
        if groups_ctrl else 0
    assert [(e[0], e[1]) for e in ev_ctrl] == \
        [(e[0], e[1]) for e in ev_today if e[0] <= ctrl_frames], \
        "cadence control changed the event sequence (same features must decide alike)"

    mel_u, mel_a = mel_of(wav_u), mel_of(wav_a)

    verify = None
    ref_l4 = None
    if args.verify and shard is not None and shard.exists():
        z = np.load(shard)
        ref = z["hu_l4"] if "hu_l4" in z.files else None
        ref_l4 = ref
        if ref is not None:
            n = min(len(ref), len(hu_today))
            a, b = ref[:n].astype(np.float64), hu_today[:n].astype(np.float64)
            cos = (a * b).sum(1) / np.maximum(np.linalg.norm(a, axis=1) *
                                              np.linalg.norm(b, axis=1), 1e-12)
            rel = np.linalg.norm(a - b, axis=1) / np.maximum(np.linalg.norm(b, axis=1), 1e-12)
            verify = {"frames": n, "cos_p50": round(float(np.median(cos)), 6),
                      "cos_p05": round(float(np.percentile(cos, 5)), 6),
                      "relL2_p50": round(float(np.median(rel)), 5)}
    return {"session": sid, "T": T, "wav_u": wav_u, "wav_a": wav_a, "energy": energy,
            "hu_today": hu_today, "ha_today": ha_today, "mel_u": mel_u, "mel_a": mel_a,
            "today": today, "ctrl": ctrl, "ev_today": ev_today, "ev_ctrl": ev_ctrl,
            "today_enc_ms": today_enc_ms, "verify": verify, "ref_l4": ref_l4}


def tap_pass(prep, args, tap_u, tap_a, student, rules_dylib):
    """The streaming tap path (no processor calls in this phase)."""
    groups = build_streaming(prep["wav_u"], prep["wav_a"], prep["energy"], prep["T"],
                             prep["mel_u"], prep["mel_a"], tap_u, tap_a)
    if prep["verify"] is not None:
        # The timestamps rest on the row grid: chunk i's rows are shard frames
        # 7i+1..7i+7. Check it against the stored windowed L4 rows.
        rows = np.concatenate([g.hu for g in groups])
        ref = prep["ref_l4"]
        n = min(len(rows), len(ref))
        grid = {}
        for off in (-1, 0, 1):
            a = rows[max(0, off):n + min(0, off)].astype(np.float64)
            b = ref[max(0, -off):n - max(0, off)].astype(np.float64)
            m = min(len(a), len(b))
            a, b = a[:m], b[:m]
            cos = (a * b).sum(1) / np.maximum(np.linalg.norm(a, axis=1) *
                                              np.linalg.norm(b, axis=1), 1e-12)
            # ref row = tap row + shift (off=-1 => tap[r] vs ref[r+1])
            grid[f"ref=tap{-off:+d}"] = [round(float(np.median(cos)), 4),
                                          round(float(np.percentile(cos, 5)), 4)]
        prep["verify"] = dict(prep["verify"], tap_grid_cos_p50_p05=grid)
    variants = {}
    if "chunk" in args.scoring:
        variants["chunk"] = decide(groups, student, Rules(rules_dylib, args.thresholds))
    if "per-frame" in args.scoring:
        for pol in args.left_policies:
            variants[f"per-frame/{pol}"] = decide_flat(
                groups, prep["wav_u"], prep["wav_a"], student,
                Rules(rules_dylib, args.thresholds), "per-frame", pol)
    if "tap-hop" in args.scoring:
        variants["tap-hop"] = decide_flat(
            groups, prep["wav_u"], prep["wav_a"], student,
            Rules(rules_dylib, args.thresholds), "tap-hop", "hop-phase")
    return groups, variants, float(np.mean([g.enc_s for g in groups])) * 1e3


def assemble(prep, groups, variants, tap_enc_ms):
    ev_today = prep["ev_today"]
    p_ctrl, _, _ = pair(prep["ev_ctrl"], ev_today)

    def per_session(pairs):
        return {"endpoint": delta_row(pairs, "ENDPOINT"), "all": delta_row(pairs)}

    paths = {}
    for name, frames in variants.items():
        ev = events_of(frames)
        pairs, only_this, only_today = pair(ev, ev_today)
        paths[name] = {
            "summary": summary(frames, ev, name),
            "paired_vs_today": per_session(pairs),
            "endpoint_deltas_ms": [round((a[2] - b[2]) * 1e3, 1)
                                   for a, b in pairs if a[1] == "ENDPOINT"],
            "matched": len(pairs), "only_this": only_this, "only_today": only_today,
            "backlog_max_ms": round(max((f.feature_ready - f.group_audio_end
                                         for f in frames), default=0.0) * 1e3, 1),
            "backlog_end_ms": round((frames[-1].feature_ready - frames[-1].group_audio_end)
                                    * 1e3, 1) if frames else None,
            "events": [[e[0], e[1], round(e[2], 4)] for e in ev],
        }

    # `left` must be invisible to the decisions. If a policy changes an event
    # frame or kind, this is the finding - not a number to average.
    per_frame = [n for n in paths if n.startswith("per-frame/")]
    if len(per_frame) > 1:
        base = [(e[0], e[1]) for e in paths[per_frame[0]]["events"]]
        for n in per_frame[1:]:
            assert [(e[0], e[1]) for e in paths[n]["events"]] == base, \
                f"left policy {n} changed the event sequence"

    backlog_today = [f.feature_ready - f.group_audio_end for f in prep["today"]]
    tap_groups = boundaries(list(variants.values())[0]) if variants else []
    ref = (paths.get("chunk") or paths.get("per-frame/hop-phase")
           or next(iter(paths.values())))
    return {
        "session": prep["session"],
        "frames": prep["T"],
        "today": summary(prep["today"], ev_today, "today"),
        "cadence": summary(prep["ctrl"], prep["ev_ctrl"], "cadence"),
        "tap": ref["summary"],
        "paths": paths,
        "paired": {
            "cadence_vs_today": per_session(p_ctrl),
            "matched": len(pair(prep["ev_ctrl"], ev_today)[0]),
        },
        "backlog_ms": {
            "today_max": round(max(backlog_today) * 1e3, 1) if backlog_today else None,
        },
        "encode_ms": {
            "today_mean_hop": round(prep["today_enc_ms"], 1),
            "tap_mean_chunk": round(tap_enc_ms, 1),
        },
        "verify": prep["verify"],
        "raw": {
            "today_groups": boundaries(prep["today"]),
            "tap_groups": tap_groups,
            "today_events": [[e[0], e[1], round(e[2], 4)] for e in ev_today],
        },
    }


def frac_over(recs, name, ms):
    """Share of matched endpoints whose tap decision is > ms past today's."""
    xs = [d for r in recs for d in r["paths"][name]["endpoint_deltas_ms"]]
    return {"n": len(xs), "above": sum(1 for d in xs if d > ms),
            "frac": (sum(1 for d in xs if d > ms) / len(xs)) if xs else 0.0}


def manager_shifts(path):
    """Per-session p50 of the paced probe's `measured - offline` (the #174 shift)."""
    p = Path(path) if path else None
    if p is None or not p.exists():
        return {}
    doc = json.loads(p.read_text())
    out = {}
    for s in doc.get("sessions", []):
        if s.get("mode") == "paced" and s.get("vs_offline_ms", {}).get("p50") is not None:
            out[s["session"]] = float(s["vs_offline_ms"]["p50"])
    return out


# --------------------------------------------------------------------------- #
# selfcheck + report
# --------------------------------------------------------------------------- #
def selfcheck():
    # scheduling: ready is never before the group's audio
    g = Group(0, 0, 0.32, np.zeros(0, np.float32), np.zeros(0, np.float32),
              np.zeros((4, 1024), np.float32), np.zeros((4, 1024), np.float32),
              np.zeros(4, np.float32), 0.01)
    assert max(g.audio_end, 0.0) + g.enc_s >= g.audio_end
    # pairing: same kind within tol, aligned by frame not arrival order
    a = [(10, "ENDPOINT", 1.0), (100, "BACKCHANNEL", 2.0)]
    b = [(11, "ENDPOINT", 0.6), (101, "BACKCHANNEL", 1.9), (200, "ENDPOINT", 5.0)]
    pairs, only_a, only_b = pair(a, b)
    assert [(x[0], y[0]) for x, y in pairs] == [(10, 11), (100, 101)]
    assert (only_a, only_b) == (0, 1)
    # aggregation is mean of per-session medians, worst = max
    agg = aggregate([{"median_ms": 100.0}, {"median_ms": 300.0}])
    assert agg == {"sessions": 2, "mean_of_medians_ms": 200.0, "worst_session_ms": 300.0}
    # frame/group maps: 7 frames per chunk, chunk end on the 80 ms grid
    assert CHUNK_FRAMES * FRAME_SAMPLES / SR == 0.56
    # left values: today's sequence, zero, and the delivery-chunk countdown
    assert [left_value("hop-phase", f, {}) for f in range(9)] == [3, 2, 1, 0] * 2 + [3]
    assert [left_value("zero", f, {}) for f in range(9)] == [0] * 9
    span = {f: (7 if f <= 7 else 7 + 7 * ((f - 8) // 7 + 1)) for f in range(23)}
    assert [left_value("chunk-countdown", f, span) for f in (0, 7, 8, 14, 15)] == [7, 0, 6, 0, 6]
    # delivery chunks and hop straddles: chunk 4 is frames 29..35, so the hop
    # ending at 31 waits for it; hop 8 (32..35) does not straddle.
    assert [group_of_frame(f, 99) for f in (0, 7, 8, 14, 15, 29, 35, 36)] == \
        [0, 0, 1, 1, 2, 4, 4, 5]
    assert group_of_frame(31, 99) == 4 and group_of_frame(35, 99) == 4
    assert group_of_frame(28, 99) == 3 and group_of_frame(32, 99) == 4

    def fake_groups(n):
        out = []
        for gi in range(n):
            f0, k = (0, CHUNK_FRAMES + 1) if gi == 0 else (CHUNK_FRAMES * gi + 1,
                                                           CHUNK_FRAMES)
            out.append(Group(gi, f0, 0.0, np.zeros(0, np.float32), np.zeros(0, np.float32),
                             np.zeros((k, 1), np.float32), np.zeros((k, 1), np.float32),
                             np.zeros(k, np.float32), 0.0))
        return out
    gs = fake_groups(8)
    pf = scoring_units(gs, "per-frame")
    th = {u["frames"][0]: u for u in scoring_units(gs, "tap-hop")}
    assert len(pf) == sum(len(g.hu) for g in gs)
    assert pf[12]["release"] == 1 and pf[28]["release"] == 3
    # hop 3 (12..15) waits for chunk 2; hop 4 (16..19) is already in chunk 2;
    # hop 7 (28..31) waits for chunk 4 while row 28's own chunk is 3.
    assert th[12]["release"] == 2 and th[16]["release"] == 2
    assert th[28]["release"] == 4 and pf[28]["release"] == 3
    print("selfcheck: scheduling, pairing, aggregation, left policies, chunk grid, "
          "scoring units OK")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--sessions", default=",".join(DEFAULT_SESSIONS),
                    help="live capture ids (turn-<id>.wav), comma separated")
    ap.add_argument("--captures", default="~/Library/Application Support/Idfon/turn-captures")
    ap.add_argument("--shards", default="bench-results/live-shipping",
                    help="live-shipping shards (frame counts + optional feature check)")
    ap.add_argument("--tap-artifact",
                    default="bench-results/asr-tap/encoder_tap_fp16_int8w.mlpackage",
                    help="reference-pass (56/0) streaming tap artifact")
    ap.add_argument("--windowed-dir", default="bench-results/coreml-l4")
    ap.add_argument("--step", default="bench-results/student-l4-coreml/StudentStep.mlpackage")
    ap.add_argument("--rules-dylib", default="mac/Vendor/libiroh_c_ffi.dylib")
    ap.add_argument("--thresholds", default=None,
                    help="JSON rules thresholds (default: the ABI's bundle defaults)")
    ap.add_argument("--scoring", default="chunk,per-frame,tap-hop",
                    help=f"tap scoring modes to run: {', '.join(SCORINGS)}")
    ap.add_argument("--left-policies", default=",".join(LEFT_POLICIES),
                    help=f"per-frame `left` policies: {', '.join(LEFT_POLICIES)}")
    ap.add_argument("--manager-probe", default="bench-results/asr-manager-probe/paced.json",
                    help="paced probe JSON; its per-frame `measured - offline` p50 is "
                         "added to the endpoint medians (the uniform shift #174 measured)")
    ap.add_argument("--verify", action="store_true",
                    help="check replayed windowed L4 rows against the shard's hu_l4")
    ap.add_argument("--limit-frames", type=int, default=0, help="debug: first N frames only")
    ap.add_argument("--out", default=None, help="write the full record (JSON) here")
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args()

    if args.selfcheck:
        selfcheck()
        return
    args.scoring = [s.strip() for s in args.scoring.split(",") if s.strip()]
    args.left_policies = [s.strip() for s in args.left_policies.split(",") if s.strip()]
    for s in args.scoring:
        if s not in SCORINGS:
            raise SystemExit(f"unknown scoring mode {s!r}")
    for p in args.left_policies:
        if p not in LEFT_POLICIES:
            raise SystemExit(f"unknown left policy {p!r}")
    if not args.scoring:
        raise SystemExit("no scoring modes selected")

    from transformers import AutoProcessor
    processor = AutoProcessor.from_pretrained("nvidia/nemotron-3.5-asr-streaming-0.6b")
    enc = WindowedEncoder(Path(args.windowed_dir))
    # Load the step before any prediction: coremltools' get_spec() deepcopy segfaults
    # once the big artifacts have served predictions (measured on this host).
    student = Student(Path(args.step))
    enc.fixed.predict({"feats": np.zeros((1, 801, 128), np.float16)})
    enc.dyn.predict({"feats": np.zeros((1, 801, 128), np.float32)})

    # Phase 1: every processor call and both windowed passes, before the tap
    # artifact predicts (a tap prediction makes later mel calls segfault here).
    preps = []
    for sid in [s.strip() for s in args.sessions.split(",") if s.strip()]:
        preps.append(prepare(sid, args, enc, processor, student, Path(args.rules_dylib)))

    # Phase 2: the streaming tap path.
    tap_u = StreamingTap(Path(args.tap_artifact))
    tap_a = StreamingTap(Path(args.tap_artifact))
    one = np.zeros((1, TOTAL_MEL, 128), np.float32)
    for tap in (tap_u, tap_a):
        tap.encode(one)
        tap.reset()

    recs = []
    for prep in preps:
        print(f"\n== {prep['session']}", flush=True)
        groups, variants, tap_enc_ms = tap_pass(prep, args, tap_u, tap_a, student,
                                               Path(args.rules_dylib))
        rec = assemble(prep, groups, variants, tap_enc_ms)
        recs.append(rec)
        for name, s in (("today", rec["today"]), ("cadence", rec["cadence"])):
            d = s["feature_delay_ms"]
            print(f"  {name:<8} {s['frames']:5d} frames {s['groups']:4d} groups "
                  f"{s['events']:3d} events ({s['endpoints']:2d} ep)  feature delay "
                  f"p50 {d['p50']:7.1f}  p95 {d['p95']:7.1f}  max {d['max']:7.1f} ms")
        for name, p in rec["paths"].items():
            s, e = p["summary"], p["paired_vs_today"]["endpoint"]
            print(f"  {name:<22} {s['frames']:5d} frames {s['groups']:4d} groups "
                  f"{s['events']:3d} events ({s['endpoints']:2d} ep)  vs today "
                  f"n={e['n']:2d} median {e['median_ms']} p95 {e['p95_ms']} "
                  f"max {e['max_ms']} ms  backlog {p['backlog_max_ms']} ms"
                  f" (end {p['backlog_end_ms']})")
        print(f"  feature delay tap p50 {rec['tap']['feature_delay_ms']['p50']} "
              f"p95 {rec['tap']['feature_delay_ms']['p95']} ms  |  encode/hop "
              f"{rec['encode_ms']['today_mean_hop']} ms  encode/chunk "
              f"{rec['encode_ms']['tap_mean_chunk']} ms")
        if rec["verify"]:
            print(f"  verify  windowed L4 vs shard hu_l4: cos p50 {rec['verify']['cos_p50']} "
                  f"p05 {rec['verify']['cos_p05']}  relL2 p50 {rec['verify']['relL2_p50']}")

    print("\n== aggregate (harness.py: mean of per-session medians; worst = max)")
    names = list(recs[0]["paths"]) if recs else []
    shifts = manager_shifts(args.manager_probe)
    for name in names:
        eps = [r["paths"][name]["paired_vs_today"]["endpoint"] for r in recs]
        agg = aggregate([{"median_ms": e["median_ms"]} for e in eps])
        over = frac_over(recs, name, 320.0)
        print(f"  {name:<22} endpoints n={sum(e['n'] for e in eps):2d}  "
              f"mean-of-medians {agg['mean_of_medians_ms']} ms  "
              f"worst session {agg['worst_session_ms']} ms  "
              f"past +320 {over['above']}/{over['n']} ({over['frac']:.0%})")
        if shifts:
            shifted = aggregate([{"median_ms": (
                r["paths"][name]["paired_vs_today"]["endpoint"]["median_ms"] or 0.0)
                + shifts.get(r["session"], 0.0)} for r in recs])
            print(f"  {'  + manager shift':<22} mean-of-medians "
                  f"{shifted['mean_of_medians_ms']} ms  worst session "
                  f"{shifted['worst_session_ms']} ms  "
                  f"(per-session p50 {', '.join(f'{s:+.1f}' for s in shifts.values())})")
    print("  (bar +160 mean-of-medians, +320 worst session)")

    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(
            {"sessions": recs, "manager_p50_ms": shifts,
             "scoring": args.scoring, "left_policies": args.left_policies}, indent=1))
        print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
