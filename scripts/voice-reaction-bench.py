#!/usr/bin/env python3
"""The reaction-word calibration bench — the first instance of the iterative
voice-improvement pipeline (point it at a target, score candidates, keep what
scores better; the lessons accumulate in the registry).

Candidates are `slug|text` lines rendered through the ptts CLI (the mouth's
model), scored by scripts/voice-audio-metrics.py against a target sound
profile: how a human starts a hesitation (a 150-300 ms swell, a soft opening)
rather than an exclamation hit.

    scripts/voice-reaction-bench.py                     # default candidates
    scripts/voice-reaction-bench.py --target ref.wav    # learn the target from audio
    scripts/voice-reaction-bench.py --target-dir refs/  # ... from a collection
    scripts/voice-reaction-bench.py --json-out out.json # machine form for the loop

The propose step is still external (edit the candidate list, or a mutator like
scripts/voice-gepa-mutate.py); this script is the probe + score half.
"""
import argparse
import array
import json
import math
import os
import statistics
import subprocess
import sys
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
METRICS = os.path.join(HERE, "voice-audio-metrics.py")
DEFAULT_OUT = os.path.expanduser("~/.cache/idfon/reaction-bench")

# The calibration set: hesitation shapes to compare.
DEFAULT_CANDIDATES = """\
um-leadin|Um, one moment.
so-um|So, um, one moment.
letssee-um|Let's see. Um, one moment.
hmm-lower|hmm, let me check.
well|Well, one moment.
letmesee|Let me see. One moment.
mhm|Mhm.
hmm|Hmm.
um-alone|Um.
uhm-leadin|uhm, one moment.
yeah|Yeah.
right|Right.
"""

# Built-in target: how humans start a hesitation (the 2026-10-26 onset
# measurements of natural speech; docs/voice-audition.html).
HUMAN_HESITATION = {"swell_ms": 180, "head_rms": 0.05}


def load_target(args):
    paths = []
    if args.target:
        paths = [args.target]
    elif args.target_dir:
        paths = sorted(
            os.path.join(args.target_dir, f)
            for f in os.listdir(args.target_dir) if f.endswith(".wav")
        )
    if not paths:
        return dict(HUMAN_HESITATION), "built-in human-hesitation profile"
    rows = [m for p in paths if (m := one_metrics(p))]
    swells = [m["swell_ms"] for m in rows if m["swell_ms"] is not None]
    heads = [m["head_rms"] for m in rows]
    if not rows or not heads:
        die(f"no usable target audio in {paths}")
    target = {
        "swell_ms": statistics.median(swells) if swells else HUMAN_HESITATION["swell_ms"],
        "head_rms": round(statistics.median(heads), 3),
    }
    return target, f"learned from {len(rows)} target wav(s)"


def one_metrics(path):
    out = subprocess.run([sys.executable, METRICS, "--json", path],
                         capture_output=True, text=True).stdout
    rows = json.loads(out or "[]")
    return rows[0] if rows else None


def die(msg):
    print(f"voice-reaction-bench: {msg}", file=sys.stderr)
    sys.exit(2)


def score(m, target):
    """Distance from the target sound: lower is closer to how humans start."""
    s = m["swell_ms"] if m["swell_ms"] is not None else 0
    return round(abs(s - target["swell_ms"]) / target["swell_ms"]
                 + abs(m["head_rms"] - target["head_rms"]) / max(0.01, target["head_rms"]), 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates", help="file of slug|text lines (default: the built-in set)")
    ap.add_argument("--target", help="one reference wav to learn the target profile from")
    ap.add_argument("--target-dir", help="a collection of reference wavs")
    ap.add_argument("--ptts", help="ptts CLI (default: on PATH)")
    ap.add_argument("--out", default=DEFAULT_OUT, help="where rendered wavs go")
    ap.add_argument("--json-out", help="write the full report as JSON")
    args = ap.parse_args()

    lines = (open(args.candidates).read() if args.candidates else DEFAULT_CANDIDATES)
    candidates = [l.split("|", 1) for l in lines.splitlines() if l.strip() and not l.startswith("#")]
    target, target_note = load_target(args)
    print(f"target: swell {target['swell_ms']} ms, head {target['head_rms']}  ({target_note})")

    ptts = args.ptts or "ptts"
    if subprocess.run(["which", ptts], capture_output=True).returncode != 0:
        die(f"ptts CLI not found ({ptts}); build xn-ptts with --features cli")
    os.makedirs(args.out, exist_ok=True)

    rows = []
    for slug, text in candidates:
        wav = os.path.join(args.out, f"{slug}.wav")
        subprocess.run([ptts, "--lang", "en", text, "-o", wav],
                       check=True, capture_output=True)
        m = one_metrics(wav)
        if not m:
            continue
        rows.append({"slug": slug, "text": text, **m, "score": score(m, target)})
    rows.sort(key=lambda r: r["score"])

    print(f"\n{'rank':>4}  {'slug':16} {'swell':>7} {'head':>6} {'score':>6}  text")
    for i, r in enumerate(rows, 1):
        swell = f"{r['swell_ms']} ms" if r["swell_ms"] is not None else "-"
        print(f"{i:>4}  {r['slug']:16} {swell:>7} {r['head_rms']:>6} {r['score']:>6}  {r['text']}")
    if rows:
        print(f"\nbest: {rows[0]['text']}  (score {rows[0]['score']})")
    if args.json_out:
        json.dump({"target": target, "rows": rows}, open(args.json_out, "w"), indent=1)


if __name__ == "__main__":
    main()
