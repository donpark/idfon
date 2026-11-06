"""The rules' `mode` track for every replay harness — one derivation, one truth.

`rules.on_frame(sess, mode, ...)` branches on `mode == "speaking"` (the agent holds
the floor, so the yield head may fire a BARGE) and treats every other string as
listening. `mode` is therefore the app's floor state, `"listen"` / `"speaking"`,
fed by `VoiceAgentSession` (`TurnShadow.setMode`) — not the audio stream's name.
Replays used to pass `"response"` (the tyger-s2s stream name), which silently
disabled the barge branch for weeks.

This module is the only place a replay decides `mode`:

  * a shard/log `mode` track (`data.py`'s optional `mode`, 0=listen / 1=speaking)
    is used verbatim when present;
  * otherwise it is derived from the **agent channel's energy** (`ch1` of a
    `TurnCapture` stereo wav, or the decoded `ch1` of a corpus session).

Derivation (the `featurize.py` convention, extracted here so the corpus shards
and the replays cannot disagree): group the 80 ms frame energies into the 320 ms
hops the app updates `mode` on; a hop is loud when any of its four frames is
above `VAD_DB`; loud latches `speaking`; release after `RELEASE_HOPS` quiet hops
(1.92 s) to bridge the pauses inside one agent turn. `VAD_DB` is the rules' own
voiced threshold (`rules.py`, -50 dB), not a value fitted on barge outcomes.

What the derivation cannot know (report it, never hide it): the real floor comes
from the app, so this is a proxy. Playback that was scheduled but did not reach
the speaker still reads as `speaking` (the capture stores the playback bus, not
the room), and agent audio that leaked into the mic can make a caller frame look
voiced. The false-positive side is therefore measured, not assumed — see
`live_barge.py`.

No app, threshold, model, rule or fork change: this is a harness-side function.

    .venv/bin/python ports/tyger-student/mode_track.py --selfcheck
"""
import argparse

import numpy as np

VAD_DB = -50.0        # the rules' voiced threshold (`tyger constants.VAD_DB`)
RELEASE_HOPS = 6      # quiet 320 ms hops before speaking releases (1.92 s)
HOP_FRAMES = 4        # 80 ms frames per 320 ms hop (the app's mode cadence)

_MODES = ("listen", "speaking")


def next_speaking_mode(agent_loud, speaking, quiet_hops, release_hops=RELEASE_HOPS):
    """One hop: latch `speaking` on loud agent audio, release after quiet hops."""
    if agent_loud:
        return True, 0
    if not speaking:
        return False, 0
    quiet_hops += 1
    return (True, quiet_hops) if quiet_hops <= release_hops else (False, 0)


def frame_modes(agent_db=None, given=None, thr=VAD_DB, release_hops=RELEASE_HOPS,
                hop_frames=HOP_FRAMES):
    """Per-frame `mode` strings: `given` verbatim when present, else derived.

    agent_db  per-80 ms-frame agent-channel energy in dB (required when `given`
              is None; a silent channel derives all `"listen"`)
    given     a recorded mode track: 0/1 (or bool) per frame, or "listen" /
              "speaking" strings. Any other string is rejected — notably the
              stream name "response" that caused the replay bug.
    """
    if given is not None:
        arr = np.asarray(given)
        if arr.ndim != 1:
            raise ValueError(f"mode track must be 1-D, got shape {arr.shape}")
        if arr.dtype.kind in "biu":
            bad = sorted(set(np.unique(arr).tolist()) - {0, 1})
            if bad:
                raise ValueError(f"integer mode track must be 0/1, got {bad}")
            out = np.where(arr.astype(bool), "speaking", "listen")
        else:
            out = arr.astype(str)
            bad = sorted(set(np.unique(out).tolist()) - set(_MODES))
            if bad:
                raise ValueError(f"mode track must be 'listen'/'speaking', got {bad} "
                                 f"(a stream name such as 'response' is not a mode)")
        if agent_db is not None and len(agent_db) != len(out):
            raise ValueError(f"mode track has {len(out)} frames, agent_db {len(agent_db)}")
        return out

    if agent_db is None:
        raise ValueError("frame_modes needs a mode track (`given`) or agent energy (`agent_db`)")
    db = np.asarray(agent_db, np.float64).ravel()
    out = []
    speaking, quiet = False, 0
    for start in range(0, len(db), hop_frames):
        hop = db[start:start + hop_frames]
        speaking, quiet = next_speaking_mode(bool(np.any(hop > thr)), speaking, quiet,
                                            release_hops)
        out.extend(["speaking" if speaking else "listen"] * len(hop))
    return np.asarray(out)


