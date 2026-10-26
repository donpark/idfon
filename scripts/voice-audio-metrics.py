#!/usr/bin/env python3
"""Audio onset/energy metrics for voice calibration (the improvement
pipeline's sound scorer; docs/voice-audition.html carries the first findings).

For each wav: how the sound starts and how hot it opens.
  swell_ms   onset -> 90% of the first sound's peak. Human hesitations swell
             in over 150-300 ms; an exclamation hits within one 5 ms window.
  head_rms   RMS/peak of the first 150 ms: how loud the opening is.
  crest_db   peak vs average level: dynamic softness.
  pitch_hz   rough F0 estimate. **Identity metric: reported, never scored**
             (matching it would clone the reference voice, not its behavior).
  peak_dbfs  overall peak level.
  dur_s      duration.

    scripts/voice-audio-metrics.py a.wav b.wav        # table
    scripts/voice-audio-metrics.py --json --utmos *.wav  # + UTMOS quality
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

STYLE = ("swell_ms", "head_rms", "crest_db")  # scored against a target
IDENTITY = ("pitch_hz",)                        # reported only
HERE = os.path.dirname(os.path.abspath(__file__))
# The UTMOS runner needs torch; default to the repo's tyger venv.
UTMOS_PYTHON = os.environ.get(
    "UTMOS_PYTHON", os.path.join(HERE, "..", "ports", "tyger-coreai", ".venv", "bin", "python"))


def utmos_scores(paths):
    """{path: mos} via scripts/utmos-score.py (None when unavailable)."""
    runner = os.path.join(HERE, "utmos-score.py")
    if not (os.path.exists(UTMOS_PYTHON) and os.path.exists(runner)):
        return {}
    try:
        out = subprocess.run([UTMOS_PYTHON, runner, *paths],
                             capture_output=True, text=True, timeout=600)
        return json.loads(out.stdout or "{}")
    except Exception:
        return {}


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
    body = data[int(sr * 0.15):] or head
    rms_all = math.sqrt(sum(x * x for x in data) / len(data))
    mean_dbfs = 20 * math.log10(max(1e-9, rms_all / 32768))
    return {
        "file": path,
        "swell_ms": (full - onset) if onset is not None and full is not None else None,
        "onset_ms": onset,
        "head_rms": round(math.sqrt(sum(x * x for x in head) / max(1, len(head))) / peak, 3),
        "crest_db": round(20 * math.log10(peak / 32768) - mean_dbfs, 1),
        "pitch_hz": pitch_hz(data, sr),
        "peak_dbfs": round(20 * math.log10(peak / 32768), 1),
        "dur_s": round(len(data) / sr, 2),
    }


def pitch_hz(data, sr):
    """Rough F0: the best autocorrelation lag in the 60-400 Hz band, over the
    loudest 60 ms. Identity metric — coarse on purpose."""
    win = int(sr * 0.06)
    best_i = max(range(0, max(1, len(data) - win)), key=lambda i: sum(abs(x) for x in data[i:i + win]))
    seg = data[best_i:best_i + win]
    lo, hi = max(2, sr // 400), max(3, sr // 60)
    best_lag, best_corr = 0, 0.0
    for lag in range(lo, min(hi, len(seg) - 1)):
        corr = sum(seg[i] * seg[i + lag] for i in range(0, len(seg) - lag))
        if corr > best_corr:
            best_corr, best_lag = corr, lag
    return round(sr / best_lag, 1) if best_lag else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wavs", nargs="+")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--utmos", action="store_true", help="add the neural MOS quality score")
    args = ap.parse_args()
    rows = [m for p in args.wavs if (m := metrics(p))]
    if args.utmos:
        mos = utmos_scores([m["file"] for m in rows])
        for m in rows:
            m["mos"] = mos.get(m["file"])
    if args.json:
        print(json.dumps(rows))
        return
    with_mos = any("mos" in m for m in rows)
    header = f"{'file':36} {'swell':>7} {'head':>6} {'crest':>6} {'pitch':>7} {'peak':>7} {'dur':>6}"
    if with_mos:
        header += f" {'mos':>5}"
    print(header)
    for m in rows:
        swell = f"{m['swell_ms']} ms" if m["swell_ms"] is not None else "-"
        pitch = f"{m['pitch_hz']:.0f} Hz" if m.get("pitch_hz") else "-"
        line = (f"{m['file'].split('/')[-1]:36} {swell:>7} {m['head_rms']:>6} {m['crest_db']:>5} dB "
                f"{pitch:>7} {m['peak_dbfs']:>6} dB {m['dur_s']:>5}s")
        if with_mos:
            line += f" {m.get('mos') if m.get('mos') is not None else '-':>5}"
        print(line)


if __name__ == "__main__":
    main()
