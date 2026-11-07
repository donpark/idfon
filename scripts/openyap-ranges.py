"""Find labelled audio ranges in Open Yap 1k for smart-turn event testing.

Disk-conscious by construction. Pass 1 reads only the per-conversation JSON
(meta + both transcripts, ~160 MB for the whole corpus) and never touches the
297 GB of FLAC audio. Pass 2 (`--extract`) decodes only the ranges asked for,
so a 1,000-clip set reads a few minutes of audio, not the corpus.

Events come from word-level timestamps, which the corpus provides per speaker.
A turn is a maximal run of words with no gap over `--turn-gap-ms`. At each turn
boundary the next speaker's start decides the event:

    handoff      next starts 0-320 ms after the turn ends
    overlap      next starts inside the turn (the caller barges in)
    silent_tail  next starts 320-1200 ms after the turn ends
    long_pause   next starts over 1200 ms after (a gap, not an event)
    backchannel  a short next turn (< 300 ms) inside the turn

`lead_clean` records whether the clip's lead actually shows the event's premise:
the speaker whose turn ends is voiced in the lead and the other is silent. That
is the quality gate the 32-clip audit found missing (48% of handoffs had the
caller already talking).

    .venv/bin/python scripts/openyap-ranges.py \\
        --data datasets/open-yap-1k_2026-11-07_flac_372fb0fd \\
        --out ranges.jsonl [--events handoff,overlap] [--limit 20]

    .venv/bin/python scripts/openyap-ranges.py --extract ranges.jsonl \\
        --out /tmp/clips --clip-s 6

  --selfcheck   event derivation on synthetic word timestamps
"""
from __future__ import annotations

import argparse
import bisect
import glob
import json
import os
import subprocess
import sys
from collections import Counter

TURN_GAP_MS = 300.0
HANDOFF_MAX_MS = 320.0
SILENT_TAIL_MAX_MS = 1200.0
LONG_PAUSE_MAX_MS = 3000.0     # the negative class's outer edge, not an event
BACKCHANNEL_MAX_MS = 300.0
LEAD_S = 1.2
CLIP_S = 6.0

EVENTS = ("handoff", "overlap", "silent_tail", "backchannel", "long_pause")


def load_words(path: str) -> list[dict]:
    """Word spans from one speaker's transcript; non-words and un-timed entries dropped."""
    d = json.load(open(path))
    ws = d.get("words") or []
    return [w for w in ws
            if w.get("type", "word") == "word"
            and w.get("start") is not None and w.get("end") is not None]


def turns(ws: list[dict], gap_ms: float = TURN_GAP_MS) -> list[dict]:
    """Maximal runs of words with no inter-word gap over `gap_ms`."""
    out, cur = [], None
    for w in ws:
        if cur is None or (w["start"] - cur["end"]) * 1000 > gap_ms:
            if cur:
                out.append(cur)
            cur = {"start": w["start"], "end": w["end"], "n": 1}
        else:
            cur["end"] = max(cur["end"], w["end"])
            cur["n"] += 1
    if cur:
        out.append(cur)
    return out


def voiced(ws: list[dict], starts: list[float], lo: float, hi: float) -> float:
    """Fraction of [lo, hi) covered by word spans.

    `starts` is the precomputed start list; bisecting it keeps this O(log n)
    instead of rescanning every word per event (the corpus has ~15k words per
    conversation and ~300 events, so a full scan made the pass quadratic).
    """
    if hi <= lo:
        return 0.0
    i = max(0, bisect.bisect_left(starts, lo) - 1)
    span = 0.0
    for w in ws[i:]:
        if w["start"] >= hi:
            break
        a, b = max(w["start"], lo), min(w["end"], hi)
        if b > a:
            span += b - a
    return span / (hi - lo)


