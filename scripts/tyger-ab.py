#!/usr/bin/env python3
"""A/B: TYGER's endpointing vs the energy endpointer idfon runs today (docs/voice-tyger.md).

Builds a small corpus of synthesized questions (macOS `say`) with known turn
boundaries — including the case that separates the two: a pause *inside* a turn —
then runs both deciders over it and prints the table.

  * TYGER: the real bundle via tyger-s2s's ReferenceEars (same rules.py as live).
  * Baseline: the energy endpointer that runs in the relay slot today
    (integrations/eve-idfon-voice/live-relay.mjs: |s16| > 300, 800 ms quiet tail,
    turns under 1 s dropped as blips) — ported line-for-line.

    .venv/bin/python scripts/tyger-ab.py --build          # make the corpus
    .venv/bin/python scripts/tyger-ab.py                   # run the comparison

Env: TYGER_S2S (tyger-s2s clone), TYGER_BUNDLE (the HF snapshot dir).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import wave

import numpy as np

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE")
SR = 16_000
HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "..", "bench-results", "tyger-ab")

# Each case is a list of turns; each turn is a list of phrases separated by the
# intra-turn pause. The turn's true end is the end of its last phrase.
PAUSE_S = 0.9
CASES = {
    "clean": [[("Could you please count from one to ten for me?",)], [("What time is it in Tokyo?",)]],
    "pause-inside": [[("So I was thinking about the trip",), ("and maybe we should leave a bit earlier",)]],
    "slow-thinker": [[("The thing is I am not really sure",), ("whether we can make it",), ("by eight o'clock tomorrow morning",)]],
}
PAUSES = {"pause-inside": 0.9, "slow-thinker": 1.1}
LEAD_S, TAIL_S, GAP_S = 0.5, 3.0, 2.5


def say_wav(path, text):
    aiff = path + ".aiff"
    subprocess.run(["say", "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, path], check=True)
    os.remove(aiff)


def read_mono(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2, f"{path}: need mono s16"
        rate = w.getframerate()
        x = (w.getnframes(), w.readframes(w.getnframes()))

    pcm = np.frombuffer(x[1], "<i2").astype(np.int16)
    if rate != SR:
        n = int(round(len(pcm) * SR / rate))
        pcm = np.interp(np.linspace(0, len(pcm), n, endpoint=False), np.arange(len(pcm)), pcm).astype(np.int16)
    return pcm


def build(corpus):
    os.makedirs(corpus, exist_ok=True)
    rng = np.random.default_rng(7)

    def silence(seconds):
        # room tone, not digital silence: real pauses have breath and noise
        return rng.integers(-40, 40, int(seconds * SR)).astype(np.int16)

    manifest = []
    for name, turns in CASES.items():
        parts, t, turn_ends = [], LEAD_S, []
        parts.append(silence(LEAD_S))
        for gi, turn in enumerate(turns):
            for pi, (phrase,) in enumerate(turn):
                tmp = os.path.join(corpus, "_tmp.wav")
                say_wav(tmp, phrase)
                sp = read_mono(tmp)
                parts.append(sp)
                t += len(sp) / SR
                if pi == len(turn) - 1:
                    turn_ends.append(t)  # the turn's true end: the last phrase's end
                else:
                    parts.append(silence(PAUSES.get(name, PAUSE_S)))
                    t += PAUSES.get(name, PAUSE_S)
            if gi < len(turns) - 1:
                parts.append(silence(GAP_S))
                t += GAP_S
        parts.append(silence(TAIL_S))
        out = os.path.join(corpus, f"{name}.wav")
        data = np.concatenate(parts)
        with wave.open(out, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(data.tobytes())
        manifest.append({"file": out, "turn_ends": turn_ends, "seconds": round(len(data) / SR, 1)})
    os.remove(os.path.join(corpus, "_tmp.wav"))
    with open(os.path.join(corpus, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"corpus: {len(manifest)} cases in {corpus}")


def baseline_endpoints(pcm):
    """The relay's energy endpointer (live-relay.mjs), on 20 ms frames."""
    THRESHOLD, QUIET, MIN = 300, int(SR * 0.8), 1.0  # MIN: seconds of speech before a turn counts (JS: samples)
    frame, speaking, quiet, started, ends = int(SR * 0.02), False, 0, 0.0, []
    for off in range(0, len(pcm) - frame + 1, frame):
        block = pcm[off : off + frame]
        t = (off + frame) / SR
        loud = bool((abs(block.astype(np.int32)) > THRESHOLD).any())
        if loud:
            if not speaking:
                speaking, started = True, t
            quiet = 0
            continue
        if not speaking:
            continue
        quiet += frame
        if quiet < QUIET:
            continue
        speaking = False
        if (t - QUIET / SR) - started >= MIN:  # speech before the quiet tail, minus blips
            ends.append(t)  # the moment the relay would act
    return ends


