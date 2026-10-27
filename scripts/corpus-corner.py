#!/usr/bin/env python3
"""Corner-case stress tests for the voice agent — the other direction from
corpus collection: enumerate the cases that trigger edge behavior, generate
the transcript that triggers each one, synthesize it, replay it through the
real turn pipeline, and score the decisions against expectations.

A case is a small conversation (user turns + scripted agent replies, like a
corpus entry) plus expected decisions: an event near a time, an event absent
in a window, an event count. `soft: True` expectations are characterization
notes — they report but do not fail (behavior not yet settled by design).

    scripts/corpus-corner.py                    # the whole suite (~15 min)
    scripts/corpus-corner.py --case barge-mid-reply
    scripts/corpus-corner.py --list
    scripts/corpus-corner.py --selftest         # no app, no audio

The harness is the corpus replay's `-tygerdemo` (real turn engine, scripted
replies); the caller audio is synthesized from the case timings with macOS
`say` — generated speech, so no recordings and no copyright surface.
Shortcut: speech-only triggers. Coughs, whispers and noise need real audio
and are not generated here yet.
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_APP = os.path.join(ROOT, "mac", "build", "Idfon.app", "Contents", "MacOS", "Idfon")
CACHE = os.path.expanduser("~/.cache/idfon/corpus-corner")

# Reuse the corpus replay's synthesis and mark parsing (same pipeline).
spec = importlib.util.spec_from_file_location(
    "corpus_regression", os.path.join(HERE, "corpus-regression.py"))
corpus_regression = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus_regression)

LONG_REPLY = (
    "That is a good question and there are a few things to say about it. "
    "Let me lay out the main points before I give you the short version."
)

# The case suite: triggers and expected decisions. Times are the synthesized
# caller timeline in seconds (the harness speaks replies at its own ENDPOINT
# decisions, so "during the reply" windows sit after the first turn ends).
CASES = [
    dict(id="mid-sentence-pause", soft=True,
         desc="a 2 s pause mid-thought must not end the turn",
         turns=[(0.5, 3.0, "I need to ask you about the trip next month and"),
                (5.0, 8.0, "what we should do about the hotel booking")],
         replies=[LONG_REPLY],
         expect=[dict(event="ENDPOINT", absent_in=(2.8, 5.2)),
                 dict(event="ENDPOINT", near=8.5, tol=1.5)]),
    dict(id="long-silence", soft=True,
         desc="4 s of dead air between turns must not invent a turn",
         turns=[(0.5, 3.0, "Are you there right now?"),
                (7.0, 10.0, "I had another question about my schedule today")],
         replies=[LONG_REPLY],
         expect=[dict(event="ENDPOINT", absent_in=(3.0, 7.0)),
                 dict(event="ENDPOINT", near=10.5, tol=1.5)]),
    dict(id="short-utterance",
         desc="a very short fragment is not a turn",
         turns=[(0.5, 0.8, "So"),
                (3.0, 6.0, "what I wanted to know about is the weather in Paris")],
         replies=[LONG_REPLY],
         expect=[dict(event="ENDPOINT", absent_in=(0.0, 2.5)),
                 dict(event="ENDPOINT", near=6.5, tol=1.5)]),
    dict(id="barge-mid-reply",
         desc="the caller cutting the reply stops playback",
         turns=[(0.5, 3.0, "Tell me everything about electric cars please"),
                (5.5, 6.3, "stop, I want to ask something else")],
         replies=[LONG_REPLY],
         expect=[dict(event="BARGE", near=5.9, tol=0.8)]),
    dict(id="barge-then-new-turn",
         desc="a cut-in becomes the next turn after it interrupts",
         turns=[(0.5, 3.0, "Tell me everything about electric cars please"),
                (5.5, 6.3, "stop that for a second"),
                (8.0, 11.0, "what I actually want is a good cheap city car")],
         replies=[LONG_REPLY, LONG_REPLY],
         expect=[dict(event="BARGE", near=5.9, tol=0.8),
                 dict(event="ENDPOINT", near=11.5, tol=1.5)]),
    dict(id="backchannel-during-reply", soft=True,
         desc="a listener murmur should not cut the reply",
         turns=[(0.5, 3.0, "Tell me everything about electric cars please"),
                (5.5, 6.0, "uh-huh")],
         replies=[LONG_REPLY],
         expect=[dict(event="BARGE", absent_in=(5.0, 6.5))]),
    dict(id="rapid-turns",
         desc="three quick turns stay three turns",
         turns=[(0.5, 2.0, "One thing I wanted to ask about today"),
                (2.4, 3.9, "and the second thing about tomorrow"),
                (4.3, 6.0, "and the last thing about the weekend trip")],
         replies=[LONG_REPLY],
         expect=[dict(event="ENDPOINT", count=3, tol=1)]),
    dict(id="long-monologue",
         desc="a 25 s monologue ends in one turn, not splits",
         turns=[(0.5, 26.0, "Well there is a lot to cover here and I want to be "
                            "clear about all of it before you answer me so listen "
                            "carefully because this matters a great deal to me and "
                            "I have been thinking about it for a very long time now")],
         replies=[LONG_REPLY],
         expect=[dict(event="ENDPOINT", near=26.5, tol=1.5, count=1, count_tol=1)]),
    dict(id="restart-self-correction",
         desc="a mid-sentence restart is one turn",
         turns=[(0.5, 4.0, "I need the flight for the fourteenth, actually "
                           "make that the fifteenth, in the morning")],
         replies=[LONG_REPLY],
         expect=[dict(event="ENDPOINT", near=4.5, tol=1.5, count=1, count_tol=1)]),
    dict(id="digits-spoken",
         desc="digit-heavy speech still turns over",
         turns=[(0.5, 4.0, "Call me back at five five five one two one two "
                           "tomorrow morning")],
         replies=[LONG_REPLY],
         expect=[dict(event="ENDPOINT", near=4.5, tol=1.5)]),
    dict(id="question-intonation",
         desc="a question ends the turn like a statement",
         turns=[(0.5, 3.0, "So what do you think about all of this then")],
         replies=[LONG_REPLY],
         expect=[dict(event="ENDPOINT", near=3.5, tol=1.5)]),
]


def case_entry(case):
    """The case as the corpus-replay input shape (human channel + timings)."""
    return {
        "speakers": {"human": 1},
        "duration_s": max(e for _, e, _ in case["turns"]) + 3.0,
        "turns": [{"spk": 1, "s": s, "e": e, "text": t} for s, e, t in case["turns"]],
    }


def case_script(case):
    """The -tygerdemo script shape: scripted replies, no reference events."""
    return {
        "replies": case.get("replies", []),
        "demo": {"bc": [], "ack": [], "barges": [], "reply_starts": [],
                 "user_turns": [[s, e] for s, e, _ in case["turns"]]},
    }


def run_case(app, case, keep=False):
    """Synthesize the caller, replay it, return the decision events."""
    os.makedirs(CACHE, exist_ok=True)
    wav = os.path.join(CACHE, f"{case['id']}.wav")
    corpus_regression.build_user_wav(case_entry(case), wav)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(case_script(case), f)
        script = f.name
    proc = subprocess.run([app, "-tygerdemo", wav, script],
                          capture_output=True, text=True,
                          timeout=case_entry(case)["duration_s"] + 120)
    os.unlink(script)
    events = corpus_regression.parse_marks(proc.stderr)
    return events if events["done"] else None


def evaluate(expect, events):
    """[(ok, is_soft, detail)] for one case's expectations."""
    out = []
    for rule in expect:
        soft = rule.get("soft", False)
        kind = rule["event"].lower()
        times = events.get(kind, [])
        if "absent_in" in rule:
            a, b = rule["absent_in"]
            hit = [t for t in times if a <= t <= b]
            out.append((not hit, soft,
                        f"{rule['event']} absent in [{a},{b}]" + (f": hit at {hit}" if hit else "")))
        if "near" in rule:
            hit = [t for t in times if abs(t - rule["near"]) <= rule.get("tol", 1.0)]
            out.append((bool(hit), soft,
                        f"{rule['event']} near {rule['near']}" + (f": none" if not hit else f": at {hit}")))
        if "count" in rule:
            ok = abs(len(times) - rule["count"]) <= rule.get("count_tol", 0)
            out.append((ok, soft, f"{rule['event']} count {len(times)} (want {rule['count']})"))
    return out