def classify(a_turns: list[dict], b_turns: list[dict]) -> list[dict]:
    """One event per A-turn boundary; B is the speaker who takes (or keeps) the floor."""
    out = []
    if not b_turns:
        return out
    b_starts = [b["start"] for b in b_turns]
    for a in a_turns:
        lo = bisect.bisect_left(b_starts, a["start"] - 1e-9)
        hi = bisect.bisect_right(b_starts, a["end"] + LONG_PAUSE_MAX_MS / 1000.0)
        for b in b_turns[lo:hi]:
            gap = (b["start"] - a["end"]) * 1000.0
            dur = (b["end"] - b["start"]) * 1000.0
            if gap < 0:
                kind = "backchannel" if dur < BACKCHANNEL_MAX_MS else "overlap"
            elif gap <= HANDOFF_MAX_MS:
                kind = "handoff"
            elif gap <= SILENT_TAIL_MAX_MS:
                kind = "silent_tail"
            else:
                kind = "long_pause"
            out.append({"kind": kind, "turn_start": round(a["start"], 3),
                        "turn_end": round(a["end"], 3), "mark": round(b["start"], 3),
                        "gap_ms": round(gap, 1), "next_ms": round(dur, 1)})
            break  # the first next turn is the one that takes the floor
    return out


def ranges(data: str, events: set[str], limit: int | None) -> list[dict]:
    """Every event in the corpus whose lead shows its premise."""
    dirs = sorted(glob.glob(os.path.join(data, "conversations", "*")))
    if limit:
        dirs = dirs[:limit]
    rows = []
    for i, d in enumerate(dirs, 1):
        meta_p = os.path.join(d, "meta.json")
        a_p = os.path.join(d, "speaker_a_transcript.json")
        b_p = os.path.join(d, "speaker_b_transcript.json")
        if not (os.path.exists(a_p) and os.path.exists(b_p)):
            continue
        meta = json.load(open(meta_p))
        a_ws, b_ws = load_words(a_p), load_words(b_p)
        a_st, b_st = [w["start"] for w in a_ws], [w["start"] for w in b_ws]
        a_t, b_t = turns(a_ws), turns(b_ws)
        # both directions: each speaker's turn end is a decision opportunity
        for a, b in ((a_t, b_t), (b_t, a_t)):
            for e in classify(a, b):
                if e["kind"] not in events:
                    continue
                lead_lo = max(0.0, e["mark"] - LEAD_S)
                # voiced fraction of the turn-ending speaker and of the next speaker
                ender = voiced(a_ws, a_st, lead_lo, e["mark"])
                nxt = voiced(b_ws, b_st, lead_lo, e["mark"])
                e["lead_ender"] = round(ender, 3)
                e["lead_next"] = round(nxt, 3)
                e["lead_clean"] = bool(ender >= 0.5 and nxt <= 0.1)
                e["conversation_id"] = meta["conversation_id"]
                e["relationship"] = meta.get("relationship")
                e["gap_ms_meta"] = meta.get("turn_taking_gap_ms")
                e["turns_per_minute"] = meta.get("turns_per_minute")
                e["duration_s"] = meta.get("duration_seconds")
                rows.append(e)
        if i % 200 == 0:
            print(f"  {i}/{len(dirs)} conversations, {len(rows)} events", flush=True)
    return rows


def extract(jsonl: str, out: str, data: str, clip_s: float = CLIP_S) -> int:
    """Decode only the requested ranges into stereo 16 kHz clips."""
    os.makedirs(out, exist_ok=True)
    rows = [json.loads(l) for l in open(jsonl) if l.strip()]
    for r in rows:
        conv = os.path.join(data, "conversations", r["conversation_id"])
        a_f = os.path.join(conv, "speaker_a.flac")
        b_f = os.path.join(conv, "speaker_b.flac")
        if not (os.path.exists(a_f) and os.path.exists(b_f)):
            print(f"! missing flac for {r['conversation_id']}", file=sys.stderr)
            continue
        t0 = max(0.0, r["mark"] - LEAD_S)
        name = f"{r['conversation_id']}_{r['kind']}_{r['mark']:.2f}.wav"
        subprocess.run(
            ["ffmpeg", "-v", "error", "-ss", f"{t0:.3f}", "-t", f"{clip_s:.3f}", "-i", a_f,
             "-ss", f"{t0:.3f}", "-t", f"{clip_s:.3f}", "-i", b_f,
             "-filter_complex",
             "[0:a]aresample=16000,aformat=channel_layouts=mono[a];"
             "[1:a]aresample=16000,aformat=channel_layouts=mono[b];"
             "[a][b]amerge=inputs=2[out]",
             "-map", "[out]", "-ac", "2", "-c:a", "pcm_s16le",
             os.path.join(out, name), "-y"], check=True)
    return len(rows)


