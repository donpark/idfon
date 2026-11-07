"""Gate Open Yap ranges on the audio's own lead, not only transcript coverage.

The transcript gate (`lead_ender`/`lead_next` in openyap-ranges.py) counts the
fraction of the lead covered by *word spans*. It misses everything the
transcript does not spell: laughs, breaths, throat clears, noise. In the first
handoff clip audited, the next speaker vocalised for 240 ms before the ender's
last word and `lead_next` was 0.0 — the clip was scored clean and was not.

This pass reads each extracted clip's lead and measures channel dominance per
80 ms frame. A frame "belongs" to a speaker when that channel is 6 dB louder.
`audio_clean` keeps clips whose ender owns at least half the lead and whose next
speaker owns at most a tenth — the same 0.5/0.1 shape as the transcript gate,
but on energy.

Reads only the first ~1.2 s of each clip (a few MB), so it is cheap next to
extraction. Writes a gated manifest; deletes nothing.

Usage:
  python scripts/openyap-audio-gate.py \
    --manifest bench-results/openyap-ranges-2026-11-07/manifest.jsonl \
    --clips bench-results/openyap-ranges-2026-11-07/clips \
    --out bench-results/openyap-ranges-2026-11-07/manifest_gated.jsonl
"""
import argparse
import glob
import json
import os
import wave
from concurrent.futures import ThreadPoolExecutor

import numpy as np

SR = 16_000
HOP = int(0.08 * SR)
LEAD_S = 1.2
DOM_DB = 6.0


def lead_dominance(path: str, mark_in_clip: float) -> tuple[float, float]:
    """(fraction of lead frames the ender owns, fraction the next speaker owns)."""
    with wave.open(path) as w:
        raw = w.readframes(w.getnframes())
    pcm = np.frombuffer(raw, np.int16).astype(np.float32) / 32768.0
    c0, c1 = pcm[0::2], pcm[1::2]
    n = min(int(mark_in_clip * SR), len(c0))
    if n <= HOP:
        return 0.0, 0.0
    a = np.lib.stride_tricks.sliding_window_view(c0[:n], HOP)[::HOP]
    b = np.lib.stride_tricks.sliding_window_view(c1[:n], HOP)[::HOP]
    m = min(len(a), len(b))
    da = 20 * np.log10(np.sqrt((a[:m] ** 2).mean(axis=1)) + 1e-12)
    db = 20 * np.log10(np.sqrt((b[:m] ** 2).mean(axis=1)) + 1e-12)
    d = da - db
    return float((d > DOM_DB).mean()), float((d < -DOM_DB).mean())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--clips", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--workers", type=int, default=12)
    args = ap.parse_args()

    rows = [json.loads(l) for l in open(args.manifest) if l.strip()]
    index = {os.path.basename(p): p for p in glob.glob(os.path.join(args.clips, "*", "*.wav"))}

    def judge(r: dict):
        name = f"{r['conversation_id']}_{r['kind']}_{r['mark']:.2f}.wav"
        p = index.get(name)
        if not p:
            return None
        mark_in_clip = min(LEAD_S, r["mark"])
        ender_dom, next_dom = lead_dominance(p, mark_in_clip)
        r = dict(r)
        r["audio_ender_dom"] = round(ender_dom, 3)
        r["audio_next_dom"] = round(next_dom, 3)
        r["audio_clean"] = bool(ender_dom >= 0.5 and next_dom <= 0.1)
        return r

    kept = []
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        for r in ex.map(judge, rows):
            if r and r["audio_clean"]:
                kept.append(r)
    with open(args.out, "w") as f:
        for r in kept:
            f.write(json.dumps(r) + "\n")

    print(f"{len(rows)} transcript-clean rows -> {len(kept)} audio-clean ({len(kept)/max(1,len(rows)):.0%})")
    from collections import Counter
    print("by kind:", dict(Counter(r["kind"] for r in kept)))


if __name__ == "__main__":
    main()
