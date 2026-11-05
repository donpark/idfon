"""The first barge measurement on the live captures (#132 / #102).

The replay harnesses used to pass `mode="response"` (a stream name), so the rules'
barge branch never ran. This replays the same captures with `mode_track.py`: the
shard's own mode track when present, else derived from the agent channel (`ch1`)
of the `TurnCapture` stereo wav. No app, threshold, model, rule or fork change.

For each capture it reports, per frame:

  agent activity   ch1 energy above the rules' VAD (-50 dB)
  speaking         the derived mode, the app's floor proxy
  overlap          caller voiced *and* agent audible in the same 80 ms frame
  BARGE            rules events from the live tier's recorded 8-vector (`teacher`)

and splits each BARGE by whether the agent was still audible when the yield head
crossed (the interrupt that can cut playback) and whether the caller's stretch
began while the agent was audible. Frames where the derived mode says speaking
but ch1 is inaudible are counted as the proxy's false-positive side.

`--selfcheck` pins the mode derivation and the replay controls: a synthetic
speaking-mode replay where the yield head fires must emit BARGE, and the same
frames in listen mode must not.

Usage:
  .venv/bin/python ports/tyger-student/live_barge.py \
      --shards bench-results/live-shipping \
      --wavs "$HOME/Library/Application Support/Idfon/turn-captures"
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from data import load_shard  # noqa: E402
from mode_track import VAD_DB, frame_modes  # noqa: E402
from oracle import Oracle  # noqa: E402

FRAME_S = 0.08
HOP_FRAMES = 4
INAUDIBLE_DB = -60.0   # "no playback reached the capture": below the -50 dB VAD and
                       # below the -80 dB dither floor these captures show in pauses


def frame_db(x):
    """80 ms frame energy in dB (the rules' VAD scale)."""
    n = len(x) // 1280
    seg = np.asarray(x[:n * 1280], np.float32).reshape(n, 1280)
    return (20.0 * np.log10(np.sqrt((seg ** 2).mean(1) + 1e-12) + 1e-9)).astype(np.float32)


def read_capture(wav_dir, session_id):
    """`live-turn-<stamp>` -> the TurnCapture wav (ch0 mic, ch1 agent)."""
    import soundfile as sf
    stamp = session_id[len("live-turn-"):] if session_id.startswith("live-turn-") else session_id
    path = Path(wav_dir) / f"turn-{stamp}.wav"
    wav, rate = sf.read(str(path), dtype="float32", always_2d=True)
    assert rate == 16000 and wav.shape[1] == 2, f"{path}: {rate} Hz x {wav.shape[1]}"
    return wav[:, 0], wav[:, 1]


def sidecar(wav_dir, session_id):
    """TurnCapture's `<wav>.json` (agentHops / agentNonSilent / agentPeak), or None."""
    stamp = session_id[len("live-turn-"):] if session_id.startswith("live-turn-") else session_id
    path = Path(wav_dir) / f"turn-{stamp}.json"
    return json.loads(path.read_text()) if path.exists() else None


def replay(vecs, energy, agent_db, modes, oracle, thr=(0.88, 0.5, 0.3)):
    """Rules replay with the mode track; returns (BARGE records, all event kinds).

    `switch_mode` per frame is idempotent: it only resets on a floor change, which
    is what the app does at the hop boundary. `left` is the hop's remaining frames
    (the shipped value); it only moves a barge's reported onset_s.
    """
    sess = oracle.EarsSession(0, ep_thr=thr[0], barge_thr=thr[1], bc_thr=thr[2])
    last, barges, kinds = None, [], {}
    for f in range(len(vecs)):
        mode = str(modes[f])
        if mode != last:
            oracle.rules.switch_mode(sess, mode)
            last = mode
        evs, _final, _reset = oracle.rules.on_frame(
            sess, mode, vecs[f], float(energy[f]), left=3 - (f % HOP_FRAMES))
        for e in evs:
            kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
            if e["kind"] == "BARGE":
                talk = int(sess.talk_frames)
                start = max(0, f - talk + 1)
                barges.append(dict(
                    frame=f + 1, onset_s=e["onset_s"], talk_frames=talk,
                    yield_prob=float(vecs[f][5]),
                    user_db=float(energy[f]), agent_db=float(agent_db[f]),
                    event_hop_loud=bool(np.any(agent_db[f - f % HOP_FRAMES:
                                                     f - f % HOP_FRAMES + HOP_FRAMES] > VAD_DB)),
                    onset_hop_loud=bool(np.any(agent_db[start - start % HOP_FRAMES:
                                                        start - start % HOP_FRAMES + HOP_FRAMES] > VAD_DB)),
                ))
    return barges, kinds


def speaking_stretches(modes):
    """Maximal speaking runs as (start, end) frame indices."""
    runs, start = [], None
    for f, m in enumerate(modes):
        if m == "speaking" and start is None:
            start = f
        elif m != "speaking" and start is not None:
            runs.append((start, f))
            start = None
    if start is not None:
        runs.append((start, len(modes)))
    return runs


def echo_score(user, agent):
    """Max normalized sample correlation over +/-100 ms on up to 5 loud 1 s blocks.

    A high value means the mic track carries a delayed copy of playback (leak), so
    simultaneous loudness is echo rather than the caller; low means the overlap is
    independent speech.
    """
    block = 16000
    best = 0.0
    used = 0
    for i in range(0, max(0, min(len(user), len(agent)) - block), block):
        x, y = user[i:i + block], agent[i:i + block]
        if np.sqrt((x ** 2).mean()) < 1e-3 or np.sqrt((y ** 2).mean()) < 1e-3:
            continue
        x = x - x.mean()
        y = y - y.mean()
        nx, ny = np.linalg.norm(x), np.linalg.norm(y)
        for lag in range(-1600, 1601, 16):
            c = (np.dot(x[lag:], y[:block - lag]) if lag >= 0
                 else np.dot(x[:block + lag], y[-lag:])) / (nx * ny + 1e-9)
            best = max(best, float(c))
        used += 1
        if used == 5:
            break
    return best


def analyze(shard_dir, wav_dir, oracle, thr=(0.88, 0.5, 0.3)):
    rows = []
    for path in sorted(Path(shard_dir).glob("*.npz")):
        frames, _labels, _events, meta = load_shard(path)
        sid = meta["session_id"]
        user, agent = read_capture(wav_dir, sid)
        mic_db, agent_db = frame_db(user), frame_db(agent)
        n = len(frames["energy"])
        assert len(agent_db) >= n, f"{sid}: wav is shorter than the shard"
        # frame-alignment pin: the shard's energy is this wav's ch0
        d = float(np.abs(mic_db[:n] - frames["energy"][:n]).max())
        assert d < 1e-3, f"{sid}: shard energy does not match ch0 (max diff {d})"
        agent_db = agent_db[:n]
        given = frames.get("mode")
        modes = frame_modes(agent_db, given=given[:n] if given is not None else None)
        vecs = frames["teacher"]
        assert len(vecs) == n
        barges, kinds = replay(vecs, mic_db[:n], agent_db, modes, oracle, thr)

        loud = agent_db > VAD_DB
        overlap = loud & (mic_db[:n] > VAD_DB)
        runs = speaking_stretches(modes)
        with_barge = [r for r in runs if any(r[0] <= b["frame"] - 1 < r[1] for b in barges)]
        rows.append(dict(
            sid=sid, frames=n, seconds=n * FRAME_S,
            agent_loud=int(loud.sum()),
            speaking=int((modes == "speaking").sum()),
            speaking_inaudible=int(((modes == "speaking") & (agent_db <= INAUDIBLE_DB)).sum()),
            overlap=int(overlap.sum()),
            echo=round(echo_score(user[:n * 1280], agent[:n * 1280]), 3),
            modes_given=given is not None,
            sidecar=sidecar(wav_dir, sid),
            mic_hash=hashlib.sha256(user[:n * 1280].tobytes()).hexdigest()[:12],
            barge=len(barges),
            barge_stretches=len(with_barge),
            barge_audible=sum(b["event_hop_loud"] for b in barges),
            barge_audible_frame=sum(b["agent_db"] > VAD_DB for b in barges),
            barge_caller_voiced=sum(b["event_hop_loud"] and b["user_db"] > VAD_DB
                                    for b in barges),
            barge_start_over_agent=sum(b["onset_hop_loud"] for b in barges),
            barge_audible_and_start_over=sum(b["event_hop_loud"] and b["onset_hop_loud"]
                                             for b in barges),
            onsets=[b["onset_s"] for b in barges if b["event_hop_loud"]],
            kinds=kinds, events=barges,
            # kept for the sensitivity pass, not serialized
            agent_db=agent_db, mic_db=mic_db[:n], vecs=vecs,
        ))
    return rows


def stats(vals):
    if not vals:
        return "0"
    a = np.asarray(vals, np.float64)
    return (f"n {len(a)}  p50 {np.percentile(a, 50):.2f}s  "
            f"p95 {np.percentile(a, 95):.2f}s  max {a.max():.2f}s")


def print_table(rows, thr=(0.88, 0.5, 0.3)):
    print(f"thresholds ep/barge/bc {thr[0]}/{thr[1]}/{thr[2]}; "
          f"VAD {VAD_DB} dB; mode: shard track if present else ch1 energy")
    print("\n| capture | s | agent loud | speaking | inaudible speaking | overlap | "
          "BARGE | stretches | audible hop | audible frame | onset p50/max |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in rows:
        ons = r["onsets"]
        op = (f"{np.percentile(ons, 50):.2f}/{max(ons):.2f}s" if ons else "-")
        print(f"| {r['sid'].replace('live-turn-', '')} | {r['seconds']:.0f} | "
              f"{r['agent_loud']} | {r['speaking']} | {r['speaking_inaudible']} | "
              f"{r['overlap']} | {r['barge']} | {r['barge_stretches']} | "
              f"{r['barge_audible']} | {r['barge_audible_frame']} | {op} |")
    groups = {}
    for r in rows:
        groups.setdefault(r["mic_hash"], []).append(r["sid"])
    dups = [g for g in groups.values() if len(g) > 1]
    print(f"\ncaptures {len(rows)}, distinct caller-mic tracks {len(groups)}"
          + (f" (recaptures: {dups})" if dups else ""))
    print(f"agent-active {sum(r['agent_loud'] > 0 for r in rows)}, "
          f"with any BARGE {sum(r['barge'] > 0 for r in rows)}, "
          f"with a BARGE while the agent was audible "
          f"{sum(r['barge_audible'] > 0 for r in rows)}, "
          f"at the event frame {sum(r['barge_audible_frame'] > 0 for r in rows)}")
    print(f"sidecars present {sum(r['sidecar'] is not None for r in rows)}/{len(rows)}"
          + ("" if any(r["sidecar"] for r in rows) else
             " (these captures predate TurnCapture's agentNonSilent/agentPeak field; "
             "ch1 was measured directly from the wav)"))
    print(f"BARGE events {sum(r['barge'] for r in rows)} "
          f"(audible hop at event {sum(r['barge_audible'] for r in rows)}, "
          f"agent above VAD at the event frame {sum(r['barge_audible_frame'] for r in rows)}, "
          f"caller voiced at an audible-hop event {sum(r['barge_caller_voiced'] for r in rows)}, "
          f"started over the agent {sum(r['barge_start_over_agent'] for r in rows)}); "
          f"speaking stretches with a barge {sum(r['barge_stretches'] for r in rows)}")
    print(f"derived speaking frames whose ch1 is inaudible (<= {INAUDIBLE_DB} dB): "
          f"{sum(r['speaking_inaudible'] for r in rows)} / "
          f"{sum(r['speaking'] for r in rows)}")
    print(f"caller-over-agent frames (both > {VAD_DB} dB): "
          f"{sum(r['overlap'] for r in rows)} across "
          f"{sum(r['overlap'] > 0 for r in rows)} captures; "
          f"max echo corr {max(r['echo'] for r in rows):.3f}")
    print("\nBARGE onset_s, events where the agent was audible at the event:")
    print("  " + stats([o for r in rows for o in r["onsets"]]))
    print("\nper event / kind counts:")
    for r in rows:
        print(f"  {r['sid'].replace('live-turn-', '')}: {r['kinds']}")


def sensitivity(rows, oracle, thr=(0.88, 0.5, 0.3)):
    """How the barge count moves with the mode threshold and release hold."""
    print("\nsensitivity (mode derivation only; same rules thresholds):")
    print("| thr dB | release hops | BARGE | audible@event | captures audible |")
    print("|---:|---:|---:|---:|---:|")
    for db in (-60.0, -55.0, VAD_DB, -45.0, -40.0):
        for rel in (0, 2, 6):
            tot = aud = caps = 0
            for r in rows:
                n = r["frames"]
                agent_db = r["agent_db"]
                modes = frame_modes(agent_db, thr=db, release_hops=rel)
                barges, _ = replay(r["vecs"], r["mic_db"], agent_db, modes, oracle, thr)
                tot += len(barges)
                a = sum(b["event_hop_loud"] for b in barges)
                aud += a
                caps += a > 0
            print(f"| {db:.0f} | {rel} | {tot} | {aud} | {caps} |")


def selfcheck():
    """Controls: speaking mode fires BARGE, listen mode does not."""
    import mode_track
    mode_track.selfcheck()

    oracle = Oracle(device="cpu")
    out = np.array([0.0, 0.0, 0.0, 0.0, 0.0, 0.9, 0.0, 0.0])  # yield 0.9
    energy = np.full(12, -20.0, np.float32)
    agent = np.full(12, -20.0, np.float32)
    vecs = np.tile(out, (12, 1))

    speaking = np.array(["speaking"] * 12)
    barge, _ = replay(vecs, energy, agent, speaking, oracle)
    assert barge, "positive control: speaking mode + firing yield must emit BARGE"
    assert barge[0]["onset_s"] > 0, barge[0]

    listen = np.array(["listen"] * 12)
    barge, kinds = replay(vecs, energy, agent, listen, oracle)
    assert not barge, f"negative control: listen mode must not emit BARGE ({barge})"
    assert "BACKCHANNEL" not in kinds and "ENDPOINT" not in kinds, kinds
    print("live_barge selfcheck: ok (speaking BARGE / listen no BARGE)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", default="bench-results/live-shipping")
    ap.add_argument("--wavs", default=str(Path.home() / "Library/Application Support/Idfon/turn-captures"))
    ap.add_argument("--ep-thr", type=float, default=0.88)
    ap.add_argument("--barge-thr", type=float, default=0.5)
    ap.add_argument("--bc-thr", type=float, default=0.3)
    ap.add_argument("--json", default=None, help="write the per-capture rows here")
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args()
    if args.selfcheck:
        return selfcheck()

    thr = (args.ep_thr, args.barge_thr, args.bc_thr)
    wav_dir = Path(args.wavs).expanduser()
    oracle = Oracle(device="cpu")
    rows = analyze(args.shards, wav_dir, oracle, thr)
    print_table(rows, thr)
    drop = ("events", "agent_db", "mic_db", "vecs")
    body = {r["sid"]: {k: v for k, v in r.items() if k not in drop} for r in rows}
    with_clips = {r["sid"]: r["events"] for r in rows}
    if args.json:
        Path(args.json).write_text(json.dumps({"rows": body, "barges": with_clips}, indent=1))
    sensitivity(rows, oracle, thr)


if __name__ == "__main__":
    main()
