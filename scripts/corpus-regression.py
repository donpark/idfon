#!/usr/bin/env python3
"""Replay the voice-interaction corpus through the real turn pipeline and
report pass or fail (docs/voice-gaps.html item 7; corpus/voice-interactions/
README.md). One command replaces the manual `-tygerdemo` run-and-diff.

The corpus keeps transcripts and timings, never audio (see the README). This
script recreates the caller's side deterministically: each human turn is
synthesized with macOS `say` (Samantha, rate fitted to its corpus window) and
placed at its corpus start time on a 16 kHz mono timeline. The wav is cached
outside the repo (audio is recreated, never committed).

The replay itself is `Idfon -tygerdemo <wav> <entry>` at wall-clock pace: the
app's real turn engine makes the decisions, the harness speaks the scripted
replies. Decision marks come back on stderr (`idfon-auto: tygerdemo t=...`).

Pass criteria: the replay is deterministic (fixed synthesis, seeded TTS), so
the gate is the recorded decision timeline: the first run stores a baseline
per entry (corpus/voice-interactions/baselines/) and later runs must
reproduce it (endpoint count and times tight; cut-in and feedback counts
within a small slack). That is what catches a voice change moving the
decisions. How close each run also comes to the ORIGINAL conversation is
reported as context: the replica is approximate by construction (synthesized
caller audio, scripted replies on its own timeline), so the original's
timings are a reference, not the gate.

    scripts/corpus-regression.py                 # whole corpus (~20 min)
    scripts/corpus-regression.py corpus/voice-interactions/dessa-anniversary.json
    scripts/corpus-regression.py --update-baseline   # accept the current behavior
"""
import argparse
import array
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS_DIR = os.path.join(ROOT, "corpus", "voice-interactions")
BASELINE_DIR = os.path.join(CORPUS_DIR, "baselines")
CACHE_DIR = os.path.expanduser("~/.cache/idfon/corpus-audio")
DEFAULT_APP = os.path.join(ROOT, "mac", "build", "Idfon.app", "Contents", "MacOS", "Idfon")
SR = 16_000
VOICE = "Samantha"


def die(msg):
    print(f"corpus-regression: {msg}", file=sys.stderr)
    sys.exit(2)


def synth_turn(text, window_s, out_path):
    """One human turn as a 16k mono wav, rate fitted to its corpus window."""
    words = max(1, len(text.split()))
    wpm = min(500.0, max(100.0, words / max(0.3, window_s) * 60.0))
    for _ in range(3):  # refit until the render fits its corpus window
        subprocess.run(
            ["say", "-v", VOICE, "-r", str(int(wpm)), "--data-format=LEI16@16000",
             "-o", out_path, text],
            check=True, capture_output=True)
        with wave.open(out_path) as w:
            dur = w.getnframes() / SR
        if dur <= window_s * 1.03 or wpm >= 550:
            return
        wpm = min(550.0, wpm * dur / window_s)