def agent_audible(agent_db, lookup=2, thr=VAD_DB):
    """Per frame: was the agent's own channel loud within the last `lookup` frames?

    `mode` is bridged (it holds RELEASE_HOPS past the last loud hop so the state
    machine survives pauses inside one agent turn), so `mode == "speaking"` means
    "spoke in the last 1.92 s", not "is audible now". A barge needs the second
    meaning: stopping playback that already finished is not an interruption. Use
    this as the extra condition on the barge branch, never on the floor state.
    """
    loud = np.asarray(agent_db, np.float64).ravel() > thr
    out = np.zeros(len(loud), bool)
    for f in range(len(loud)):
        out[f] = bool(loud[max(0, f - lookup):f + 1].any())
    return out


def mode_at_hop(modes, hop, hop_frames=HOP_FRAMES):
    """The mode the app would feed for this 320 ms hop (its first frame's mode)."""
    return str(modes[min(hop * hop_frames, len(modes) - 1)])


def selfcheck():
    """Pin the derivation and the recorded-track guard (no models)."""
    # silent agent channel -> listening throughout
    assert set(frame_modes(np.full(40, -120.0))) == {"listen"}

    # one loud 80 ms frame inside hop 0: speaking starts with that hop and holds
    # for RELEASE_HOPS quiet hops (28 frames), then releases at frame 28
    db = np.full(40, -120.0)
    db[2] = -20.0
    m = frame_modes(db, thr=-50.0, release_hops=6)
    assert m[:28].tolist() == ["speaking"] * 28, m[:32]
    assert m[28:].tolist() == ["listen"] * 12, m[28:32]
    assert list(frame_modes(db, release_hops=0))[:8] == ["speaking"] * 4 + ["listen"] * 4

    # a recorded track wins and is normalised
    assert frame_modes(np.full(4, -120.0), given=np.array([0, 1, 1, 0])).tolist() == \
        ["listen", "speaking", "speaking", "listen"]
    assert frame_modes(given=np.array(["listen", "speaking"])).tolist() == ["listen", "speaking"]
    assert mode_at_hop(np.array(["speaking"] * 4 + ["listen"] * 4), 0) == "speaking"
    assert mode_at_hop(np.array(["speaking"] * 4 + ["listen"] * 4), 1) == "listen"

    # audible: one loud frame carries `lookup` frames of tolerance, then stops.
    # This is the barge condition; the mode track stays speaking for 28 frames here.
    db2 = np.full(20, -120.0)
    db2[2] = -20.0
    assert agent_audible(db2, lookup=0).sum() == 1
    assert agent_audible(db2, lookup=2)[:5].tolist() == [False, False, True, True, True]
    assert not agent_audible(db2, lookup=2)[5:].any()
    assert agent_audible(np.full(6, -120.0)).sum() == 0
    assert set(frame_modes(db2)[:4].tolist()) == {"speaking"} and not agent_audible(db2)[10]  # the tail

    # the old bug's value is not a mode
    for bad in (["response"] * 4, np.array([0, 2, 0, 0])):
        try:
            frame_modes(given=bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"accepted an invalid mode track: {bad!r}")
    try:
        frame_modes(np.zeros(3), given=np.array([0, 1]))
    except ValueError:
        pass
    else:
        raise AssertionError("accepted a mode track of the wrong length")
    try:
        frame_modes()
    except ValueError:
        pass
    else:
        raise AssertionError("derived a mode with neither a track nor agent energy")
    print("mode_track selfcheck: ok")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args()
    if args.selfcheck:
        selfcheck()
    else:
        ap.error("--selfcheck")
