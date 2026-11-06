"""Derive the relay's existing outcome vocabulary offline from the live captures.

Step 0 of #197. The relay (`integrations/eve-idfon-voice/tyger-relay.mjs`) judges
each agent action against what the caller did next and bumps one of seven names
(`crates/idfon-voice/src/adapt.rs` consumes the same names):

  early_cut_in    an utterance starts within 0.5 s after we started replying
  late_endpoint   at an ENDPOINT, dead air after the caller's last speech > 1.2 s
  real_barge      a BARGE fired on an utterance that took >= 1.0 s of floor
  false_barge     a BARGE fired on a shorter sound
  missed_barge    the utterance took >= 1.0 s and no BARGE fired within 0.64 s
  bc_ok           the caller spoke within 1 s after a backchannel (it landed)
  bc_intrusive    the caller did not speak within 1 s after a backchannel

No human ears: the events come from replaying the shard's recorded teacher
8-vectors (the product's existing ears, as `live_barge.py` does), the
speech/playback intervals from the capture's own two channels. `--events
student` replays the unshipped L4 student instead. Nothing here changes the app
or the rules.

Approximations the capture cannot remove (stated so the numbers are not read as
more than they are):
- the relay's "loud" is any 20 ms mic chunk with a nonzero sample; offline we use
  the rules' -50 dB VAD per 80 ms frame, the same floor the events use.
- `replyStartS` is the app's pipeline start (`hopS + 40 ms`); offline it is the
  endpoint's hop end + 40 ms. TTS latency is not in the capture.
- playback pieces are agent-channel voiced runs. A backchannel's run is excluded
  using the replay's BACKCHANNEL event time (the relay excludes `p.bc` pieces).
- utterance intervals bridge gaps < 0.2 s, as the relay's `pushMic` does.

Usage:
  .venv/bin/python scripts/live-outcomes.py --shards bench-results/live-shipping \
      --wavs bench-results/turn-layer-2026-11-06/live/in --out /tmp/live-outcomes.json
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

FRAME_S = 0.08
HOP_FRAMES = 4
HOP_S = FRAME_S * HOP_FRAMES          # 320 ms, the app's decision cadence
VAD_DB = -50.0                        # rules.py's voiced threshold
LEAD_S = 0.04                         # tyger-relay.mjs LEAD_S
BRIDGE_S = 0.2                        # tyger-relay.mjs pushMic bridge
TAKE_S = 1.0                          # "took the floor" minimum utterance
BARGE_WINDOW_S = 0.64                 # barge must fire within this of the onset
DEAD_AIR_S = 1.2                      # late_endpoint threshold
BC_WINDOW_S = 1.0                     # bc_ok: caller speech within 1 s after
THR = (0.9146, 0.5, 0.5)              # shipped ep/barge/bc (rules.py defaults)
LABELS = ("early_cut_in", "late_endpoint", "real_barge", "false_barge",
          "missed_barge", "bc_ok", "bc_intrusive")


def frame_db(x):
    """80 ms frame energy in dB, the rules' VAD scale."""
    n = len(x) // 1280
    seg = np.asarray(x[:n * 1280], np.float32).reshape(n, 1280)
    return (20.0 * np.log10(np.sqrt((seg ** 2).mean(1) + 1e-12) + 1e-9)).astype(np.float32)


def intervals(mask, bridge=BRIDGE_S):
    """Loud-frame runs as (start_s, end_s), bridging gaps shorter than `bridge`."""
    runs = []
    start = prev = None
    for f, loud in enumerate(mask):
        if not loud:
            continue
        t0, t1 = f * FRAME_S, (f + 1) * FRAME_S
        if start is not None and t0 - prev <= bridge + 1e-9:
            prev = t1
        else:
            if start is not None:
                runs.append((start, prev))
            start, prev = t0, t1
    if start is not None:
        runs.append((start, prev))
    return runs