def build_user_wav(entry, cache_path):
    """Mix the entry's human turns into one timeline wav (additive, clipped)."""
    human = entry["speakers"]["human"]
    turns = [t for t in entry["turns"] if t["spk"] == human and t["text"].strip()]
    total = int(math.ceil((entry["duration_s"] + 1.0) * SR))
    buf = array.array("h", bytes(2 * total))
    with tempfile.TemporaryDirectory() as tmp:
        for i, turn in enumerate(turns):
            path = os.path.join(tmp, f"turn{i}.wav")
            synth_turn(turn["text"], turn["e"] - turn["s"], path)
            with wave.open(path) as w:
                data = array.array("h", w.readframes(w.getnframes()))
            off = int(turn["s"] * SR)
            for j, v in enumerate(data):
                k = off + j
                if k >= total:
                    break
                nv = buf[k] + v
                buf[k] = max(-32768, min(32767, nv))
    with wave.open(cache_path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(buf.tobytes())
    return len(turns)


def user_wav_for(entry, name, force):
    """Cached by content hash: corpus edits invalidate automatically."""
    human = entry["speakers"]["human"]
    key = b"fit3|" + json.dumps(
        [[t["s"], t["e"], t["text"]] for t in entry["turns"] if t["spk"] == human],
        sort_keys=True).encode()
    path = os.path.join(CACHE_DIR, f"{name}-{hashlib.sha256(key).hexdigest()[:8]}.wav")
    if force or not os.path.exists(path):
        os.makedirs(CACHE_DIR, exist_ok=True)
        n = build_user_wav(entry, path)
        print(f"  synthesized {n} human turns -> {path}")
    return path


MARK = re.compile(r"^idfon-auto: tygerdemo t=([0-9.]+) (.*)$")
SHADOW = re.compile(r"^idfon-auto: turn-shadow: (.*)$")


def parse_marks(stderr):
    """Wall-clock events from the harness marks."""
    events = {"stream_start": None, "endpoint": [], "endpoint_fired": [], "barge": [], "barge_fired": [],
              "feedback": [], "feedback_skipped": [], "replies": [], "done": False, "tier": "?"}
    for line in stderr.splitlines():
        line = line.strip()
        if line.startswith("idfon-auto: turn-shadow: tier "):
            events["tier"] = line.split("tier ", 1)[1]
            continue
        m = MARK.match(line)
        if not m:
            continue
        t, msg = float(m.group(1)), m.group(2)
        if msg == "user stream start":
            # The corpus timeline starts here: marks before it cover model
            # load and prep, and every event time is relative to this point.
            events["stream_start"] = t
        elif msg.startswith("decision ENDPOINT"):
            events["endpoint"].append(t)
            if msg.endswith("-> reply"):
                events["endpoint_fired"].append(t)
        elif msg.startswith("decision BARGE"):
            events["barge"].append(t)
            if msg.endswith("-> stop playback"):
                events["barge_fired"].append(t)
        elif msg.startswith("decision BACKCHANNEL"):
            events["feedback"].append(t)
        elif msg.startswith("feedback skipped"):
            events["feedback_skipped"].append(t)
        elif msg.startswith("reply ") and " start " in msg:
            events["replies"].append(int(msg.split()[1]))
        elif msg == "done":
            events["done"] = True
    return events


def match_times(expected, actual, tolerance):
    """Ordered match: each expected time takes the first actual within
    tolerance. Returns (errors, unmatched_expected)."""
    pairs, miss = [], []
    ai = 0
    for e in expected:
        while ai < len(actual) and actual[ai] < e - tolerance:
            ai += 1
        if ai < len(actual) and abs(actual[ai] - e) <= tolerance:
            pairs.append(abs(actual[ai] - e))
            ai += 1
        else:
            miss.append(e)
    return pairs, miss


def gate_baseline(name, events, update):
    """The regression gate: reproduce the recorded decision timeline."""
    path = os.path.join(BASELINE_DIR, f"{name}.json")
    if update or not os.path.exists(path):
        os.makedirs(BASELINE_DIR, exist_ok=True)
        json.dump({"tier": events["tier"], "endpoint": events["endpoint"],
                   "barge": events["barge"], "feedback": events["feedback"]},
                  open(path, "w"), indent=1)
        return True, "baseline written"
    b = json.load(open(path))
    if b["tier"] != events["tier"]:
        return False, f"tier changed ({b['tier']} -> {events['tier']}) — rerun with --update-baseline"
    # One marginal decision can move between runs (the replica paces in real
    # time and the second ear pairs hops from live playback), so the gate is
    # reproduction of the timeline, not perfection: all but two endpoints
    # within 2.5s, counts within two, cut-in and feedback counts within two.
    # A real regression moves the whole timeline and blows past these.
    errs, miss = match_times(b["endpoint"], events["endpoint"], 2.5)
    extra = len(events["endpoint"]) - len(errs)
    drift = f"max drift {max(errs):.2f}s" if errs else "no endpoints"
    if len(miss) > 2 or abs(len(events["endpoint"]) - len(b["endpoint"])) > 2:
        return False, f"endpoints moved: {len(errs)}/{len(b['endpoint'])} reproduced ({drift}), off near {['%.1f' % t for t in miss[:4]]}"
    if abs(len(events["barge"]) - len(b["barge"])) > 2:
        return False, f"cut-ins moved: {len(events['barge'])} vs {len(b['barge'])} in baseline"
    if abs(len(events["feedback"]) - len(b["feedback"])) > 2:
        return False, f"feedback moved: {len(events['feedback'])} vs {len(b['feedback'])} in baseline"
    return True, f"reproduces baseline ({len(errs)}/{len(b['endpoint'])} endpoints, {drift}, {len(events['barge'])} cut-ins)"


def replay(app, wav, entry_path, tolerance, update_baseline):
    name = os.path.splitext(os.path.basename(entry_path))[0]
    entry = json.load(open(entry_path))
    demo = entry["replay"]["demo"]
    expected_replies = demo["reply_starts"]
    expected_barges = demo["barges"]

    env = dict(os.environ)
    proc = subprocess.run(
        [app, "-tygerdemo", wav, entry_path],
        capture_output=True, text=True, timeout=entry["duration_s"] + 120, env=env)
    events = parse_marks(proc.stderr)
    if not events["done"]:
        print(f"  FAIL harness did not finish (exit {proc.returncode})")
        print("  --- stderr tail ---")
        print("\n".join(proc.stderr.splitlines()[-12:]))
        return False

    # Wall-clock marks -> corpus timeline.
    offset = events["stream_start"] or 0.0
    for key in ("endpoint", "endpoint_fired", "barge", "barge_fired",
                "feedback", "feedback_skipped"):
        events[key] = [t - offset for t in events[key]]

    reply_errs, missed_replies = match_times(expected_replies, events["endpoint"], tolerance)
    barge_errs, missed_barges = match_times(expected_barges, events["barge"], tolerance)

    print(f"  stream offset {offset:.1f}s (model load + prep)")
    print(f"  endpoints at {['%.1f' % t for t in events['endpoint']]}")
    print(f"  expected    at {['%.1f' % t for t in expected_replies]}")

    print(f"  endpoints: {len(reply_errs)}/{len(expected_replies)} within {tolerance}s"
          + (f", max error {max(reply_errs):.2f}s" if reply_errs else "")
          + f", fired {len(events['endpoint_fired'])}, ignored {len(events['endpoint']) - len(events['endpoint_fired'])}")
    print(f"  cut-ins:   {len(barge_errs)}/{len(expected_barges)} within {tolerance}s"
          + (f", max error {max(barge_errs):.2f}s" if barge_errs else "")
          + f", stopped playback {len(events['barge_fired'])}")
    print(f"  feedback:  {len(events['feedback'])} fired, {len(events['feedback_skipped'])} skipped (advisory)")

    ok = True
    # Context against the original conversation: the replica is approximate
    # (synthesized caller audio, scripted replies on its own timeline), so
    # these timings are a reference, not the gate.
    if len(reply_errs) != len(expected_replies):
        print(f"  reference: endpoints missing near {missed_replies[:5]}")
    if expected_barges and len(barge_errs) * 2 < len(expected_barges):
        print(f"  reference: only {len(barge_errs)} of {len(expected_barges)} original cut-ins reproduced")
    passed, why = gate_baseline(os.path.splitext(os.path.basename(entry_path))[0], events, update_baseline)
    print(f"  {why}")
    print(f"  {'PASS' if passed else 'FAIL'}")
    return passed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("entries", nargs="*", help="corpus .json files (default: all)")
    ap.add_argument("--app", default=DEFAULT_APP)
    ap.add_argument("--tolerance", type=float, default=2.5, help="reference matching window in seconds")
    ap.add_argument("--force-audio", action="store_true", help="rebuild the synthesized wavs")
    ap.add_argument("--update-baseline", action="store_true", help="accept the current decision timeline")
    args = ap.parse_args()

    if not os.path.exists(args.app):
        die(f"app not found: {args.app} (run mac/build.sh first)")
    if shutil.which("say") is None:
        die("macOS `say` not found (audio is recreated from timings with it)")
    if not any(l.startswith(VOICE) for l in
               subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout.splitlines()):
        die(f"voice {VOICE} not installed (set VOICE in this script)")

    entries = args.entries or sorted(
        os.path.join(CORPUS_DIR, f) for f in os.listdir(CORPUS_DIR) if f.endswith(".json"))
    if not entries:
        die("no corpus entries found")

    results = []
    for path in entries:
        name = os.path.splitext(os.path.basename(path))[0]
        entry = json.load(open(path))
        print(f"{name}: replaying {entry['duration_s']:.0f}s at wall-clock pace")
        wav = user_wav_for(entry, name, args.force_audio)
        results.append((name, replay(args.app, wav, path, args.tolerance, args.update_baseline)))

    print()
    failed = [n for n, ok in results if not ok]
    for n, ok in results:
        print(f"{'PASS' if ok else 'FAIL'}  {n}")
    if failed:
        print(f"\n{len(failed)} of {len(results)} entries FAILED")
        sys.exit(1)
    print(f"\nall {len(results)} entries passed")


if __name__ == "__main__":
    main()
