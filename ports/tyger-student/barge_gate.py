"""Barge with the agent still audible, replayed online on both sides.

`rules.on_frame` fires BARGE whenever `mode == "speaking"`, and the mode track is
bridged: it holds speaking for RELEASE_HOPS (1.92 s) past the agent's last loud hop
so the floor state survives pauses inside one agent turn.

This replays *both* the teacher (from the shard's stored 8-vector, which reproduces
the recorded events at 99%) and the student through the same rules, with an extra
condition inside the barge branch: the agent's own channel must have been audible
within `--lookup` frames. The condition is applied where the rules would emit, not
by deleting events afterwards, so the debounce, the seeded pre-buffer and the
subsequent rules state evolve as they would in the product.

    .venv/bin/python ports/tyger-student/barge_gate.py \\
        --shards <live shard dir> --captures <TurnCapture dir> \\
        --student bench-results/student-l4-60/student.pt --feature-layer 4 \\
        --lookup 0,2,4,8

  --selfcheck   the window and matching arithmetic on synthetic events, no models
"""
from __future__ import annotations

import argparse
import glob
import os
import sys
import wave

import numpy as np

from data import load_shard
from gate import aligned_count, student_events
from mode_track import agent_audible

FRAME_S = 0.08  # the 80 ms decision grid


def agent_db(path: str, frames: int, secs: float = 180.0) -> np.ndarray:
    """Per-80 ms-frame energy (dB) of a TurnCapture's ch1, the agent's own channel."""
    with wave.open(str(path)) as w:
        rate = w.getframerate()
        raw = w.readframes(min(w.getnframes(), int(rate * secs)))
    a = np.frombuffer(raw, np.int16).reshape(-1, 2).astype(np.float32) / 32768.0
    hop = int(rate * FRAME_S)
    e = np.array([np.sqrt(np.mean(a[i:i + hop, 1] ** 2))
                  for i in range(0, len(a) + 1 - hop, hop)])
    out = np.full(frames, -120.0)
    out[:min(frames, len(e))] = 20 * np.log10(np.maximum(e[:frames], 1e-12))
    return out


def teacher_events(frames, oracle, barge_ok=None):
    """The rules replay over the shard's stored teacher 8-vector (the recorded events' source)."""
    from oracle import HOP_FRAMES
    sess = oracle.EarsSession(0)
    out = []
    for f in range(len(frames["energy"])):
        mode = "speaking" if int(frames["mode"][f]) else "listen"
        evs, _final, _reset = oracle.rules.on_frame(
            sess, mode, frames["teacher"][f].astype(np.float64), float(frames["energy"][f]),
            left=3 - (f % HOP_FRAMES))
        for e in evs:
            if e["kind"] == "FRAME":
                continue
            if e["kind"] == "BARGE" and barge_ok is not None and not barge_ok[f]:
                continue
            out.append((f + 1, e["kind"]))
    return out


def one(shard, captures, student, oracle, layer, lookup, thr, tol):
    frames, _labels, events, meta = load_shard(shard)
    sid = str(meta["session_id"])
    wav = os.path.join(captures, sid.replace("live-turn-", "turn-") + ".wav")
    if not os.path.exists(wav):
        return {"session": sid, "missing": wav}
    audible = agent_audible(agent_db(wav, len(frames["energy"])), lookup=lookup)
    recorded = [(int(f), str(k)) for f, k in zip(events[0], events[1])] if events is not None else []
    teach = teacher_events(frames, oracle, audible)
    cand = student_events(student, oracle, frames, layer=layer, thr=thr, barge_ok=audible)
    barges = lambda ev: [e for e in ev if e[1] == "BARGE"]
    a, _, _ = aligned_count(barges(teach), barges(cand), tol)
    return {"session": sid, "lookup": lookup,
            "recorded": sum(1 for _, k in recorded if k == "BARGE"),
            "teach": len(barges(teach)), "cand": len(barges(cand)), "matched": a}


def selfcheck() -> None:
    """The window arithmetic and the matching, on synthetic data."""
    db = np.full(20, -120.0)
    db[5] = -20.0
    a = agent_audible(db, lookup=2)
    assert a[5:8].all() and not a[8:].any() and not a[:5].any()
    assert agent_audible(np.full(6, -120.0)).sum() == 0
    assert aligned_count([(6, "BARGE")], [(7, "BARGE")], 2)[0] == 1
    assert aligned_count([(6, "BARGE")], [(20, "BARGE")], 2)[0] == 0
    print("selfcheck ok")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards")
    ap.add_argument("--captures", help="dir of TurnCapture wavs (needs ch1)")
    ap.add_argument("--student")
    ap.add_argument("--tap", default=None)
    ap.add_argument("--feature-layer", type=int, default=4)
    ap.add_argument("--lookup", default="2", help="comma-separated frame lookbacks to sweep")
    ap.add_argument("--ep-thr", type=float, default=0.75)
    ap.add_argument("--barge-thr", type=float, default=0.5)
    ap.add_argument("--bc-thr", type=float, default=0.5)
    ap.add_argument("--tol", type=int, default=2, help="event alignment tolerance in frames")
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--selfcheck", action="store_true")
    a = ap.parse_args()
    if a.selfcheck:
        return selfcheck()
    if not (a.shards and a.captures and a.student):
        ap.error("--shards, --captures and --student are required (or --selfcheck)")

    from checkpoint import load as load_model
    from oracle import Oracle
    student, _ = load_model(a.student, tap=a.tap, device=a.device)
    oracle = Oracle(device="cpu")
    thr = (a.ep_thr, a.barge_thr, a.bc_thr)
    shards = sorted(glob.glob(os.path.join(a.shards, "*.npz")))
    if not shards:
        sys.exit(f"no shards in {a.shards}")

    for lookup in [int(x) for x in a.lookup.split(",")]:
        rows = [one(s, a.captures, student, oracle, a.feature_layer, lookup, thr, a.tol) for s in shards]
        rows = [r for r in rows if not r.get("missing")]
        teach = sum(r["teach"] for r in rows)
        cand = sum(r["cand"] for r in rows)
        ali = sum(r["matched"] for r in rows)
        print(f"\nlookup {lookup} frames ({lookup * 80} ms), online gate on both sides, "
              f"{len(rows)} sessions")
        print(f"  teacher barges {sum(r['recorded'] for r in rows):>4} recorded -> {teach:>3} gated"
              f"   student -> {cand:>3} gated   matched {ali:>3}")
        print(f"  student agreement {100 * ali / teach if teach else 0:>5.1f}% of the teacher's gated barges"
              f"   precision {100 * ali / cand if cand else 0:>5.1f}%")
        silent = sorted(r["session"][-14:] for r in rows if r["teach"] and not r["matched"])
        if silent:
            print(f"  sessions with gated teacher barges and no student match: {len(silent)}")
    print()


if __name__ == "__main__":
    main()