def hop_end(t):
    """The stream position when the hop containing the frame that ends at `t` is
    processed (tyger-relay's hopS). A frame at 0.08 s is in hop 0 (ends 0.32 s)."""
    f = int(t / FRAME_S - 1e-9)
    return ((f // HOP_FRAMES) + 1) * HOP_S


def piece_at(pieces, t):
    for t0, t1 in pieces:
        if t0 <= t < t1:
            return t0, t1
    return None


def derive(speech, pieces, events):
    """Apply the relay's predicates. events: [{kind, t, hop_end}], sorted by time.

    Returns (episodes, totals). An episode is one utterance's judgement, or one
    endpoint/backchannel's. A missing judgement (utterance outside playback, no
    dead-air call) is not emitted.
    """
    bcs = [e for e in events if e["kind"] == "BACKCHANNEL"]
    episodes = []

    # The relay judges utterances at every hop (observe()), after that hop's
    # events. Merge both streams into one time-ordered walk: events first on a tie.
    actions = [(e["hop_end"], 0, "event", e) for e in events]
    actions += [(hop_end(iv_end), 1, "speech", (iv_start, iv_end))
                for iv_start, iv_end in speech]
    actions.sort(key=lambda a: (a[0], a[1]))

    # early_cut_in: earlyJudged starts True; a short-dead-air endpoint arms it.
    early_judged = True
    reply_start = None
    barge_fired_at = None
    bc_windows = [(b["hop_end"], b["hop_end"] + BC_WINDOW_S) for b in bcs]

    def in_bc(t):
        return any(a <= t < b for a, b in bc_windows)

    played = [(t0, t1) for t0, t1 in pieces if not in_bc(t0)]

    for _t, _kind, what, item in actions:
        if what == "event":
            ev = item
            if ev["kind"] == "ENDPOINT":
                last_end = max((s[1] for s in speech if s[1] <= ev["hop_end"]), default=None)
                dead = None if last_end is None else ev["hop_end"] - last_end
                if dead is not None and dead > DEAD_AIR_S:
                    episodes.append(dict(label="late_endpoint", t=round(ev["hop_end"], 2),
                                         dead_air_s=round(float(dead), 2)))
                else:
                    early_judged = False
                    reply_start = ev["hop_end"] + LEAD_S
            elif ev["kind"] == "BARGE":
                barge_fired_at = ev["hop_end"]
            elif ev["kind"] == "BACKCHANNEL":
                at = ev["hop_end"]
                ok = any(at < s <= at + BC_WINDOW_S for s, _ in speech)
                episodes.append(dict(label="bc_ok" if ok else "bc_intrusive",
                                     t=round(at, 2)))
        else:
            iv_start, iv_end = item
            if not early_judged and reply_start is not None and \
                    reply_start <= iv_start < reply_start + 0.5:
                early_judged = True
                episodes.append(dict(label="early_cut_in", t=round(iv_start, 2),
                                     reply_start=round(reply_start, 2),
                                     utterance_s=round(iv_end - iv_start, 2)))
            if piece_at(played, iv_start) is None:
                continue
            took = iv_end - iv_start >= TAKE_S
            judge = hop_end(iv_end)
            fired = barge_fired_at is not None and \
                iv_start <= barge_fired_at <= min(iv_start + BARGE_WINDOW_S, judge)
            if fired:
                episodes.append(dict(label="real_barge" if took else "false_barge",
                                     t=round(iv_start, 2),
                                     utterance_s=round(iv_end - iv_start, 2),
                                     fired_s=round(barge_fired_at, 2)))
            elif took:
                episodes.append(dict(label="missed_barge", t=round(iv_start, 2),
                                     utterance_s=round(iv_end - iv_start, 2)))

    episodes.sort(key=lambda e: (e["t"], e["label"]))
    totals = {name: 0 for name in LABELS}
    for e in episodes:
        totals[e["label"]] += 1
    return episodes, totals


def replay_events(vecs, energy, agent_db, modes, oracle, thr):
    """Rules replay over the student's 8-vectors; all events, in frame order."""
    sess = oracle.EarsSession(0, ep_thr=thr[0], barge_thr=thr[1], bc_thr=thr[2])
    out = []
    for f in range(len(vecs)):
        evs, _final, _reset = oracle.rules.on_frame(
            sess, str(modes[f]), vecs[f], float(energy[f]), left=3 - (f % HOP_FRAMES))
        for e in evs:
            kind = e.get("kind")
            if kind in ("ENDPOINT", "BARGE", "BACKCHANNEL"):
                out.append(dict(kind=kind, frame=f, t=round((f + 1) * FRAME_S, 2),
                                hop_end=hop_end((f + 1) * FRAME_S)))
    return out


def student_vecs(model, hu, ha, energy, modes, oracle, device, torch):
    """The shipped student's 8-vector per frame, carrying its own rules session."""
    sess = oracle.EarsSession(0)
    hidden = None
    rows = []
    with torch.no_grad():
        for f in range(len(energy)):
            o, hidden = model(torch.as_tensor(hu[f], device=device)[None, None],
                              torch.as_tensor(ha[f], device=device)[None, None],
                              torch.tensor([[float(energy[f])]], device=device),
                              torch.tensor([[int(sess.prev_state)]], device=device), hidden)
            v = model.eight_vector(o)[0, 0].cpu().numpy().astype(np.float64)
            rows.append(v)
            oracle.rules.on_frame(sess, str(modes[f]), v, float(energy[f]),
                                  left=3 - (f % HOP_FRAMES))
    return np.stack(rows) if rows else np.zeros((0, 8), np.float64)


def read_capture(wav_dir, session_id):
    """`live-turn-<stamp>` -> the TurnCapture wav (ch0 mic, ch1 agent)."""
    import soundfile as sf
    stamp = session_id[len("live-turn-"):] if session_id.startswith("live-turn-") else session_id
    path = Path(wav_dir) / f"turn-{stamp}.wav"
    wav, rate = sf.read(str(path), dtype="float32", always_2d=True)
    assert rate == 16000 and wav.shape[1] == 2, f"{path}: {rate} Hz x {wav.shape[1]}"
    return wav[:, 0], wav[:, 1]


def analyze(shard_dir, wav_dir, events_from="teacher", student_path=None,
            device="cpu", thr=THR):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ports/tyger-student"))
    from data import load_shard
    from mode_track import frame_modes
    from oracle import Oracle

    oracle = Oracle(device=device)
    model = torch = None
    if events_from == "student":
        if not student_path:
            sys.exit("--events student needs --student PATH")
        import torch as _torch
        from model import Student
        from registry import by_id
        torch = _torch
        ck = torch.load(student_path, map_location=device)
        model = Student([by_id(i) for i in ck["heads"]], width=ck["width"],
                        layers=ck["layers"]).to(device)
        model.load_state_dict(ck["state_dict"])
        model.eval()

    rows = []
    for path in sorted(Path(shard_dir).glob("*.npz")):
        frames, _labels, _events, meta = load_shard(path)
        sid = meta["session_id"]
        user, agent = read_capture(wav_dir, sid)
        n = len(frames["energy"])
        mic_db, agent_db = frame_db(user)[:n], frame_db(agent)[:n]
        d = float(np.abs(mic_db - frames["energy"]).max())
        assert d < 1e-3, f"{sid}: shard energy does not match ch0 (max diff {d})"
        modes = frame_modes(agent_db)
        if events_from == "teacher":
            vecs = frames["teacher"]
        else:
            vecs = student_vecs(model, frames["hu_l4"], frames["ha_l4"],
                                frames["energy"], modes, oracle, device, torch)
        events = replay_events(vecs, frames["energy"], agent_db, modes, oracle, thr)

        speech = intervals(mic_db > VAD_DB)
        pieces = intervals(agent_db > VAD_DB)
        episodes, totals = derive(speech, pieces, events)
        rows.append(dict(sid=sid, seconds=round(n * FRAME_S, 1),
                         speech=len(speech), pieces=len(pieces),
                         events={k: sum(1 for e in events if e["kind"] == k)
                                 for k in ("ENDPOINT", "BARGE", "BACKCHANNEL")},
                         totals=totals, episodes=episodes))
    return rows


def selfcheck():
    """The predicates are pure; pin each label on a hand-built timeline."""
    pieces = [(9.5, 12.0)]

    # real_barge: long utterance, barge within 0.64 s
    e, t = derive([(10.0, 11.2)], pieces,
                  [dict(kind="BARGE", t=10.24, hop_end=10.24)])
    assert t["real_barge"] == 1 and not t["missed_barge"], t
    # false_barge: short sound, barge fired
    e, t = derive([(10.0, 10.5)], pieces,
                  [dict(kind="BARGE", t=10.24, hop_end=10.24)])
    assert t["false_barge"] == 1 and not t["real_barge"], t
    # missed_barge: long utterance, barge too late
    e, t = derive([(10.0, 11.2)], pieces,
                  [dict(kind="BARGE", t=11.0, hop_end=11.0)])
    assert t["missed_barge"] == 1 and not t["real_barge"], t
    # utterance outside playback is not judged
    e, t = derive([(12.5, 13.7)], pieces, [dict(kind="BARGE", t=12.6, hop_end=12.6)])
    assert sum(t.values()) == 0, t
    # late_endpoint: dead air 1.6 s
    e, t = derive([(4.0, 4.8)], [(9.5, 12.0)],
                  [dict(kind="ENDPOINT", t=6.4, hop_end=6.4)])
    assert t["late_endpoint"] == 1, t
    # early_cut_in: short-dead-air endpoint arms; utterance starts 0.2 s after
    e, t = derive([(5.0, 5.1), (5.3, 6.0)], pieces,
                  [dict(kind="ENDPOINT", t=5.12, hop_end=5.12)])
    assert t["early_cut_in"] == 1, t
    # bc_ok: caller speaks within 1 s after the backchannel; bc_intrusive: no speech
    e, t = derive([(8.0, 8.5)], [(7.0, 7.4)],
                  [dict(kind="BACKCHANNEL", t=7.2, hop_end=7.2)])
    assert t["bc_ok"] == 1 and not t["bc_intrusive"], t
    e, t = derive([], [(7.0, 7.4)],
                  [dict(kind="BACKCHANNEL", t=7.2, hop_end=7.2)])
    assert t["bc_intrusive"] == 1 and not t["bc_ok"], t
    print("live-outcomes selfcheck: ok (7 labels pinned)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", default="bench-results/live-shipping")
    ap.add_argument("--wavs", default=str(Path("bench-results/turn-layer-2026-11-06/live/in")))
    ap.add_argument("--events", choices=("teacher", "student"), default="teacher",
                    help="whose 8-vectors the rules replay (teacher = the existing ears)")
    ap.add_argument("--student", default="bench-results/student-l4-60/student.pt")
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--out", default=None, help="write per-capture episodes here")
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args()
    if args.selfcheck:
        return selfcheck()

    rows = analyze(args.shards, Path(args.wavs).expanduser(), args.events,
                   args.student, args.device)
    totals = {name: sum(r["totals"][name] for r in rows) for name in LABELS}
    print(f"captures {len(rows)}, seconds {sum(r['seconds'] for r in rows):.0f}")
    print("| capture | s | speech | pieces | ENDPOINT | BARGE | BC | "
          + " | ".join(LABELS) + " |")
    print("|---|" + "---:|" * (4 + len(LABELS)))
    for r in rows:
        print(f"| {r['sid'].replace('live-turn-', '')} | {r['seconds']:.0f} | "
              f"{r['speech']} | {r['pieces']} | {r['events']['ENDPOINT']} | "
              f"{r['events']['BARGE']} | {r['events']['BACKCHANNEL']} | "
              + " | ".join(str(r["totals"][n]) for n in LABELS) + " |")
    print(f"| **total** | {sum(r['seconds'] for r in rows):.0f} | "
          f"{sum(r['speech'] for r in rows)} | {sum(r['pieces'] for r in rows)} | "
          f"{sum(r['events']['ENDPOINT'] for r in rows)} | "
          f"{sum(r['events']['BARGE'] for r in rows)} | "
          f"{sum(r['events']['BACKCHANNEL'] for r in rows)} | "
          + " | ".join(str(totals[n]) for n in LABELS) + " |")
    if args.out:
        Path(args.out).write_text(json.dumps(dict(rows=rows, totals=totals), indent=1))


if __name__ == "__main__":
    main()