def selftest():
    events = {"endpoint": [1.0, 4.5], "barge": [], "feedback": []}
    out = evaluate([dict(event="ENDPOINT", absent_in=(2.0, 4.0)),
                    dict(event="ENDPOINT", near=4.5, tol=0.5),
                    dict(event="BARGE", absent_in=(0, 9)),
                    dict(event="ENDPOINT", count=2)], events)
    assert all(ok for ok, _, _ in out), out
    out = evaluate([dict(event="ENDPOINT", near=8.0)], events)
    assert not out[0][0], "a missing event must fail"
    out = evaluate([dict(event="ENDPOINT", near=8.0, soft=True)], events)
    assert not out[0][0] and out[0][1], "soft expectations report but do not fail"
    print("selftest OK")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", help="run one case by id")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--app", default=DEFAULT_APP)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return
    if args.list:
        for c in CASES:
            print(f"{c['id']:24} {c['desc']}")
        return
    if not os.path.exists(args.app):
        die(f"app not found: {args.app} (run mac/build.sh first)")

    suite = [c for c in CASES if not args.case or c["id"] == args.case]
    if not suite:
        die(f"no such case: {args.case}")
    failed = []
    for case in suite:
        print(f"\n== {case['id']}: {case['desc']}")
        events = run_case(args.app, case)
        if events is None:
            print("  FAIL harness did not finish")
            failed.append(case["id"])
            continue
        case_ok = True
        for ok, soft, detail in evaluate(case["expect"], events):
            tag = "ok  " if ok else ("WARN" if soft else "FAIL")
            print(f"  {tag} {detail}")
            if not ok and not soft:
                case_ok = False
        print(f"  {'PASS' if case_ok else 'FAIL'}")
        if not case_ok:
            failed.append(case["id"])
    print()
    if failed:
        print(f"{len(failed)} of {len(suite)} cases FAILED: {', '.join(failed)}")
        sys.exit(1)
    print(f"all {len(suite)} cases passed")


def die(msg):
    print(f"corpus-corner: {msg}", file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