def selfcheck() -> None:
    """Turn clustering, classification, and the lead gate on synthetic words."""
    def w(s, e):
        return {"start": s, "end": e, "type": "word"}

    # 1) turns: a 300 ms gap splits, a 200 ms gap does not
    ws = [w(0.0, 0.2), w(0.4, 0.6), w(0.9, 1.0)]
    t = turns(ws)
    assert len(t) == 2, t                       # 0.2->0.4 is 200 ms (same turn)
    assert t[0]["start"] == 0.0 and t[0]["end"] == 0.6, t[0]

    # 2) handoff: B starts 200 ms after A ends
    a = [{"start": 0.0, "end": 1.0, "n": 3}]
    b = [{"start": 1.2, "end": 2.0, "n": 3}]
    e = classify(a, b)[0]
    assert e["kind"] == "handoff" and abs(e["gap_ms"] - 200) < 1e-6, e

    # 3) overlap: B starts inside A's turn
    e = classify(a, [{"start": 0.6, "end": 2.0, "n": 3}])[0]
    assert e["kind"] == "overlap" and e["gap_ms"] < 0, e

    # 4) backchannel: short B turn inside A's turn
    e = classify(a, [{"start": 0.6, "end": 0.8, "n": 1}])[0]
    assert e["kind"] == "backchannel", e

    # 5) silent_tail: B starts 600 ms after A ends
    e = classify(a, [{"start": 1.6, "end": 2.4, "n": 3}])[0]
    assert e["kind"] == "silent_tail", e

    # 6) long_pause: B starts 1.6 s after A ends
    e = classify(a, [{"start": 2.6, "end": 3.4, "n": 3}])[0]
    assert e["kind"] == "long_pause", e

    # 7) lead gate: A voiced in the lead, B silent -> clean; B talks -> dirty
    a_ws = [w(0.0, 1.0)]
    a_st = [x["start"] for x in a_ws]
    assert voiced(a_ws, a_st, 0.4, 1.0) == 1.0
    b_ws = [w(1.05, 1.2)]
    assert voiced(b_ws, [x["start"] for x in b_ws], 0.4, 1.0) == 0.0
    c_ws = [w(0.4, 0.6)]
    assert voiced(c_ws, [x["start"] for x in c_ws], 0.4, 1.0) < 0.35
    print("selfcheck ok")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data", default="datasets/open-yap-1k_2026-11-07_flac_372fb0fd",
                    help="dataset root holding conversations/")
    ap.add_argument("--out", default=None, help="write ranges JSONL here")
    ap.add_argument("--events", default="handoff",
                    help=f"comma list from {','.join(EVENTS)}")
    ap.add_argument("--limit", type=int, default=None, help="first N conversations")
    ap.add_argument("--extract", default=None, help="materialise clips from a ranges JSONL")
    ap.add_argument("--clip-s", type=float, default=CLIP_S)
    ap.add_argument("--selfcheck", action="store_true")
    a = ap.parse_args()

    if a.selfcheck:
        return selfcheck()
    if a.extract:
        if not a.out:
            ap.error("--extract needs --out")
        n = extract(a.extract, a.out, a.data, a.clip_s)
        print(f"extracted {n} clips to {a.out}")
        return
    if not a.out:
        ap.error("--out is required (or --selfcheck / --extract)")

    events = {x.strip() for x in a.events.split(",") if x.strip()}
    bad = events - set(EVENTS)
    if bad:
        ap.error(f"unknown events {sorted(bad)}; choose from {','.join(EVENTS)}")

    rows = ranges(a.data, events, a.limit)
    with open(a.out, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

    print(f"\n{len(rows)} ranges -> {a.out}")
    print("by kind:", dict(Counter(r["kind"] for r in rows)))
    print("lead_clean:", dict(Counter((r["kind"], r["lead_clean"]) for r in rows)))
    convs = {r["conversation_id"] for r in rows}
    clean = sum(1 for r in rows if r["lead_clean"])
    print(f"conversations with events: {len(convs)}; clean-lead ranges: {clean}"
          f" ({clean / max(1, len(rows)):.0%})")


if __name__ == "__main__":
    main()
