"""Score the turn layer's events against Open Yap labelled ranges.

Step 4 of the smart-turn dataset plan: run the product's ears over clips whose
labels say what happened, and ask whether the events land where the labels say.

Why the clips are re-decoded rather than read from `clips/`: the model's window
is 8 s, and the shipped clips lead the mark by only 1.2 s. Scored at 1.2 s the
model is cold — its window and carried state have seen a fraction of what the
product sees. This script decodes LEAD_S before the turn end straight from the
corpus, so every decision frame has a full window.

Channels are the clip convention: ch0 = the turn ender (the model's "user"),
ch1 = the party taking the floor. `dir` says whether the source files swap.

The decision frame is the ender's last word end, LEAD_S into the window. An
event "lands" when it fires within TOL_S of that frame. Everything else the
model fires in the window counts as a false fire.

Usage:
  TYGER_BUNDLE=... python scripts/openyap-score.py \
    --manifest bench-results/openyap-ranges-2026-11-07/manifest_gated.jsonl \
    --sample 200 --out /tmp/score.jsonl
"""
import argparse
import json
import os
import random
import subprocess
import wave
from collections import Counter

import numpy as np

DATA_DEFAULT = "datasets/open-yap-1k_2026-11-07_flac_372fb0fd"
LEAD_S = 8.0
TAIL_S = 2.0
FRAME_S = 0.08
TOL_S = 0.32


def decode(conv: str, direction: str, t0: float, dur: float, data: str) -> dict:
    """Decode a window to the clip channel convention (ch0 = ender)."""
    cd = os.path.join(data, "conversations", conv)
    a = os.path.join(cd, "speaker_a.flac")
    b = os.path.join(cd, "speaker_b.flac")
    if direction == "b2a":
        a, b = b, a
    out = f"/tmp/score_{os.getpid()}.wav"
    subprocess.run(
        ["ffmpeg", "-v", "error", "-ss", f"{t0:.3f}", "-t", f"{dur:.3f}", "-i", a,
         "-ss", f"{t0:.3f}", "-t", f"{dur:.3f}", "-i", b,
         "-filter_complex",
         "[0:a]aresample=16000,aformat=channel_layouts=mono[x];"
         "[1:a]aresample=16000,aformat=channel_layouts=mono[y];"
         "[x][y]amerge=inputs=2[o]",
         "-map", "[o]", "-ac", "2", "-c:a", "pcm_s16le", out, "-y"], check=True)
    with wave.open(out) as w:
        raw = w.readframes(w.getnframes())
    os.remove(out)
    pcm = np.frombuffer(raw, np.int16).astype(np.float32) / 32768.0
    return {"ch0": pcm[0::2], "ch1": pcm[1::2]}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--data", default=DATA_DEFAULT)
    ap.add_argument("--kinds", default="handoff,silent_tail,overlap",
                    help="which labelled kinds to score")
    ap.add_argument("--sample", type=int, default=0, help="0 = every row")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--tol", type=float, default=TOL_S)
    ap.add_argument("--device", default="mps")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    kinds = set(args.kinds.split(","))

    rows = [json.loads(l) for l in open(args.manifest) if l.strip()]
    rows = [r for r in rows if r["kind"] in kinds]
    if args.sample and args.sample < len(rows):
        random.Random(args.seed).shuffle(rows)
        rows = rows[:args.sample]
    if not rows:
        print("no rows selected")
        return

    import sys
    sys.path.insert(0, "ports/tyger-student")
    from oracle import Oracle
    from featurize import run_session

    oracle = Oracle(device=args.device).load_bundle()

    out = []
    for i, r in enumerate(rows, 1):
        mark = r["mark"]
        gap = r["gap_ms"] / 1000.0
        # handoff/silent_tail: the decision is the ender's last word end, which
        # is `gap` before the mark. overlap: gap is negative (the next speaker
        # started first), so the decision is the interruption at the mark; using
        # mark - gap there lands after the mark and can run past the audio.
        decision = mark - gap if gap >= 0 else mark
        t0 = max(0.0, decision - LEAD_S)
        dur = LEAD_S + (mark - t0) + TAIL_S
        wavs = decode(r["conversation_id"], r.get("dir", "a2b"), t0, dur, args.data)
        frames, events = run_session(oracle, wavs)
        dec = decision - t0
        mode = frames["mode"]
        fdec = int(dec / FRAME_S)
        lead_speak = mode[max(0, fdec - 15):fdec]
        ev = [(round(f * FRAME_S, 2), k) for f, k in events if k != "FRAME"]
        landing = [(t, k) for t, k in ev if abs(t - dec) <= args.tol]
        row = dict(r)
        row.update(decision_s=round(dec, 2), events=ev,
                   n_events=len(ev), landing=landing,
                   speak_frac_lead=round(float((lead_speak == 1).mean()) if len(lead_speak) else 0.0, 2))
        out.append(row)
        if i % 25 == 0 or i == len(rows):
            print(f"  {i}/{len(rows)} scored", flush=True)

    print(f"\nscored {len(out)} clips at tol={args.tol}s")
    by = {}
    for r in out:
        by.setdefault(r["kind"], []).append(r)
    for kind, rs in sorted(by.items()):
        landed = [r for r in rs if r["landing"]]
        kinds_fired = Counter(k for r in rs for _t, k in r["landing"])
        any_fired = Counter(k for r in rs for _t, k in r["events"])
        speak = [r.get("speak_frac_lead", 0.0) for r in rs]
        print(f"  {kind:12s} n={len(rs):4d}  lands={len(landed):4d} ({len(landed)/len(rs):.0%})"
              f"  speak-mode lead={sum(speak)/max(1,len(speak)):.0%}"
              f"  landing kinds={dict(kinds_fired)}  all fired={dict(any_fired)}")
    if args.out:
        with open(args.out, "w") as f:
            for r in out:
                f.write(json.dumps(r) + "\n")


if __name__ == "__main__":
    main()
