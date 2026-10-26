#!/usr/bin/env python3
"""The reaction-word calibration bench — the probe + score half of the
iterative voice-improvement pipeline (docs/voice-calibration.md).

Candidates are `slug|text` lines rendered through the ptts CLI (the mouth's
model), scored by scripts/voice-audio-metrics.py against a target sound
profile: how a human starts a hesitation (a 150-300 ms swell, a soft opening)
rather than an exclamation hit. With --utmos, UTMOS adds a quality floor: a
candidate never wins on target-distance while its predicted naturalness sits
below the target's own MOS.

    scripts/voice-reaction-bench.py                     # default candidates
    scripts/voice-reaction-bench.py --target ref.wav    # learn the target from audio
    scripts/voice-reaction-bench.py --target-dir refs/  # ... from a collection
    scripts/voice-reaction-bench.py --utmos --json-out out.json

The propose step is external (scripts/voice-autoresearch.py drives the loop).
"""
import argparse
import json
import os
import statistics
import subprocess
import sys

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
# measurements of natural speech; docs/voice-audition.html). Metrics the
# built-in target does not name are not scored. `mos_floor` is the UTMOS
# quality floor used when the target is not audio.
HUMAN_HESITATION = {"swell_ms": 180, "head_rms": 0.05, "mos_floor": 4.0}

# Scored metrics — keep in step with voice-audio-metrics.py STYLE. Identity
# metrics (pitch) are never scored: matching them would clone the reference
# voice rather than its behavior.
STYLE = ("swell_ms", "head_rms", "crest_db")


def batch_metrics(paths, utmos):
    """One metrics call for the whole batch (the UTMOS model loads once)."""
    cmd = [sys.executable, METRICS, "--json"]
    if utmos:
        cmd.append("--utmos")
    out = subprocess.run(cmd + paths, capture_output=True, text=True)
    rows = json.loads(out.stdout or "[]")
    return {r["file"]: r for r in rows}


def load_target(args, utmos):
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
    rows = list(batch_metrics(paths, utmos).values())
    swells = [m["swell_ms"] for m in rows if m["swell_ms"] is not None]
    heads = [m["head_rms"] for m in rows]
    if not rows or not heads:
        die(f"no usable target audio in {paths}")
    target = {
        "swell_ms": statistics.median(swells) if swells else HUMAN_HESITATION["swell_ms"],
        "head_rms": round(statistics.median(heads), 3),
    }
    crests = [m["crest_db"] for m in rows if m.get("crest_db") is not None]
    if crests:
        target["crest_db"] = round(statistics.median(crests), 1)
    moss = [m["mos"] for m in rows if m.get("mos") is not None]
    if moss:
        target["mos"] = round(statistics.median(moss), 3)
    return target, f"learned from {len(rows)} target wav(s)"


def die(msg):
    print(f"voice-reaction-bench: {msg}", file=sys.stderr)
    sys.exit(2)


def score(m, target):
    """Relative distance from the target sound over the style metrics, plus
    the UTMOS quality floor: never win on distance while sounding less
    natural than the target (or than the built-in floor)."""
    total, n = 0.0, 0
    for k in STYLE:
        v, t = m.get(k), target.get(k)
        if v is None or t is None:
            continue
        total += abs(v - t) / max(abs(t), 0.01)
        n += 1
    dist = total / max(1, n)
    floor = target.get("mos", target.get("mos_floor"))
    if m.get("mos") is not None and floor is not None:
        dist += max(0.0, floor - 0.25 - m["mos"]) * 4
    return round(dist, 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates", help="file of slug|text lines (default: the built-in set)")
    ap.add_argument("--target", help="one reference wav to learn the target profile from")
    ap.add_argument("--target-dir", help="a collection of reference wavs")
    ap.add_argument("--ptts", help="ptts CLI (default: on PATH)")
    ap.add_argument("--out", default=DEFAULT_OUT, help="where rendered wavs go")
    ap.add_argument("--json-out", help="write the full report as JSON")
    ap.add_argument("--utmos", action="store_true", help="add the UTMOS quality floor")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    lines = (open(args.candidates).read() if args.candidates else DEFAULT_CANDIDATES)
    candidates = [l.split("|", 1) for l in lines.splitlines() if l.strip() and not l.startswith("#")]
    target, target_note = load_target(args, args.utmos)
    if not args.quiet:
        print(f"target: {target}  ({target_note})")

    ptts = args.ptts or "ptts"
    if subprocess.run(["which", ptts], capture_output=True).returncode != 0:
        die(f"ptts CLI not found ({ptts}); build xn-ptts with --features cli")
    os.makedirs(args.out, exist_ok=True)

    rendered = []
    for slug, text in candidates:
        wav = os.path.join(args.out, f"{slug}.wav")
        subprocess.run([ptts, "--lang", "en", text, "-o", wav],
                       check=True, capture_output=True)
        rendered.append((slug, text, wav))
    measured = batch_metrics([w for _, _, w in rendered], args.utmos)

    rows = []
    for slug, text, wav in rendered:
        m = measured.get(wav)
        if not m:
            continue
        rows.append({"slug": slug, "text": text, **m, "score": score(m, target)})
    rows.sort(key=lambda r: r["score"])

    if not args.quiet:
        print(f"\n{'rank':>4}  {'slug':16} {'swell':>7} {'head':>6} {'mos':>5} {'score':>6}  text")
        for i, r in enumerate(rows, 1):
            swell = f"{r['swell_ms']} ms" if r["swell_ms"] is not None else "-"
            mos = f"{r['mos']:.2f}" if r.get("mos") is not None else "-"
            print(f"{i:>4}  {r['slug']:16} {swell:>7} {r['head_rms']:>6} {mos:>5} {r['score']:>6}  {r['text']}")
        if rows:
            print(f"\nbest: {rows[0]['text']}  (score {rows[0]['score']})")
    if args.json_out:
        json.dump({"target": target, "rows": rows}, open(args.json_out, "w"), indent=1)


if __name__ == "__main__":
    main()
