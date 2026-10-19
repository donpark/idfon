#!/usr/bin/env python3
"""Generate decision fixtures for the Rust port of tyger's turn rules.

Runs tyger-s2s's `rules.py` (the oracle) over scripted frame streams and writes
crates/idfon-voice/tests/data/turns-fixtures.json. `cargo test -p idfon-voice` then
asserts `src/turns.rs` produces identical events, flags and turn lengths.

Regenerate after any semantic change on either side:
    TYGER_S2S=~/dev/tyger-s2s python3 scripts/tyger-rules-fixtures.py
"""
import json
import os
import sys
from pathlib import Path

import numpy as np

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
sys.path.insert(0, S2S)

from app.plugins.ears.tyger import rules  # noqa: E402
from app.plugins.ears.tyger.session import EarsSession  # noqa: E402

OUT = Path(__file__).resolve().parents[1] / "crates" / "idfon-voice" / "tests" / "data" / "turns-fixtures.json"
HOP_N = 5120


def run_case(name, th, hops):
    sess = EarsSession(0, **th)
    case = {"name": name, "th": th, "hops": [], "expected": {"hop_reset": [], "mode_changed": [],
                                                            "words_events": [], "frame_records": []}}
    for hop in hops:
        mode = hop["mode"]
        user = np.full(HOP_N, hop.get("level", 0.1), np.float32)
        agent = np.full(HOP_N, hop.get("agent_level", 0.0), np.float32)
        if "set_words" in hop:
            sess.words = hop["set_words"]
        case["hops"].append({k: v for k, v in hop.items()})
        hr = rules.begin_hop(sess, user, agent, mode)
        mr = rules.switch_mode(sess, mode)
        wv = rules.words_event(sess, mode)
        case["expected"]["hop_reset"].append(bool(hr))
        case["expected"]["mode_changed"].append(bool(mr))
        case["expected"]["words_events"].append(wv)
        recs = []
        for i, (out, act) in enumerate(hop["frames"]):
            evs, final, reset = rules.on_frame(sess, mode, np.array(out, np.float32), act,
                                               left=len(hop["frames"]) - 1 - i)
            recs.append({
                "events": evs,
                "reset": bool(reset),
                "final_turn_len": int(len(final[1])) if final is not None else None,
                "final_segments": int(final[0]["segments"]) if final is not None else None,
            })
        case["expected"]["frame_records"].append(recs)
    return case


def frames(n, **kw):
    """n frames with default outputs; kw overrides any of the 8 outputs or act_db per list."""
    out = []
    for i in range(n):
        o = list(kw.get("out", [0.0, 0.0, 0.0, 0.0, 0.05, 0.1, 0.1, 0.2]))
        out.append([o, kw.get("act_db", -20.0)])
    return out


def merge(base, **over):
    for k, v in over.items():
        if k == "act_db":
            for fr in base:
                fr[1] = v
            continue
        idx = {"haz": 4, "yp": 5, "bcp": 6, "pep": 7, "s0": 0, "s1": 1, "s2": 2, "s3": 3}[k]
        for fr in base:
            fr[0][idx] = v
    return base


def main():
    cases = []

    f = merge(frames(16), pep=0.2) + merge(frames(6), pep=0.97)
    cases.append(run_case("endpoint_basic", {}, [{"mode": "listen", "frames": f}]))

    # MIN_SPEECH_MS gate: high p_end before 350 ms voiced must not end the turn
    f = merge(frames(3), pep=0.97) + merge(frames(4), pep=0.2) + merge(frames(8), pep=0.97)
    cases.append(run_case("endpoint_min_speech_gate", {}, [{"mode": "listen", "frames": f}]))

    # warmup gate: decisions do not count for the first 6 frames after a reset
    f = merge(frames(12), pep=0.97)
    cases.append(run_case("endpoint_warmup", {}, [{"mode": "listen", "frames": f}]))

    # backchannel: 2-frame debounce, 15-frame refractory, then fires again
    f = (merge(frames(10), bcp=0.1, pep=0.2) + merge(frames(2), bcp=0.93, pep=0.2)
         + merge(frames(15), bcp=0.93, pep=0.2) + merge(frames(4), bcp=0.93, pep=0.2))
    cases.append(run_case("backchannel_refractory", {}, [{"mode": "listen", "frames": f}]))

    # barge: 2-frame yield debounce; onset counts the user's speech stretch to the hop end
    f = merge(frames(8), yp=0.1) + merge(frames(4), yp=0.93)
    cases.append(run_case("barge_onset", {}, [{"mode": "speaking", "frames": f}]))

    # barge after a >8-frame quiet gap: no stretch -> onset 0
    f = (merge(frames(6), yp=0.1, act_db=-20.0) + merge(frames(10), yp=0.1, act_db=-70.0)
         + merge(frames(4), yp=0.93, act_db=-20.0))
    cases.append(run_case("barge_gap", {}, [{"mode": "speaking", "frames": f}]))

    # mode switches seed prev_state and clear the runs
    f = merge(frames(8), pep=0.2)
    cases.append(run_case("mode_switch", {}, [
        {"mode": "listen", "frames": list(f)},
        {"mode": "speaking", "frames": merge(frames(6), yp=0.93)},
        {"mode": "listen", "frames": merge(frames(10), pep=0.97)},
    ]))

    # random stream: every branch, tie-free values
    rng = np.random.default_rng(42)
    hops = []
    for h in range(400):
        mode = "speaking" if rng.random() < 0.3 else "listen"
        n = int(rng.integers(1, 6))
        fs = []
        for _ in range(n):
            out = [float(x) for x in rng.uniform(-4, 4, 4)] + [float(x) for x in rng.uniform(0.01, 0.99, 4)]
            out[7] = float(rng.uniform(0.01, 0.99))
            fs.append([out, float(rng.uniform(-80, -20))])
        hop = {"mode": mode, "level": float(rng.choice([0.0, 0.1, 0.3])), "frames": fs}
        if rng.random() < 0.05:
            hop["set_words"] = f"word{h}"
        hops.append(hop)
    cases.append(run_case("random_stream", {"ep_thr": 0.7771, "bc_thr": 0.6221, "barge_thr": 0.4113,
                                            "theta": 0.3337, "bc_refractory": 7}, hops))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(cases, indent=1))
    n_frames = sum(len(fr) for c in cases for fr in c["expected"]["frame_records"])
    print(f"wrote {OUT} ({len(cases)} cases, {n_frames} frames)")


if __name__ == "__main__":
    main()
