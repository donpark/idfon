#!/usr/bin/env python3
"""Audio onset/energy metrics for voice calibration (the improvement
pipeline's sound scorer; docs/voice-audition.html carries the first findings).

For each wav: how the sound starts and how hot it opens.
  swell_ms   onset -> 90% of the first sound's peak. Human hesitations swell
             in over 150-300 ms; an exclamation hits within one 5 ms window.
  head_rms   RMS/peak of the first 150 ms: how loud the opening is.
  peak_dbfs  overall peak level.
  dur_s      duration.

    scripts/voice-audio-metrics.py a.wav b.wav        # table
    scripts/voice-audio-metrics.py --json *.wav       # machine form
"""
import argparse
import array
import json
import math
import sys
import wave


def metrics(path):
    with wave.open(path) as w:
        n = w.getnframes()
        sr = w.getframerate()
        data = array.array("h", w.readframes(n))
    if not data:
        return None
    peak = max(1, max(abs(x) for x in data))
    win = max(1, int(sr * 0.005))
    env = [max(abs(x) for x in data[i:i + win]) / peak
           for i in range(0, min(len(data), int(sr * 0.4)), win)]
    first_peak = max(env[:60]) if env else 0
    onset = next((i * 5 for i, v in enumerate(env) if v > 0.10 * first_peak), None)
    full = next((i * 5 for i, v in enumerate(env) if v >= 0.90 * first_peak), None)
    head = data[:int(sr * 0.15)]
    return {
        "file": path,
        "swell_ms": (full - onset) if onset is not None and full is not None else None,
        "onset_ms": onset,
        "head_rms": round(math.sqrt(sum(x * x for x in head) / max(1, len(head))) / peak, 3),
        "peak_dbfs": round(20 * math.log10(peak / 32768), 1),
        "dur_s": round(len(data) / sr, 2),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wavs", nargs="+")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    rows = [m for p in args.wavs if (m := metrics(p))]
    if args.json:
        print(json.dumps(rows))
        return
    print(f"{'file':36} {'swell':>7} {'head':>6} {'peak':>7} {'dur':>6}")
    for m in rows:
        swell = f"{m['swell_ms']} ms" if m["swell_ms"] is not None else "-"
        print(f"{m['file'].split('/')[-1]:36} {swell:>7} {m['head_rms']:>6} {m['peak_dbfs']:>6} dB {m['dur_s']:>5}s")


if __name__ == "__main__":
    main()
