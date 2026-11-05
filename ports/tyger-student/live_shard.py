"""Live-call decision log -> shards (#102's live-call baseline, the read half).

`TurnEngine` writes the log behind `IDFON_TURN_LOG=<path>` (the shared
`ports/tyger-swift` package, `TurnTrace`): one JSON header per session, then one
JSON object per 80 ms frame carrying the deployed tier's 8-vector, the rules
input (energy, prev_state, mode), and the events that fired. This script turns
that into `data.py`'s shard format — the layout `gate.py`, `tap_gate.py` and
`agreement.py` already read — so a recorded call is comparable material with no
hand work.

    .venv/bin/python ports/tyger-student/live_shard.py \
        --log call.jsonl --out bench-results/live-call-shards

What the log holds vs what a shard needs:
  energy/prev_state/mode/teacher/ev_*   from the log (teacher = the LIVE tier's
                                        8-vector, not the fp32 teacher)
  hu/ha (the 1,024-d encoder features)  the log has no audio — join a
                                        `featurize.py --wavs` pass over the same
                                        `TurnCapture` stereo wav with --features

    .venv/bin/python ports/tyger-student/featurize.py --wavs "$CAPTURES" --out bench-results/live-shards
    .venv/bin/python ports/tyger-student/live_shard.py --log call.jsonl \
        --features bench-results/live-shards/live-turn-<stamp>.npz --out bench-results/live-call-shards

Without --features the shard still carries the live events (a reference side for
`gate.py`), but hu/ha are zeros, so it is not a replayable shard. --features
needs a single-session log (one call) because featurize names shards by wav, not
by session id; pass the matching npz. Frames are aligned by index and cut to the
shorter side (featurize and the app share the 4-frames-per-hop grid).

`--selfcheck` runs a synthetic log round trip (assert-based, no models).
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from data import load_shard, save_shard  # noqa: E402

SR, HOP = 16000, 5120


def read_log(path):
    """JSONL -> [{header, frames}] in file order. Records belong to the header
    that precedes them, so several calls can share one file."""
    sessions = []
    with open(path) as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                raise SystemExit(f"{path}:{lineno}: not JSON ({e})")
            if rec.get("rec") == "session":
                sessions.append({"header": rec, "frames": []})
            elif rec.get("rec") == "frame":
                if not sessions:
                    raise SystemExit(f"{path}:{lineno}: frame before any session header")
                sessions[-1]["frames"].append(rec)
            else:
                raise SystemExit(f"{path}:{lineno}: unknown record kind {rec.get('rec')!r}")
    return [s for s in sessions if s["frames"]]


def load_features(path):
    """hu/ha from a featurize.py shard (canonical 1,024-d streams)."""
    with np.load(path) as z:
        return z["hu"], z["ha"]


def build_shard(session, features=None):
    """One session -> (frames, events, metadata). Raises SystemExit on a log
    that cannot be a shard (wrong rate/hop, malformed 8-vector, bad index)."""
    hdr, recs = session["header"], session["frames"]
    sid = hdr.get("session") or "?"
    if hdr.get("rate", SR) != SR or hdr.get("hop", HOP) != HOP:
        raise SystemExit(f"session {sid}: rate/hop {hdr.get('rate')}/{hdr.get('hop')} "
                         f"is not the {SR}/{HOP} frame grid the shards use")
    for n, rec in enumerate(recs):
        if rec.get("i") != n + 1:
            raise SystemExit(f"session {sid}: frame index {rec.get('i')!r} at line {n + 1} "
                             f"(expected {n + 1}; a gap loses the frame grid)")
        if len(rec.get("out") or []) != 8:
            raise SystemExit(f"session {sid}: frame {n + 1} has no 8-vector")

    T = len(recs)
    hu = np.zeros((T, 1024), np.float32)
    ha = np.zeros((T, 1024), np.float32)
    if features is not None:
        fhu, fha = features
        n = min(T, len(fhu), len(fha))
        if abs(T - n) > 4:
            print(f"  {sid[:8]}… log {T} frames vs features {len(fhu)}: using {n}",
                  file=sys.stderr)
        lost = [e["kind"] for r in recs[n:] for e in (r.get("events") or [])]
        if lost:
            print(f"  {sid[:8]}… cut past the feature grid, dropping events {lost}", file=sys.stderr)
        T = n
        hu, ha = fhu[:T], fha[:T]
        recs = recs[:T]

    events = [(int(e["frame"]), str(e["kind"])) for r in recs
              for e in (r.get("events") or [])]
    frames = {
        "hu": np.asarray(hu, np.float32),
        "ha": np.asarray(ha, np.float32),
        "energy": np.array([r["act_db"] for r in recs], np.float32),
        "prev_state": np.array([r["prev"] for r in recs], np.int64),
        "mode": np.array([1 if r.get("mode") == "speaking" else 0 for r in recs], np.int8),
        "teacher": np.array([r["out"] for r in recs], np.float32),
    }
    meta = {k: hdr[k] for k in ("session", "started_at", "rate", "hop", "app", "build",
                                "tier", "rung", "step", "traits") if k in hdr}
    return frames, events, meta


def convert(log_path, out_dir, features_path=None):
    sessions = read_log(log_path)
    if not sessions:
        sys.exit(f"{log_path}: no sessions with frames")
    if features_path and len(sessions) > 1:
        sys.exit(f"{log_path}: {len(sessions)} sessions — --features applies to one call; "
                 f"split the log (one file per call) or drop --features")
    features = load_features(features_path) if features_path else None
    out = Path(out_dir)
    made = []
    for s in sessions:
        frames, events, meta = build_shard(s, features if len(sessions) == 1 else None)
        sid = "live-call-" + str(meta.get("session", "?"))[:8]
        path = out / f"{sid}.npz"
        if events:
            save_shard(path, sid, frames, {},
                       events=(np.array([f for f, _ in events], np.int32),
                               np.array([k for _, k in events])))
        else:
            save_shard(path, sid, frames, {})  # gate.py skips a shard with no reference events
        made.append((path, len(frames["energy"]), len(events), meta))
        print(f"{sid} {len(frames['energy'])} frames ({len(frames['energy']) / 12.5:.0f}s), "
              f"{len(events)} events, tier {meta.get('tier', '?')}/{meta.get('step', '?')} -> {path}",
              flush=True)
    return made


def selfcheck():
    """Synthetic log -> shard -> load_shard: the format pin."""
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        log = tmp / "call.jsonl"
        rows = [{"rec": "session", "session": "aaaaaaaa-0000", "started_at": "2026-11-05T00:00:00Z",
                 "origin_ns": 1.0, "rate": 16000, "hop": 5120, "app": "test", "build": "1 (1)",
                 "tier": "coreai", "step": "student_step"}]
        for i in range(1, 9):
            rec = {"rec": "frame", "i": i, "t_ms": (i - 1) * 80.0,
                   "out": [float(i)] + [0.0] * 7, "act_db": -30.0 - i, "prev": (i - 1) % 4,
                   "left": 3 - (i - 1) % 4, "mode": "speaking" if i > 4 else "listen"}
            if i == 5:
                rec["events"] = [{"kind": "BARGE", "frame": 5}]
            if i == 8:
                rec["events"] = [{"kind": "ENDPOINT", "frame": 8}]
            rows.append(rec)
        log.write_text("\n".join(json.dumps(r) for r in rows) + "\n")

        # a 6-frame "featurize" pass over the same wav: 2 frames shorter
        feats = tmp / "feat.npz"
        np.savez(feats, hu=np.ones((6, 1024), np.float32), ha=np.full((6, 1024), 2.0, np.float32))

        made = convert(log, tmp / "shards")
        assert len(made) == 1 and made[0][1] == 8 and made[0][2] == 2, made
        path, _frames, _events, meta = made[0]
        fr, labels, ev, loaded = load_shard(path)
        assert loaded["session_id"] == "live-call-aaaaaaaa" and loaded["frames"] == 8
        assert fr["energy"].tolist() == [-31.0 - i for i in range(8)]
        assert fr["prev_state"].tolist() == [0, 1, 2, 3, 0, 1, 2, 3]
        assert fr["mode"].tolist() == [0, 0, 0, 0, 1, 1, 1, 1]
        assert fr["teacher"][:, 0].tolist() == [float(i) for i in range(1, 9)]
        assert ev[0].tolist() == [5, 8] and ev[1].tolist() == ["BARGE", "ENDPOINT"]
        assert fr["hu"].shape == (8, 1024) and float(fr["hu"].sum()) == 0.0

        made = convert(log, tmp / "joined", features_path=str(feats))
        fr, _l, ev, loaded = load_shard(made[0][0])
        assert loaded["frames"] == 6, "features shorter: cut to the shorter side"
        assert fr["hu"].shape == (6, 1024) and float(fr["hu"].sum()) == 6 * 1024
        assert fr["teacher"][:, 0].tolist() == [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]

        # a second session, no events: one shard each, appended calls stay apart
        rows.append({"rec": "session", "session": "bbbbbbbb-0000", "rate": 16000, "hop": 5120})
        rows.append({"rec": "frame", "i": 1, "t_ms": 0.0, "out": [0.0] * 8, "act_db": 0.0,
                     "prev": 4, "left": 3, "mode": "listen"})
        log.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        made = convert(log, tmp / "two")
        assert [m[0].name for m in made] == ["live-call-aaaaaaaa.npz", "live-call-bbbbbbbb.npz"]
        assert load_shard(made[1][0])[2] is None, "no events: no ev arrays"
    print("live_shard selfcheck: ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", help="IDFON_TURN_LOG JSONL (one call, or several calls appended)")
    ap.add_argument("--out", default=None, help="shard dir (default bench-results/live-call-shards)")
    ap.add_argument("--features", default=None,
                    help="featurize.py shard over the same capture (fills hu/ha)")
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args()
    if args.selfcheck:
        return selfcheck()
    if not args.log:
        ap.error("--log or --selfcheck")
    out = args.out or str(Path(__file__).resolve().parents[2] / "bench-results" / "live-call-shards")
    convert(args.log, out, args.features)


if __name__ == "__main__":
    main()