def tyger_endpoints(pcm, ep_thr=None):
    sys.path.insert(0, S2S)
    sys.path.insert(0, os.path.join(S2S, "scripts"))
    import torch

    from app.plugins.ears.tyger.session import EarsSession
    from validate.reference import ReferenceEars

    torch.set_num_threads(os.cpu_count() or 8)
    ears = ReferenceEars(BUNDLE, device="cpu")
    sess = EarsSession(0, **({"ep_thr": ep_thr} if ep_thr else {}))
    hop, out = 320 * SR // 1000, []
    x = pcm.astype(np.float32) / 32768.0
    for start in range(0, len(x) - hop + 1, hop):
        for ev in ears.feed(sess, x[start : start + hop], np.zeros(hop, np.float32), "listen"):
            if ev["kind"] == "ENDPOINT":
                out.append(((start + hop) / SR, ev.get("transcript", "")))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--ep-thr", type=float, default=None, help="override the endpoint threshold (default 0.91)")
    ap.add_argument("--corpus", default=CORPUS)
    args = ap.parse_args()
    if args.build:
        build(args.corpus)
        return

    with open(os.path.join(args.corpus, "manifest.json")) as f:
        manifest = json.load(f)
    print(f"{'case':<14} {'turn end':>8} | {'tyger fired':>11} {'latency':>7} {'verdict':>8} | "
          f"{'base fired':>10} {'latency':>7} {'verdict':>8}")
    stats = {"tyger": {"early": 0, "ok": 0, "miss": 0, "lat": []}, "base": {"early": 0, "ok": 0, "miss": 0, "lat": []}}
    for case in manifest:
        pcm = read_mono(case["file"])
        name = os.path.basename(case["file"]).replace(".wav", "")
        tyger = tyger_endpoints(pcm, args.ep_thr)
        base = baseline_endpoints(pcm)
        print(f"# {name}: tyger fired {[round(t, 2) for t, _ in tyger]}  base fired {[round(t, 2) for t in base]}")
        cursor = {"tyger": 0, "base": 0}
        for end in case["turn_ends"]:
            row = {}
            for who, fired in (("tyger", tyger), ("base", base)):
                times = [t for t, _ in fired] if who == "tyger" else fired
                first = None  # each endpoint matches at most one turn
                if cursor[who] < len(times) and times[cursor[who]] <= end + 2.0:
                    first = times[cursor[who]]
                    cursor[who] += 1
                if first is None:
                    row[who] = ("—", "—", "miss")
                    stats[who]["miss"] += 1
                elif first < end:
                    row[who] = (f"{first:.2f}", f"{first - end:+.2f}", "EARLY")
                    stats[who]["early"] += 1
                else:
                    row[who] = (f"{first:.2f}", f"{first - end:.2f}", "ok")
                    stats[who]["ok"] += 1
                    stats[who]["lat"].append(first - end)
            print(f"{name:<14} {end:8.2f} | {row['tyger'][0]:>11} {row['tyger'][1]:>7} {row['tyger'][2]:>8} | "
                  f"{row['base'][0]:>10} {row['base'][1]:>7} {row['base'][2]:>8}")
    for who in ("tyger", "base"):
        s = stats[who]
        med = sorted(s["lat"])[len(s["lat"]) // 2] if s["lat"] else float("nan")
        print(f"{who}: ok={s['ok']} early={s['early']} miss={s['miss']} median latency on clean endpoints = {med:.2f}s")


if __name__ == "__main__":
    main()
