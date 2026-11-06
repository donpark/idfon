"""Does the silent playback ear have to be encoded? Three arms, one audio set (#132).

The upstream shape passes zeros for the second ear while the agent is not speaking.
Ours encodes the real silence, and in a streaming pass silence is not a fixed point
(`batched_ears.py`: ~41 chunks / 13.1 s to converge; reusing a stale result costs
cos 0.871). "Cache the silent encode" is therefore dead; this prices the other
move — not asking for it:

  A  baseline        `ha` from a continuous cache-aware pass over the playback
                     channel, exactly the rows the `l4-streaming` student was
                     fitted on (re-generated here from the audio, one code path)
  B  mask-only       A with `ha = 0` on frames the playback channel says are
                     confidently inaudible (-60 dB); every other frame untouched.
                     A representation test: the encoder still ran and advanced its
                     caches. It is NOT evidence that skipping is safe.
  C  skip            the playback encode is genuinely not called on chunks whose
                     frames are all inaudible; those frames get zeros. Two explicit
                     state policies for the gap:
                       freeze  keep the pre-gap caches (no call, no advance)
                       reset   drop them (cache_len = 1, a cold restart)
                     "advance" is not a policy: advancing a cache IS an encode.
                 D-hold is a DIAGNOSTIC, not an arm: C's cache trajectory with the
                 last pre-gap feature repeated through the gap instead of zeros.
                 It separates "the fill is wrong" from "the cache is stale".

The decision model is the deployed fp32 `l4-streaming` student, its own fitted
traits per domain, unchanged rules thresholds, per-frame scoring. Each arm carries
its own GRU hidden state, its own rules session and its own resets — `prev_state`
is never pinned to a recorded value. Nothing is refitted; no app, fork, rule or
threshold changes.

Scoring tier is 560 ms (the tier the deployed adapter was fitted on). A 320 ms
decision pass would need the 320 refit (#132, no refit allowed here), so 320 is
priced in the economics section, not decided on.

Reported per interval class, never pooled: silent interiors, playback starts,
playback stops, audible overlap (both channels voiced), audible-agent-alone, and
quiet negatives (both silent, floor listening). Classes are memberships, not a
partition — a playback start that is also overlap is the barge case. The `_win`
rows dilute the 1-frame start/stop transition by +/-3 frames (a 640 ms window),
where a debounced rules event can actually land.

    .venv/bin/python ports/tyger-student/ha_ablation.py --selfcheck
    .venv/bin/python ports/tyger-student/ha_ablation.py --run \
        --out bench-results/ha-ablation.json

`--pin` regenerates arm A for one session and compares it with the stored rows
(corpus: the streaming rows the student trained on; live: the recorded windowed
cut rows, at the published +1-row parity).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gate import aligned_count, student_events  # noqa: E402
from harness import ScoreTap, bc_score, barge_sweep, floor_series, sweep  # noqa: E402
from mode_track import VAD_DB, frame_modes  # noqa: E402
from tap_gate import kind_report, match_pairs  # noqa: E402
from tap_latency import frame_energy, read_capture  # noqa: E402

SR = 16_000
FRAME_S = 0.08
CHUNK_MEL = 56
PRE_ENCODE = 9
CHUNK_FRAMES = 7              # 560 ms tier: 7 new rows per call (the student's grid)
TOTAL_MEL = CHUNK_MEL + PRE_ENCODE
INAUDIBLE_DB = -60.0          # "confidently inaudible": below the rules' VAD (-50) and
                              # below the -80 dB dither floor these captures show in pauses
MODEL = "nvidia/nemotron-3.5-asr-streaming-0.6b"
ARTIFACT_560 = "bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage"
ARTIFACT_320 = "bench-results/asr-tap-320/encoder_tap_42-13_320ms_fp16_int8w.mlpackage"
PREFIX_B1 = "bench-results/asr-prefix-320/encoder_tap_42-13_320ms_fp16_int8w_l4b1.mlpackage"
PREFIX_B2 = "bench-results/asr-prefix-320/encoder_tap_42-13_320ms_fp16_int8w_l4b2.mlpackage"
STUDENT = "bench-results/shared-shipping-refit-fixed/student.pt"
TAP = "l4-streaming"
LIVE_SHARDS = "bench-results/live-shipping"          # windowed cut rows (A-pin only)
LIVE_WAVS = "~/Library/Application Support/Idfon/turn-captures"
CORPUS_SHARDS = "bench-results/tap-shipping-fixed/val"  # streaming rows (A-pin)
CORPUS_WAVS = "bench-results/asr-tap/wav"
TRAITS = {"live": "live.traits.json", "corpus": "corpus.traits.json"}
CLASSES = ("silent_interior", "playback_start", "playback_stop",
           "playback_start_win", "playback_stop_win", "audible_overlap",
           "audible_agent", "quiet_negative")
PROB_COLS = (("barge", 5), ("backchannel", 6), ("endpoint", 7))
ARMS = ("A", "B", "C-freeze", "C-reset", "D-hold")


# --------------------------------------------------------------------------- #
# the feature generator (arm A and arm C)
# --------------------------------------------------------------------------- #
def fresh_caches(depth=42, layers=24):
    return (np.zeros((1, layers, depth, 1024), np.float32),
            np.zeros((1, layers, 1024, 8), np.float32), 1)


def stream_rows(mel, encode, skip=frozenset(), policy="freeze"):
    """One continuous cache-aware pass over a mel [1,128,M] -> (rows [T,1024], calls).

    `encode(mel_window, caches) -> (rows [7,1024], caches)` is the artifact call.
    Chunks in `skip` are not encoded: their 7 rows are zeros, and the caches either
    stay where they were (`freeze`) or are dropped (`reset`). Row 0 of the returned
    stream is the stored grid's duplicated context row, so chunk k's rows land at
    [1+7k, 8+7k) — the mapping `pass_gate.py` emits and `playback_ear.py` measured.
    """
    assert policy in ("freeze", "reset")
    caches = fresh_caches()
    rows, calls = [], 0
    for k, end in enumerate(range(PRE_ENCODE + CHUNK_MEL, mel.shape[2] + 1, CHUNK_MEL)):
        if k in skip:
            rows.append(np.zeros((CHUNK_FRAMES, 1024), np.float32))
            if policy == "reset":
                caches = fresh_caches()
            continue
        out, caches = encode(mel[:, :, end - TOTAL_MEL:end], caches)
        rows.append(out)
        calls += 1
    tap = np.concatenate(rows) if rows else np.zeros((0, 1024), np.float32)
    return np.concatenate([tap[:1], tap]), calls


def skip_chunks(agent_db, n_chunks, hop_frames=CHUNK_FRAMES, thr=INAUDIBLE_DB):
    """Chunk indices whose every frame is confidently inaudible."""
    return frozenset(k for k in range(n_chunks)
                     if np.all(np.asarray(agent_db)[k * hop_frames:
                                                      (k + 1) * hop_frames] <= thr))


def hold_fill(ha, agent_db, n_chunks, hop_frames=CHUNK_FRAMES,
              thr=INAUDIBLE_DB):
    """Fill each skipped chunk with the last feature of the previous kept chunk."""
    out = ha.copy()
    last = None
    for k in range(n_chunks):
        sl = slice(1 + k * hop_frames, 1 + (k + 1) * hop_frames)
        silent = np.all(np.asarray(agent_db)[k * hop_frames:(k + 1) * hop_frames] <= thr)
        if silent:
            out[sl] = last if last is not None else ha[sl.start]
        else:
            last = ha[sl.stop - 1]
    return out


# --------------------------------------------------------------------------- #
# the artifact wrapper
# --------------------------------------------------------------------------- #
class TapArtifact:
    def __init__(self, path, batch=1):
        import coremltools as ct
        self.model = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_AND_NE)
        d = self.model.get_spec().description
        self.mel_len = int(d.input[0].type.multiArrayType.shape[2])
        self.batch = int(d.input[0].type.multiArrayType.shape[0])
        self.layers = int(d.input[2].type.multiArrayType.shape[1])
        self.depth = int(d.input[2].type.multiArrayType.shape[2])
        self.keep = (self.mel_len - PRE_ENCODE) // 8

    def caches(self):
        return (np.zeros((self.batch, self.layers, self.depth, 1024), np.float32),
                np.zeros((self.batch, self.layers, 1024, 8), np.float32),
                np.ones(self.batch, np.int32))

    def encode(self, window, caches):
        ch, cht, cl = caches
        out = self.model.predict({
            "mel": np.ascontiguousarray(window, np.float32),
            "mel_length": np.full(self.batch, self.mel_len, np.int32),
            "cache_channel": ch, "cache_time": cht,
            "cache_len": np.asarray(cl, np.int32).reshape(self.batch),
            "prompt_id": np.full(self.batch, 101, np.int32),
        })
        return (np.asarray(out["tap_l4"], np.float32).transpose(0, 2, 1)[0],
                (out["cache_channel_out"], out["cache_time_out"],
                 np.asarray(out["cache_len_out"], np.int32)))


def model_of(path):
    from checkpoint import TempScaled, load
    return load(path, tap=TAP)[0], TempScaled


# --------------------------------------------------------------------------- #
# session loading
# --------------------------------------------------------------------------- #
def live_session(sid, shard_dir, wav_dir):
    shard = Path(shard_dir) / f"live-turn-{sid}.npz"
    z = np.load(shard)
    u, a = read_capture(Path(os.path.expanduser(wav_dir)) / f"turn-{sid}.wav")
    return z, u, a, None


def corpus_session(sid, shard_dir, wav_dir):
    z = np.load(Path(shard_dir) / f"{sid}.npz")
    u = np.load(Path(wav_dir) / f"{sid}.npy")
    a = np.load(Path(wav_dir) / f"{sid}-ch1.npy")
    labels = {k[len("lab_"):]: z[k] for k in z.files if k.startswith("lab_")}
    return z, u, a, labels


def intervals(agent_db, mic_db, modes, thr=INAUDIBLE_DB):
    """Per-frame memberships (booleans). Sets, not a partition: a playback start
    that is also overlap is exactly the barge case and must stay visible as both."""
    a = np.asarray(agent_db, np.float64)
    m = np.asarray(mic_db, np.float64)
    audible = a > thr
    prev_a = np.r_[False, audible[:-1]]   # a file edge is not a transition
    next_a = np.r_[audible[1:], False]
    silent = ~audible
    start = audible & ~prev_a
    stop = silent & prev_a

    def win(mask, h=3):
        return np.convolve(mask.astype(np.int8), np.ones(2 * h + 1, np.int8),
                           "same") > 0

    return {
        "silent_interior": silent & ~prev_a & ~next_a,
        "playback_start": start,
        "playback_stop": stop,
        "playback_start_win": win(start),
        "playback_stop_win": win(stop),
        "audible_overlap": (a > VAD_DB) & (m > VAD_DB),
        "audible_agent": audible,
        "quiet_negative": silent & (m <= VAD_DB) & (np.asarray(modes) == "listen"),
    }


def reference_events(vecs, energy, modes, oracle, thr):
    """The teacher side of the same session, replayed with the same mode track and
    its own rules state (the shard's ev_* predate the mode fix on some captures)."""
    sess = oracle.EarsSession(0, ep_thr=thr["endpoint"], barge_thr=thr["barge"],
                              bc_thr=thr["backchannel"])
    last, events = None, []
    for f in range(len(vecs)):
        mode = str(modes[f])
        if mode != last:
            oracle.rules.switch_mode(sess, mode)
            last = mode
        evs, _final, _reset = oracle.rules.on_frame(
            sess, mode, vecs[f], float(energy[f]), left=3 - (f % 4))
        events.extend((f + 1, e["kind"]) for e in evs if e["kind"] != "FRAME")
    return events


# --------------------------------------------------------------------------- #
# scoring
# --------------------------------------------------------------------------- #
def replay(model, oracle, frames, thr, deb):
    tap = ScoreTap(model)
    t = (thr["endpoint"], thr["barge"], thr["backchannel"])
    ev = student_events(tap, oracle, frames, layer=4, thr=t, deb=deb)
    return np.stack(tap.scores), ev


def diff_events(ev_a, ev_b, tol=2):
    pairs, only_a, only_b = match_pairs(ev_a, ev_b, tol)
    delta = {(fa, ka): fb - fa for fa, ka, fb in pairs}
    return pairs, only_a, only_b, delta


def class_report(cls_masks, scores, events, arms, scores_a, events_a, thr):
    """Per interval class: probability shift, raw threshold crossings, event deltas."""
    out = {}
    for arm in arms:
        ev, s = events[arm], scores[arm]
        pairs, _only_a, _only_b, delta = diff_events(events_a, ev, 2)
        matched_a = {fa for fa, _k, _fb in pairs}
        matched_b = {fb for _fa, _k, fb in pairs}
        row = {}
        for name, mask in cls_masks.items():
            n = int(mask.sum())
            if not n:
                row[name] = {"frames": 0}
                continue
            cell = {"frames": n}
            for head, col in PROB_COLS:
                d = s[mask, col] - scores_a[mask, col]
                t = thr[head]
                fire_a = scores_a[mask, col] >= t
                fire_b = s[mask, col] >= t
                cell[head] = {
                    "a_mean": round(float(scores_a[mask, col].mean()), 4),
                    "b_mean": round(float(s[mask, col].mean()), 4),
                    "d_mean": round(float(d.mean()), 5),
                    "d_p95abs": round(float(np.percentile(np.abs(d), 95)), 5),
                    "d_maxabs": round(float(np.abs(d).max()), 5),
                    "added": int((fire_b & ~fire_a).sum()),
                    "lost": int((fire_a & ~fire_b).sum()),
                    "fires_a": int(fire_a.sum()), "fires_b": int(fire_b.sum())}
            shifted = [d for (fa, _k), d in delta.items() if mask[fa - 1] and d != 0]
            added = [k for f, k in ev if mask[f - 1] and f not in matched_b]
            lost = [k for f, k in events_a if mask[f - 1] and f not in matched_a]
            cell["added_by_kind"] = {k: added.count(k) for k in sorted(set(added))}
            cell["lost_by_kind"] = {k: lost.count(k) for k in sorted(set(lost))}
            cell["events"] = {
                "a": sum(1 for f, _k in events_a if mask[f - 1]),
                "b": sum(1 for f, _k in ev if mask[f - 1]),
                "only_a": sum(1 for f, _k in events_a if mask[f - 1] and f not in matched_a),
                "only_b": sum(1 for f, _k in ev if mask[f - 1] and f not in matched_b),
                "shifted": len(shifted),
                "shifted_earlier": sum(1 for d in shifted if d < 0),
                "shifted_later": sum(1 for d in shifted if d > 0)}
            row[name] = cell
        out[arm] = row
    return out


def product_metrics(events, scores, labels, thr):
    """harness.py's product axes for one arm (corpus only: it has the labels)."""
    T = len(scores)
    eot_s = (np.flatnonzero(labels["eot_ch0"]) * FRAME_S).tolist()
    bc_frames = np.flatnonzero(labels["bc_ch0"])
    floor = floor_series(labels, T)
    bot_int = np.flatnonzero((labels["bot_ch0"] == 1) & (np.r_[0, floor[:-1]] == 2))
    lat, early, miss = sweep([f * FRAME_S for f in
                              [int(f) - 1 for f, k in events if k == "ENDPOINT"]], eot_s)
    return {"endpoint": {"lat_med": round(float(np.median(lat)), 3) if lat else None,
                         "early": early, "miss": miss},
            "barge": barge_sweep(scores[:, 5] >= thr["barge"], bot_int),
            "bc": bc_score([int(f) - 1 for f, k in events if k == "BACKCHANNEL"],
                           bc_frames) if len(bc_frames) else None}


# --------------------------------------------------------------------------- #
# the run
# --------------------------------------------------------------------------- #
def sessions(domain, live_dir, live_wavs, corpus_dir, corpus_wavs):
    if domain == "live":
        for p in sorted(Path(live_dir).glob("*.npz")):
            yield p.stem.replace("live-turn-", ""), live_session
        return
    for p in sorted(Path(corpus_dir).glob("*.npz")):
        yield p.stem, corpus_session


def load_traits(checkpoint, domain):
    d = json.loads((Path(checkpoint).parent / TRAITS[domain]).read_text())
    dec = d["decider"]
    thr = {"endpoint": dec["ep_thr"], "barge": dec["barge_thr"],
           "backchannel": dec["bc_thr"]}
    deb = (dec["ep_deb"], dec["barge_deb"], dec["bc_deb"])
    return d, thr, deb


def run(args):
    from transformers import AutoProcessor

    from oracle import Oracle
    oracle = Oracle(device="cpu")
    proc = AutoProcessor.from_pretrained(MODEL)
    art = TapArtifact(args.artifact)
    assert art.mel_len == TOTAL_MEL and art.keep == CHUNK_FRAMES, art.keep

    load, TempScaled = model_of(args.student)
    rec, per_domain, pin = {}, {}, {}
    t_start = time.time()

    for domain, shard_dir, wav_dir in (("live", args.live_shards, args.live_wavs),
                                       ("corpus", args.corpus_shards, args.corpus_wavs)):
        traits, thr, deb = load_traits(args.student, domain)
        model = TempScaled(load, traits["temperature"])
        print(f"\n== {domain}: student {args.student} tap {TAP}, temp "
              f"{traits['temperature']}, thresholds ep/barge/bc "
              f"{thr['endpoint']}/{thr['barge']}/{thr['backchannel']}, debounce {deb}",
              flush=True)
        # phase 1: every mel and every label, before the first prediction (a tap
        # prediction corrupts later processor calls on this host)
        items = []
        for sid, loader in sessions(domain, args.live_shards, args.live_wavs,
                                    args.corpus_shards, args.corpus_wavs):
            if args.sessions and len(items) >= args.sessions:
                break
            z, u, a, labels = loader(sid, shard_dir, wav_dir)
            T = int(z["energy"].shape[0])
            mels = [proc(np.asarray(w, np.float32), sampling_rate=SR,
                         return_tensors="pt")["input_features"].numpy().transpose(0, 2, 1)
                    for w in (u, a)]
            items.append({"sid": sid, "z": z, "labels": labels, "T": T, "mels": mels,
                          "mic_db": frame_energy(u)[:T], "agent_db": frame_energy(a)[:T],
                          "stored": (z["hu_l4"], z["ha_l4"]) if "ha_l4" in z.files
                                    else (z["hu"], z["ha"])})
            print(f"  mel {sid[:24]}… {T} frames", flush=True)
        print(f"  phase 1: {len(items)} session(s) mel'd in {time.time() - t_start:.0f}s",
              flush=True)

        rows = []
        for it in items:
            sid, z, T, labels = it["sid"], it["z"], it["T"], it["labels"]
            # The floor: live captures derive it from ch1 (mode_track.py — the app proxy,
            # the only way a BARGE can fire). Corpus shards carry no mode track and their
            # recorded events are listen-mode; deriving a speaking floor there would put
            # the rules in the barge branch and suppress endpoint/backchannel, silently
            # replacing the 316-event reference `gate.py` scores against.
            modes = (np.array(["listen"] * T) if domain == "corpus"
                     else frame_modes(it["agent_db"]))
            hu, _ = stream_rows(it["mels"][0], art.encode)
            ha_a, calls_a = stream_rows(it["mels"][1], art.encode)
            hu, ha_a = hu[:T], ha_a[:T]
            n_chunks = max(0, (T - 1) // CHUNK_FRAMES)
            skip = skip_chunks(it["agent_db"], n_chunks)
            hops320 = T // 4
            skip320 = skip_chunks(it["agent_db"], hops320, hop_frames=4)
            ha_b = ha_a.copy()
            ha_b[it["agent_db"] <= INAUDIBLE_DB] = 0.0
            feats = {"A": ha_a, "B": ha_b}
            calls = {"A": calls_a}
            for policy in args.policies:
                ha_c, n_calls = stream_rows(it["mels"][1], art.encode, skip, policy)
                feats[f"C-{policy}"] = ha_c[:T]
                calls[f"C-{policy}"] = n_calls
            feats["D-hold"] = hold_fill(ha_a, it["agent_db"], n_chunks)
            # pins: the generator's own grid, and A against whatever was stored
            stored_hu, stored_ha = it["stored"]
            n0 = min(CHUNK_FRAMES, T - 1)
            # chunk-0 identity is only meaningful where stored rows are this artifact's
            # streaming rows (corpus); live stored rows are the windowed cut.
            def put(key, value):
                pin.setdefault(domain, {}).setdefault(key, []).append(value)

            def cosmed(x, y):
                x, y = x.astype(np.float64), y.astype(np.float64)
                return float(np.median((x * y).sum(1) / np.maximum(
                    np.linalg.norm(x, axis=1) * np.linalg.norm(y, axis=1), 1e-12)))

            put("chunk0_maxabs",
                float(np.abs(ha_a[1:n0 + 1] - stored_ha[1:n0 + 1]).max()))
            if domain == "corpus":  # stored rows are this artifact's streaming rows
                m = min(len(ha_a), len(stored_ha))
                put("a_ha_cos_p50", cosmed(ha_a[:m], stored_ha[:m]))
                put("a_hu_cos_p50", cosmed(hu[:m], stored_hu[:m]))
                put("a_ha_maxabs", float(np.abs(ha_a[:m] - stored_ha[:m]).max()))
                put("a_hu_maxabs", float(np.abs(hu[:m] - stored_hu[:m]).max()))
            else:  # stored live rows are the windowed cut: the published +1-row parity
                m = min(len(ha_a), len(stored_ha) - 1)
                put("a_ha_cos_p50", cosmed(ha_a[:m], stored_ha[1:m + 1]))
                put("a_hu_cos_p50", cosmed(hu[:m], stored_hu[1:m + 1]))

            frames = {"hu_l4": hu, "ha_l4": ha_a, "energy": z["energy"][:T],
                      "mode": (modes == "speaking").astype(np.int8)}
            scores, events = {}, {}
            for arm in ARMS:
                if arm not in ("A",) and arm not in feats:
                    continue
                f = dict(frames, ha_l4=feats[arm])
                scores[arm], events[arm] = replay(model, oracle, f, thr, deb)
            ref = (list(zip(z["ev_frames"].tolist(), z["ev_kinds"].tolist()))
                   if labels and "ev_frames" in z.files
                   else reference_events(z["teacher"][:T], z["energy"][:T], modes,
                                         oracle, thr))
            ref_audible = [f for f, k in ref if k == "BARGE" and np.any(
                it["agent_db"][f - 1 - (f - 1) % 4:f - 1 - (f - 1) % 4 + 4] > VAD_DB)]
            cls_masks = intervals(it["agent_db"], it["mic_db"], modes)
            cls = class_report(cls_masks, scores, events, [a for a in ARMS if a in events],
                               scores["A"], events["A"], thr)
            row = {"sid": sid, "frames": T, "chunks": n_chunks, "skipped": len(skip),
                   "hops_320": hops320, "skipped_320": len(skip320),
                   "calls": calls, "classes": {k: int(v.sum()) for k, v in cls_masks.items()},
                   "class_report": cls, "ref_events": len(ref),
                   "n_events": {a: len(e) for a, e in events.items()},
                   "agreement": {a: aligned_count(events["A"], events[a], 2)[0]
                                 for a in events if a != "A"},
                   "kept_inaudible": int(sum(
                       1 for f in np.flatnonzero(it["agent_db"] <= INAUDIBLE_DB)
                       if (f // CHUNK_FRAMES) not in skip)),
                   "barge_audible": {a: sum(1 for f, k in events[a]
                                            if k == "BARGE" and it["agent_db"][f - 1] > VAD_DB)
                                     for a in events},
                   "ref_barge_audible": sum(1 for f, k in ref
                                            if k == "BARGE" and it["agent_db"][f - 1] > VAD_DB),
                   "ref_kinds": {k: sum(1 for _f, kk in ref if kk == k)
                                 for k in sorted({kk for _f, kk in ref})},
                   "barge_hop_loud": {a: sum(
                       1 for f, k in events[a] if k == "BARGE" and np.any(
                           it["agent_db"][f - 1 - (f - 1) % 4:
                                          f - 1 - (f - 1) % 4 + 4] > VAD_DB)) for a in events},
                   "ref_barge_hop_loud": sum(
                       1 for f, k in ref if k == "BARGE" and np.any(
                           it["agent_db"][f - 1 - (f - 1) % 4:
                                          f - 1 - (f - 1) % 4 + 4] > VAD_DB)),
                   "ref_audible_matched": {
                       a: sum(1 for f in ref_audible if any(
                           k == "BARGE" and abs(g - f) <= 2 for g, k in events[a]))
                       for a in events},
                   "ref_audible": len(ref_audible),
                   "skip_vs_mask": {a: aligned_count(events["B"], events[a], 2)[0]
                                    for a in events if a.startswith("C")},
                   "by_kind": {a: kind_report(events["A"], events[a], 2)[0]
                               for a in events if a != "A"}}
            for arm in events:
                row.setdefault("kinds", {})[arm] = {
                    k: sum(1 for _f, kk in events[arm] if kk == k)
                    for k in sorted({kk for _f, kk in events[arm]} | {"BARGE", "BACKCHANNEL",
                                                                      "ENDPOINT"})}
                row.setdefault("ref_agreement", {})[arm] = aligned_count(
                    ref, events[arm], 2)[0]
            row["agreement"]["ref_size"] = len(ref)
            row["agreement"]["A_vs_ref"] = aligned_count(ref, events["A"], 2)[0]
            if labels:
                row["product"] = {a: product_metrics(events[a], scores[a], labels, thr)
                                  for a in events}
            rows.append(row)
            print(f"  {sid[:24]}… {T} frames, chunks {n_chunks}, skipped {len(skip)} "
                  f"({len(skip) / max(1, n_chunks):.0%}), events "
                  f"{ {a: len(e) for a, e in events.items()} }", flush=True)
            rec[f"{domain}:{sid}"] = row

        per_domain[domain] = summarize(domain, rows)

    return rec, per_domain, pin


def summarize(domain, rows):
    """Domain totals, per-class cells, and A<->arm agreement over all sessions."""
    agg_cls = {}
    for arm in ARMS:
        cells = {}
        for c in CLASSES:
            per = [r["class_report"][arm][c] for r in rows
                   if arm in r["class_report"] and r["class_report"][arm][c].get("frames")]
            if not per:
                continue
            cell = {"frames": sum(x["frames"] for x in per),
                    "events": {k: sum(x["events"][k] for x in per)
                               for k in ("a", "b", "only_a", "only_b", "shifted",
                                         "shifted_earlier", "shifted_later")}}
            for kd in ("added_by_kind", "lost_by_kind"):
                total = {}
                for x in per:
                    for k, v in x.get(kd, {}).items():
                        total[k] = total.get(k, 0) + v
                cell[kd] = total
            for head, _col in PROB_COLS:
                cell[head] = {
                    "a_mean": round(float(np.average([x[head]["a_mean"] for x in per],
                                                     weights=[x["frames"] for x in per])), 4),
                    "b_mean": round(float(np.average([x[head]["b_mean"] for x in per],
                                                     weights=[x["frames"] for x in per])), 4),
                    "d_mean": round(float(np.average([x[head]["d_mean"] for x in per],
                                                     weights=[x["frames"] for x in per])), 5),
                    "d_p95abs": round(float(np.mean([x[head]["d_p95abs"] for x in per])), 5),
                    "added": sum(x[head]["added"] for x in per),
                    "lost": sum(x[head]["lost"] for x in per),
                    "fires_a": sum(x[head]["fires_a"] for x in per),
                    "fires_b": sum(x[head]["fires_b"] for x in per)}
            cells[c] = cell
        agg_cls[arm] = cells
    present = [a for a in ARMS if rows and a in rows[0]["kinds"]]
    out = {"sessions": len(rows), "frames": sum(r["frames"] for r in rows),
           "class_totals": {c: sum(r["classes"][c] for r in rows) for c in CLASSES},
           "events": {a: {k: sum(r["kinds"][a].get(k, 0) for r in rows)
                          for k in ("BARGE", "BACKCHANNEL", "ENDPOINT")}
                      for a in present},
           "agreement": {}, "class_shift": agg_cls,
           "kept_inaudible": sum(r["kept_inaudible"] for r in rows),
           "chunks": sum(r["chunks"] for r in rows),
           "skipped": sum(r["skipped"] for r in rows),
           "hops_320": sum(r["hops_320"] for r in rows),
           "skipped_320": sum(r["skipped_320"] for r in rows),
           "ref_events": sum(r["ref_events"] for r in rows),
           "barge_audible": {a: sum(r["barge_audible"][a] for r in rows) for a in present},
           "barge_hop_loud": {a: sum(r["barge_hop_loud"][a] for r in rows) for a in present},
           "ref_barge_audible": sum(r["ref_barge_audible"] for r in rows),
           "ref_barge_hop_loud": sum(r["ref_barge_hop_loud"] for r in rows),
           "ref_audible": sum(r["ref_audible"] for r in rows),
           "ref_audible_matched": {a: sum(r["ref_audible_matched"][a] for r in rows)
                                   for a in present},
           "ref_kinds": {k: sum(r["ref_kinds"].get(k, 0) for r in rows)
                         for k in sorted({kk for r in rows for kk in r["ref_kinds"]})},
           "calls": {a: sum(r["calls"].get(a, 0) for r in rows) for a in present if a != "B"},
           "per_session": [{"sid": r["sid"], "frames": r["frames"],
                            "skipped": r["skipped"], "chunks": r["chunks"],
                            "hops_320": r["hops_320"], "skipped_320": r["skipped_320"],
                            "kinds": {a: r["kinds"][a] for a in r["kinds"]},
                            "agreement": r["agreement"],
                            "ref_agreement": r["ref_agreement"],
                            "barge_audible": r["barge_audible"],
                            "barge_hop_loud": r["barge_hop_loud"],
                            "ref_barge_audible": r["ref_barge_audible"],
                            "ref_barge_hop_loud": r["ref_barge_hop_loud"],
                            "ref_audible": r["ref_audible"],
                            "ref_audible_matched": r["ref_audible_matched"],
                            "ref_kinds": r["ref_kinds"],
                            "product": r.get("product")} for r in rows],
           "by_kind": {}}
    for arm in present:
        if arm == "A":
            continue
        tot = {}
        for r in rows:
            for k, v in r["by_kind"][arm].items():
                acc = tot.setdefault(k, {})
                for kk, x in v.items():
                    if x is None:
                        continue
                    if kk == "delta_p50":  # per-session median: average, do not sum
                        s0, n0 = acc.get("_d50", (0.0, 0))
                        acc["_d50"] = (s0 + x, n0 + 1)
                    else:
                        acc[kk] = (acc.get(kk) or 0) + x
        for k, acc in tot.items():
            if "_d50" in acc:
                s0, n0 = acc.pop("_d50")
                acc["delta_p50"] = round(s0 / n0, 2) if n0 else None
        out["by_kind"][arm] = tot
    if rows and rows[0].get("product"):
        prod = {}
        for arm in present:
            e = [r["product"][arm]["endpoint"] for r in rows]
            b = [r["product"][arm]["barge"] for r in rows]
            c = [r["product"][arm]["bc"] for r in rows if r["product"][arm]["bc"]]
            lat = [x["lat_med"] for x in e if x["lat_med"] is not None]
            prod[arm] = {
                "endpoint": {"lat_med_mean": round(float(np.mean(lat)), 3) if lat else None,
                             "early": sum(x["early"] for x in e),
                             "miss": sum(x["miss"] for x in e)},
                "barge": {"catch_640ms_mean": round(float(np.mean(
                    [x["catch_640ms"] for x in b if x["catch_640ms"] is not None])), 3)
                    if any(x["catch_640ms"] is not None for x in b) else None,
                    "false_fires": sum(x["false_fires"] for x in b)},
                "bc": {"precision_mean": round(float(np.mean(
                    [x["precision"] for x in c if x["precision"] is not None])), 3)
                    if any(x["precision"] is not None for x in c) else None,
                    "recall_mean": round(float(np.mean(
                        [x["recall"] for x in c if x["recall"] is not None])), 3)
                    if any(x["recall"] is not None for x in c) else None}}
        out["product_agg"] = prod
    for arm in present:
        if arm.startswith("C"):
            al = sum(r["skip_vs_mask"][arm] for r in rows)
            den = sum(max(r["n_events"]["B"], r["n_events"][arm]) for r in rows)
            out.setdefault("mask_vs_skip", {})[arm] = {
                "aligned": al, "of": den, "rate": round(al / den, 4) if den else 1.0}
    for arm in present:
        if arm == "A":
            continue
        al = sum(r["agreement"][arm] for r in rows)
        den = sum(max(r["n_events"]["A"], r["n_events"][arm]) for r in rows)
        ref_a = sum(r["ref_agreement"]["A"] for r in rows)
        ref_b = sum(r["ref_agreement"][arm] for r in rows)
        out["agreement"][arm] = {
            "a_vs_arm": {"aligned": al, "of": den,
                         "rate": round(al / den, 4) if den else 1.0},
            "vs_ref": {"A": ref_a, "arm": ref_b,
                       "of_a": (den_a := sum(max(sum(r["ref_kinds"].values()),
                                                 r["n_events"]["A"]) for r in rows)),
                       "of_b": (den_b := sum(max(sum(r["ref_kinds"].values()),
                                                 r["n_events"][arm]) for r in rows)),
                       "rate_a": round(ref_a / max(1, den_a), 4),
                       "rate_b": round(ref_b / max(1, den_b), 4)}}
    return out


# --------------------------------------------------------------------------- #
# cost, 320 ms economics
# --------------------------------------------------------------------------- #
def measure(fn, n=50, warm=5):
    for _ in range(warm):
        fn()
    ts = []
    for _ in range(n):
        t0 = time.perf_counter_ns()
        fn()
        ts.append((time.perf_counter_ns() - t0) / 1e6)
    ts = np.asarray(ts)
    return {"p50": round(float(np.percentile(ts, 50)), 3),
            "p95": round(float(np.percentile(ts, 95)), 3)}


def economics(args):
    a32 = TapArtifact(args.artifact_320)
    b1, b2 = TapArtifact(args.prefix_b1), TapArtifact(args.prefix_b2)
    win32 = np.zeros((1, 128, a32.mel_len), np.float32)
    win41 = np.zeros((1, 128, b1.mel_len), np.float32)

    def call_full():
        a32.encode(win32, a32.caches())

    def call_b1():
        b1.encode(win41, b1.caches())

    def call_b2():
        b2.encode(np.concatenate([win41, win41], 0), b2.caches())

    out = {"loadavg_start": [round(x, 2) for x in os.getloadavg()],
           "full_320_one_ear": measure(call_full),
           "prefix_320_b1": measure(call_b1),
           "prefix_320_batch2": measure(call_b2),
           "loadavg_end": [round(x, 2) for x in os.getloadavg()],
           "note": "macOS host, CPU_AND_NE, one call at a time; another process may "
                   "share the ANE, so ratios and event counts are the result, not ms."}
    return out


# --------------------------------------------------------------------------- #
# selfcheck
# --------------------------------------------------------------------------- #
def selfcheck():
    import mode_track
    mode_track.selfcheck()

    # skip selection: a chunk is skipped only when all of its frames are inaudible
    db = np.array([-90, -90, -90, -90, -90, -90, -90,   # chunk 0 skipped
                   -90, -55, -90, -90, -90, -90, -90,   # chunk 1 kept (one voiced frame)
                   -90, -90, -55, -90, -90, -90, -90])  # chunk 2 kept: -55 > -60
    assert skip_chunks(db, 3) == {0}, skip_chunks(db, 3)
    assert 2 in skip_chunks(db, 3, thr=-50), "a -55 dB frame is inaudible at a -50 dB bar"

    # stream_rows: placement, zeros, call count, and the two cache policies
    calls = {"n": 0, "cache": "c0"}

    def fake_encode(window, caches):
        calls["n"] += 1
        calls["cache"] = caches
        return np.full((CHUNK_FRAMES, 1024), float(calls["n"]), np.float32), caches

    mel = np.zeros((1, 128, PRE_ENCODE + 3 * CHUNK_MEL + 1), np.float32)
    a, n = stream_rows(mel, fake_encode)
    assert n == 3 and a.shape == (1 + 3 * CHUNK_FRAMES, 1024), (n, a.shape)
    assert a[0].tolist() == a[1].tolist(), "row 0 is the duplicated context row"
    assert np.all(a[1:8] == 1) and np.all(a[8:15] == 2), "chunk k lands at [1+7k, 8+7k)"
    calls.update(n=0, cache="c0")
    c, n = stream_rows(mel, fake_encode, skip={1})
    assert n == 2 and np.all(c[1:8] == 1) and np.all(c[8:15] == 0) and np.all(c[15:22] == 2)
    # freeze: the resumed call sees the same cache object it left; reset: a fresh one
    frozen, _ = stream_rows(mel, fake_encode, skip={1}, policy="freeze")
    assert calls["n"] == 4
    calls.update(n=0, cache="c0")
    stream_rows(mel, fake_encode, skip={1}, policy="reset")
    assert calls["n"] == 2
    # hold fill: a skipped chunk repeats the last row of the previous kept chunk
    a_rows = np.arange(1 + 3 * CHUNK_FRAMES, dtype=np.float32)[:, None].repeat(1024, 1)
    held = hold_fill(a_rows, np.array([-30] * 7 + [-90] * 7 + [-30] * 7), 3)
    assert np.all(held[8:15] == a_rows[7]), "a skipped chunk holds the last kept row"
    assert np.all(held[15:22] == a_rows[15:22]), "a kept chunk is untouched"

    # interval memberships on a hand-built track
    agent = np.array([-90, -90, -30, -30, -30, -90, -90, -90, -90], np.float64)
    mic = np.array([-90, -30, -30, -90, -30, -30, -90, -30, -90], np.float64)
    modes = np.array(["listen"] * 9)
    cls = intervals(agent, mic, modes)
    assert np.flatnonzero(cls["playback_start"]).tolist() == [2]
    assert np.flatnonzero(cls["playback_stop"]).tolist() == [5]
    assert np.flatnonzero(cls["silent_interior"]).tolist() == [0, 6, 7, 8]
    assert np.flatnonzero(cls["audible_overlap"]).tolist() == [2, 4]
    assert np.flatnonzero(cls["quiet_negative"]).tolist() == [0, 6, 8]
    assert np.flatnonzero(cls["playback_start_win"]).tolist() == [0, 1, 2, 3, 4, 5]
    assert np.flatnonzero(cls["playback_stop_win"]).tolist() == [2, 3, 4, 5, 6, 7, 8]
    assert cls["playback_start"][2] and cls["audible_overlap"][2], \
        "a start that is also overlap (the barge case) must stay in both"

    # event diff arithmetic: one shift inside tolerance, one loss, one addition
    a = [(10, "BARGE"), (40, "ENDPOINT"), (70, "BACKCHANNEL")]
    b = [(11, "BARGE"), (43, "ENDPOINT"), (90, "BACKCHANNEL")]
    pairs, only_a, only_b, delta = diff_events(a, b, 2)
    assert len(pairs) == 1 and only_a == 2 and only_b == 2, (pairs, only_a, only_b)
    assert delta[(10, "BARGE")] == 1
    print("ha_ablation selfcheck: ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--selfcheck", action="store_true")
    ap.add_argument("--out", default="bench-results/ha-ablation.json")
    ap.add_argument("--student", default=STUDENT)
    ap.add_argument("--artifact", default=ARTIFACT_560)
    ap.add_argument("--artifact-320", default=ARTIFACT_320)
    ap.add_argument("--prefix-b1", default=PREFIX_B1)
    ap.add_argument("--prefix-b2", default=PREFIX_B2)
    ap.add_argument("--live-shards", default=LIVE_SHARDS)
    ap.add_argument("--live-wavs", default=LIVE_WAVS)
    ap.add_argument("--corpus-shards", default=CORPUS_SHARDS)
    ap.add_argument("--corpus-wavs", default=CORPUS_WAVS)
    ap.add_argument("--policies", default="freeze,reset")
    ap.add_argument("--sessions", type=int, default=0, help="debug: first N per domain")
    ap.add_argument("--skip-cost", action="store_true", help="skip the 320 ms cost pass")
    args = ap.parse_args()
    args.policies = [p for p in args.policies.split(",") if p]
    if args.selfcheck:
        return selfcheck()
    if not args.run:
        ap.error("--run or --selfcheck")
    rec, per_domain, pin = run(args)
    econ = {} if args.skip_cost else economics(args)
    body = {"config": {k: str(v) for k, v in vars(args).items()},
            "pins": {dom: {k: (round(float(np.median(v)), 6) if v else None)
                           for k, v in p.items()} for dom, p in pin.items()},
            "domains": per_domain, "economics": econ, "sessions": rec}
    for dom, D in per_domain.items():
        print(f"\n== {dom}: {D['sessions']} sessions, {D['frames']} frames, "
              f"{D['chunks']} chunks {D['skipped']} skipped ({D['skipped'] / max(1, D['chunks']):.0%}); "
              f"320 hops {D['hops_320']} / {D['skipped_320']} skipped")
        print("   arm        BARGE  BACKCHANNEL  ENDPOINT   A<->arm   arm<->teacher")
        for a, e in D["events"].items():
            ag = D["agreement"].get(a, {}).get("a_vs_arm", {})
            vr = D["agreement"].get(a, {}).get("vs_ref", {})
            rate = f"{ag['rate']:.1%}" if ag else "-"
            trate = (f"{vr['rate_b']:.1%}" if a != "A" else
                     f"{D['agreement']['B']['vs_ref']['rate_a']:.1%}") if a != "A" or D.get("agreement") else "-"
            print(f"   {a:10s} {e['BARGE']:5d} {e['BACKCHANNEL']:11d} {e['ENDPOINT']:9d} "
                  f"{rate:>9s} {trate:>15s}")
        if "mask_vs_skip" in D:
            print("   mask<->skip: " + ", ".join(
                f"{k} {v['rate']:.1%}" for k, v in D["mask_vs_skip"].items()))
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(body, indent=1))
    print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
