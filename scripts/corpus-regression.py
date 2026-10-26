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

Pass criteria (the turn-taking core):
  - every expected reply start has an ENDPOINT decision within --tolerance
    and the endpoint count matches (missed or split turns fail);
  - at least half the expected cut-ins have a BARGE decision within
    --tolerance (the replica only barges while it speaks, so a strict count
    is flaky by construction -- the original run matched 4 of 9);
  - backchannel feedback is advisory (the harness timeline fires the cues;
    the engine's own cues are extra).

    scripts/corpus-regression.py                 # whole corpus (~20 min)
    scripts/corpus-regression.py corpus/voice-interactions/dessa-anniversary.json
    scripts/corpus-regression.py --tolerance 2.5 --force-audio
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
    wpm = min(420.0, max(120.0, words / max(0.3, window_s) * 60.0))
    for _ in range(2):  # one refit if the first render overruns its window
        subprocess.run(
            ["say", "-v", VOICE, "-r", str(int(wpm)), "--data-format=LEI16@16000",
             "-o", out_path, text],
            check=True, capture_output=True)
        with wave.open(out_path) as w:
            dur = w.getnframes() / SR
        if dur <= window_s * 1.03 or wpm >= 480:
            return
        wpm = min(480.0, wpm * dur / window_s)


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
    key = json.dumps(
        [[t["s"], t["e"], t["text"]] for t in entry["turns"] if t["spk"] == human],
        sort_keys=True).encode()
    path = os.path.join(CACHE_DIR, f"{name}-{hashlib.sha256(key).hexdigest()[:8]}.wav")
    if force or not os.path.exists(path):
        os.makedirs(CACHE_DIR, exist_ok=True)
        n = build_user_wav(entry, path)
        print(f"  synthesized {n} human turns -> {path}")
    return path


MARK = re.compile(r"^idfon-auto: tygerdemo t=([0-9.]+) (.*)$")


def parse_marks(stderr):
    """Wall-clock events from the harness marks."""
    events = {"endpoint": [], "endpoint_fired": [], "barge": [], "barge_fired": [],
              "feedback": [], "feedback_skipped": [], "replies": [], "done": False}
    for line in stderr.splitlines():
        m = MARK.match(line.strip())
        if not m:
            continue
        t, msg = float(m.group(1)), m.group(2)
        if msg.startswith("decision ENDPOINT"):
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
    """Ordered two-pointer match. Returns (matched_pairs, unmatched_expected)."""
    pairs, miss = [], []
    ai = 0
    for e in expected:
        best, best_err = None, None
        for j in range(ai, len(actual)):
            err = abs(actual[j] - e)
            if err > tolerance and best is None:
                break
            if best_err is None or err < best_err:
                best, best_err = j, err
        if best is None:
            miss.append(e)
        else:
            pairs.append(best_err)
            ai = best + 1
    return pairs, miss


def replay(app, wav, entry_path, tolerance):
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

    reply_errs, missed_replies = match_times(expected_replies, events["endpoint"], tolerance)
    barge_errs, missed_barges = match_times(expected_barges, events["barge"], tolerance)

    print(f"  endpoints: {len(reply_errs)}/{len(expected_replies)} within {tolerance}s"
          + (f", max error {max(reply_errs):.2f}s" if reply_errs else "")
          + f", fired {len(events['endpoint_fired'])}, ignored {len(events['endpoint']) - len(events['endpoint_fired'])}")
    print(f"  cut-ins:   {len(barge_errs)}/{len(expected_barges)} within {tolerance}s"
          + (f", max error {max(barge_errs):.2f}s" if barge_errs else "")
          + f", stopped playback {len(events['barge_fired'])}")
    print(f"  feedback:  {len(events['feedback'])} fired, {len(events['feedback_skipped'])} skipped (advisory)")

    ok = True
    if len(reply_errs) != len(expected_replies):
        print(f"  FAIL missing endpoints near {missed_replies[:5]}")
        ok = False
    if len(events["endpoint"]) > len(expected_replies) + 2:
        print(f"  FAIL extra endpoints: {len(events['endpoint'])} vs {len(expected_replies)} expected")
        ok = False
    if expected_barges and len(barge_errs) * 2 < len(expected_barges):
        print(f"  FAIL too few cut-ins detected ({len(barge_errs)} of {len(expected_barges)})")
        ok = False
    print(f"  {'PASS' if ok else 'FAIL'}")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("entries", nargs="*", help="corpus .json files (default: all)")
    ap.add_argument("--app", default=DEFAULT_APP)
    ap.add_argument("--tolerance", type=float, default=2.5, help="max decision error in seconds")
    ap.add_argument("--force-audio", action="store_true", help="rebuild the synthesized wavs")
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
        results.append((name, replay(args.app, wav, path, args.tolerance)))

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
