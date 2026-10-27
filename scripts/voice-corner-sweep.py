#!/usr/bin/env python3
"""Corner-case sweeps: generated trigger cases, replayed through the real
turn pipeline, reported as behavior measurements (docs/voice-calibration.md).

Where `corpus-corner.py` pins settled behavior with hand-written expectations,
this enumerates the trigger AXES programmatically — gap length, cut-in depth,
monologue length, fragment gaps — and reports the engine's effective
thresholds as a curve. A sweep is a measurement first: only the corner suite's
hard expectations are "correct"; here the question is WHERE behavior changes
(the improvement pipeline's probes).

    scripts/voice-corner-sweep.py                    # the whole matrix (~1 min)
    scripts/voice-corner-sweep.py --sweep gap        # one axis
    scripts/voice-corner-sweep.py --app PATH/Idfon   # shipping-chain replay
    scripts/voice-corner-sweep.py --json-out out.json
    scripts/voice-corner-sweep.py --selftest         # no app, no audio

The cases are corpus-corner shapes (ptts-synthesized caller, one voice
engine, different voices). The default runner replays them through the
REFERENCE engine headless (tyger-replay.py) — the decision layer the
shipping chain is parity-gated to — so a sweep costs seconds per case and
never spins up an app; `--app` re-runs any sweep through the shipping chain.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("cc", os.path.join(HERE, "corpus-corner.py"))
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)
cr = cc.corpus_regression

# The default runner is the REFERENCE engine (tyger-replay.py, headless):
# a sweep measures the decision layer (model + rules), parity-gated to the
# shipping chain — no app bootstrap, no audio engine, seconds per case.
# `--app` replays through the shipping chain when that is the question.
ORACLE = os.environ.get("TYGER_PYTHON", os.path.join(ROOT, "ports/tyger-coreai/.venv/bin/python"))
S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/github/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE", os.path.expanduser(
    "~/.cache/huggingface/hub/models--nineninesix--tyger/snapshots/a5d4d73bb74fa4a7082dcd4387e44a1e5ac151b6"))
REPLAY = os.path.join(HERE, "tyger-replay.py")
# mps: ~10-20x over the calibrated cpu path (float-noise caveat); cpu for
# exact reference numbers.
DEVICE = os.environ.get("TYGER_DEVICE", "mps")

LONG_REPLY = cc.LONG_REPLY

# The generated matrix. Each case: (id, turns, replies) — expectations are
# derived from the marks, not written down.
def gap_cases():
    """Two turns separated by gap g: where does an ENDPOINT land (the
    engine's effective inter-turn gap threshold)?"""
    out = []
    for g in (0.2, 0.4, 0.6, 0.9, 1.2, 1.6, 2.0, 2.5):
        b = 3.0 + g
        out.append(dict(
            id=f"gap-{str(g).replace('.', '')}",
            turns=[(0.5, 3.0, "One thing I wanted to ask about today"),
                   (b, b + 2.3, "and the second thing about tomorrow")],
            replies=[LONG_REPLY]))
    return out


def fragment_cases():
    """A bare fragment then a real turn after gap g: when does the fragment
    become a turn of its own?"""
    out = []
    for g in (1.2, 1.8, 2.2, 3.0):
        b = 1.0 + g
        out.append(dict(
            id=f"fragment-{str(g).replace('.', '')}",
            turns=[(0.5, 0.9, "So"),
                   (b, b + 2.5, "what I wanted to know about is the weather in Paris")],
            replies=[LONG_REPLY]))
    return out


def cutin_cases():
    """A cut-in at a fixed time over the reply: does playback stop (barge)?
    The actual overlap depth is computed from the reply-start mark."""
    out = []
    for at in (5.0, 6.5, 9.0):
        out.append(dict(
            id=f"cutin-{str(at).replace('.', '')}",
            turns=[(0.5, 3.0, "Tell me everything about electric cars please"),
                   (at, at + 1.8, "stop that for a second please")],
            replies=[LONG_REPLY]))
    return out


def monologue_cases():
    """One long turn: how often does the engine split it? Windows are natural
    speech rate (the 2026-10-26 lesson): the 18-word sentence runs ~7 s."""
    sentence = ("Well there is a lot to cover here and I want to be clear "
                "about all of it before you answer me ")
    out = []
    for n in (2, 4, 6):
        out.append(dict(
            id=f"monologue-{n}",
            turns=[(0.5, 0.5 + n * 7.0, sentence * n)],
            replies=[LONG_REPLY]))
    return out


SWEEPS = {
    "gap": gap_cases,
    "fragment": fragment_cases,
    "cutin": cutin_cases,
    "monologue": monologue_cases,
}


def run_case_oracle(case, agent_at=None):
    """Headless replay through the reference engine. `agent_at`: the seconds
    mark at which the scripted reply starts on the agent channel (the second
    ear — cut-in sweeps); None = listen mode, agent silent."""
    user = cr.user_wav_for(cc.case_entry(case), case["id"], False)
    agent = None
    if agent_at is not None:
        entry = {"speakers": {"human": 1}, "duration_s": agent_at + 30.0,
                 "turns": [{"spk": 1, "s": agent_at, "e": agent_at + 20.0,
                            "text": case["replies"][0]}]}
        agent = cr.user_wav_for(entry, case["id"] + "-agent", False)
    cmd = [ORACLE, REPLAY, "--wav", user, "--device", DEVICE,
           "--mode", "listen" if agent is None else "speaking"]
    if agent is not None:
        cmd += ["--agent", agent]
    env = dict(os.environ, TYGER_S2S=S2S, TYGER_BUNDLE=BUNDLE)
    run = subprocess.run(cmd, capture_output=True, text=True, env=env)
    events = {"endpoint": [], "barge": [], "feedback": [],
              "replies": [agent_at] if agent_at is not None else [],
              "done": run.returncode == 0}
    for line in run.stdout.splitlines():
        m = re.match(r"t=\s*([\d.]+)\s+(\w+)", line)
        if not m:
            continue
        t, kind = float(m.group(1)), m.group(2)
        if kind == "ENDPOINT":
            events["endpoint"].append(t)
        elif kind == "BARGE":
            events["barge"].append(t)
        elif kind == "BACKCHANNEL":
            events["feedback"].append(t)
    return events


def measure(case, events):
    """Behavior facts for one case (the marks are stream-timeline seconds)."""
    turns = case["turns"]
    return {
        "case": case["id"],
        "spans": [(s, e) for (s, e, _) in turns],
        "gaps": [round(turns[i + 1][0] - turns[i][1], 2) for i in range(len(turns) - 1)],
        "endpoints": events.get("endpoint", []),
        "barges": events.get("barge", []),
        "reply_starts": events.get("replies", []),
        "done": events.get("done", False),
    }


def where(row, t):
    """Classify a decision time against the turn slots: in a slot, in a gap,
    or after everything. Slots are synthesis windows — rendered speech can
    end early, so 'in a slot' is not exactly 'during speech'."""
    for (s, e) in row["spans"]:
        if s <= t <= e:
            return "in a turn slot"
    if t > row["spans"][-1][1]:
        return "after turn end"
    return "in a gap"


def dedupe(times, tol=0.5):
    """The reference emits one event per frame while a condition holds;
    collapse repeats into single decisions."""
    out = []
    for t in times:
        if not out or t - out[-1] > tol:
            out.append(t)
    return out


def report_gap(rows):
    print("== gap sweep: where does an ENDPOINT land around two turns?")
    threshold = None
    for row in rows:
        gap = row["gaps"][0]
        marks = [f"{t}s ({where(row, t)})" for t in dedupe(row["endpoints"])] or ["NONE"]
        split = any(where(row, t) == "in a gap" for t in row["endpoints"])
        if threshold is None and split:
            threshold = gap
        print(f"  gap {gap:>4}s: {', '.join(marks)}")
    print(f"  => split in the gap from ~{threshold}s up" if threshold
          else "  => the two turns never merge (no endpoint in any gap)")


def report_fragment(rows):
    print("== fragment sweep: when does a bare fragment become its own turn?")
    for row in rows:
        gap = row["gaps"][0]
        marks = [f"{t}s ({where(row, t)})" for t in dedupe(row["endpoints"])] or ["NONE"]
        print(f"  gap {gap:>4}s: {', '.join(marks)}")
    print("  => if the first endpoint lands before the real turn regardless of"
          " gap, the fragment is a turn at a fixed clock")


def report_cutin(rows):
    print("== cut-in sweep: does a cut-in over the reply stop playback?")
    for row in rows:
        start = row["reply_starts"][0] if row["reply_starts"] else None
        cut_at = row["spans"][1][0]
        depth = round(cut_at - start, 2) if start is not None else None
        fired = dedupe(row["barges"])
        print(f"  cut-in @{cut_at}s (depth {depth}s into the reply): "
              f"barge at {fired if fired else 'NONE'}")
    print("  => note: the turn model is gain-invariant (2026-10-27); loudness"
          " is not a barge lever, onset depth is.")


def report_monologue(rows):
    print("== monologue sweep: how often does one turn split?")
    for row in rows:
        (s, e) = row["spans"][0]
        print(f"  ~{e - s:.0f}s speech: "
              f"{len(row['endpoints'])} endpoint(s) at {row['endpoints'] or '[]'}")


REPORTS = {
    "gap": report_gap,
    "fragment": report_fragment,
    "cutin": report_cutin,
    "monologue": report_monologue,
}


def selftest():
    # classification: gap / during / after against the turn spans.
    case = dict(id="g", turns=[(0.5, 3.0, "a"), (3.6, 5.9, "b")], replies=[])
    row = measure(case, {"endpoint": [3.3], "barge": [], "replies": [], "done": True})
    assert row["gaps"] == [0.6], row
    assert where(row, 3.3) == "in a gap", row
    assert where(row, 4.0) == "in a turn slot", row
    assert where(row, 6.2) == "after turn end", row
    print("selftest OK")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sweep", choices=sorted(SWEEPS), help="run one sweep")
    ap.add_argument("--app", help="replay through the shipping chain instead "
                    "of the headless reference engine (path to Idfon binary)")
    ap.add_argument("--json-out", help="write the measurements as JSON")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return

    def run(case):
        if args.app:
            return cc.run_case(args.app, case)
        return run_case_oracle(case)

    out = {}
    for name, build in SWEEPS.items():
        if args.sweep and name != args.sweep:
            continue
        rows = []
        for case in build():
            print(f"  running {case['id']} ...", file=sys.stderr)
            if name == "cutin" and not args.app:
                # closed-loop approximation: pass 1 finds the engine's own
                # reply start (first endpoint), pass 2 plays the reply there.
                first = run_case_oracle(case)
                start = (first["endpoint"] or [4.0])[0] + 0.3
                events = run_case_oracle(case, agent_at=start)
            else:
                events = run(case)
            if events is None or not events["done"]:
                print(f"  {case['id']}: FAIL harness did not finish")
                continue
            rows.append(measure(case, events))
        out[name] = rows
        REPORTS[name](rows)
        print()
    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(out, f, indent=1)
        print(f"measurements -> {args.json_out}")


if __name__ == "__main__":
    main()
