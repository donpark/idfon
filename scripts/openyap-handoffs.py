"""Floor handoffs from the audio: the agent stops, the caller starts.

This selects the event from the *audio* rather than from the model's fires, which
is what makes it a reference: every clip is a place where the agent was speaking
and the caller then took the floor, so the listener is always judging the same
thing. Sampling fires instead only ever measures precision -- a clip where the
agent was never audible cannot answer "did the caller cut in".

A handoff is: an agent run of >= `--min-agent-ms`, a gap of at most
`--max-gap-ms`, then a caller run of at least `--min-caller-ms`. The mark is the
caller's onset, so "Yes" means the caller's utterance at the mark is a turn
rather than a filler, a noise, or the tail of something already over.

    .venv/bin/python scripts/openyap-handoffs.py --wavs /tmp/openyap/wav \\
        --clips /tmp/openyap/handoffs --sample 30 [--shards <dir> for model catch]

  --selfcheck   handoff detection and clip arithmetic on synthetic frames
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import subprocess
import sys
import wave

import numpy as np

VAD = 0.00316      # -50 dBFS, the rules' voiced threshold
FRAME_S = 0.08
CLIP_S = 6.0
LEAD_S = 0.8       # how much agent speech the clip opens with


def energy(path: str, secs: float = 300.0) -> tuple[np.ndarray, np.ndarray]:
    with wave.open(path) as w:
        sr = w.getframerate()
        raw = w.readframes(min(w.getnframes(), int(sr * secs)))
    a = np.frombuffer(raw, np.int16).reshape(-1, 2).astype(np.float32) / 32768.0
    hop = int(sr * FRAME_S)
    f = lambda x: np.array([np.sqrt(np.mean(x[i:i + hop] ** 2)) for i in range(0, len(x) + 1 - hop, hop)])
    return f(a[:, 0]), f(a[:, 1])


def runs(voiced: np.ndarray) -> list[tuple[int, int]]:
    """Maximal [start, end) runs of voiced frames."""
    out, start = [], None
    for i, v in enumerate(voiced):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append((start, i)); start = None
    if start is not None:
        out.append((start, len(voiced)))
    return out


def handoffs(caller: np.ndarray, agent: np.ndarray, min_agent_ms: float = 300,
             min_caller_ms: float = 120, max_gap_ms: float = 1500) -> list[dict]:
    """Agent speaks, stops, caller starts: one record per handoff, the mark at the caller onset."""
    a_runs = [r for r in runs(agent > VAD) if (r[1] - r[0]) * FRAME_S * 1e3 >= min_agent_ms]
    c_runs = [r for r in runs(caller > VAD) if (r[1] - r[0]) * FRAME_S * 1e3 >= min_caller_ms]
    out = []
    for c_start, c_end in c_runs:
        ended = [e for _, e in a_runs if e <= c_start]
        inside = [e for s0, e in a_runs if s0 <= c_start < e]
        if ended:
            agent_end, gap_frames = max(ended), c_start - max(ended)
        elif inside:
            agent_end, gap_frames = c_start, 0     # the caller talks over the agent
        else:
            continue
        gap_ms = gap_frames * FRAME_S * 1e3
        if gap_ms > max_gap_ms:
            continue
        out.append({"caller_on": c_start, "caller_off": c_end, "gap_ms": int(round(gap_ms)),
                    "caller_run_ms": int((c_end - c_start) * FRAME_S * 1e3),
                    "agent_end": agent_end})
    return out


def cut(wav: str, mark_frame: int, out_dir: str, name: str,
        gap_ms: int = 500) -> tuple[str, float] | None:
    """6 s clip whose lead reaches the agent's last words; returns (file, mark_s).

    The lead has to cover the gap plus a moment of agent speech, or a long silence
    before the caller starts leaves the clip with no agent in it at all.
    """
    t_on = mark_frame * FRAME_S
    lead = min(2.0, max(LEAD_S, gap_ms / 1000.0 + 0.6))
    t0 = max(0.0, t_on - lead)
    if t0 + CLIP_S > 300:
        return None
    path = os.path.join(out_dir, name)
    subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t0:.2f}", "-t", f"{CLIP_S}", "-i", wav,
                    "-ac", "2", "-acodec", "pcm_s16le", path, "-y"], check=True)
    return path, round(t_on - t0, 2)


def selfcheck() -> None:
    """Handoff detection on synthetic VAD tracks (no files)."""
    n = 60
    agent = np.zeros(n, bool); agent[5:20] = True          # agent speaks 0.4-1.6 s
    caller = np.zeros(n, bool); caller[23:35] = True        # caller starts 0.24 s later
    h = handoffs(caller.astype(float) * 0.5, agent.astype(float) * 0.5)
    assert len(h) == 1, h
    assert h[0]["caller_on"] == 23 and h[0]["gap_ms"] == 240, h[0]
    # a gap longer than the cap is not a handoff
    caller2 = np.zeros(n, bool); caller2[45:55] = True
    assert handoffs(caller2.astype(float) * 0.5, agent.astype(float) * 0.5) == []
    # a caller run under the minimum (a backchannel-length blip) is skipped
    caller3 = np.zeros(n, bool); caller3[23:24] = True
    assert handoffs(caller3.astype(float) * 0.5, agent.astype(float) * 0.5) == []
    # overlap (caller starts before the agent stops) has gap 0 and still counts
    caller4 = np.zeros(n, bool); caller4[15:30] = True
    assert handoffs(caller4.astype(float) * 0.5, agent.astype(float) * 0.5)[0]["gap_ms"] == 0
    print("selfcheck ok")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wavs")
    ap.add_argument("--clips")
    ap.add_argument("--sample", type=int, default=30)
    ap.add_argument("--shards", help="shard dir: also score the model's catch on these handoffs")
    ap.add_argument("--min-agent-ms", type=float, default=300)
    ap.add_argument("--min-caller-ms", type=float, default=120)
    ap.add_argument("--max-gap-ms", type=float, default=1500)
    ap.add_argument("--seed", type=int, default=125)
    ap.add_argument("--selfcheck", action="store_true")
    a = ap.parse_args()
    if a.selfcheck:
        return selfcheck()
    if not (a.wavs and a.clips):
        ap.error("--wavs and --clips are required (or --selfcheck)")

    os.makedirs(a.clips, exist_ok=True)
    rng = np.random.default_rng(a.seed)
    wavs = sorted(glob.glob(os.path.join(a.wavs, "*.wav")))
    if not wavs:
        sys.exit(f"no wavs in {a.wavs}")

    per_call, allh = [], []
    mins = 0.0
    for wav in wavs:
        cid = os.path.basename(wav)[:-4]
        caller, agent = energy(wav)
        mins += len(caller) * FRAME_S / 60
        hs = handoffs(caller, agent, a.min_agent_ms, a.min_caller_ms, a.max_gap_ms)
        per_call.append((cid, len(hs)))
        allh += [(cid, wav, h, caller, agent) for h in hs]

    runs_ms = np.array([h["caller_run_ms"] for _, _, h, _, _ in allh])
    print(f"{len(wavs)} conversations, {mins:.1f} min, {len(allh)} handoffs "
          f"({len(allh) / mins:.2f}/min)")
    print("  caller run length: p10 %d, p50 %d, p90 %d ms; gaps p50 %d ms"
          % (np.percentile(runs_ms, 10), np.percentile(runs_ms, 50), np.percentile(runs_ms, 90),
             int(np.median([h["gap_ms"] for _, _, h, _, _ in allh]))))
    quiet = [c for c, n in per_call if n == 0]
    print(f"  calls with no handoff: {len(quiet)} {quiet[:6]}")

    if a.shards:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ports", "tyger-student"))
        from data import load_shard
        shards = {os.path.basename(p)[5:-4]: p for p in glob.glob(os.path.join(a.shards, "*.npz"))}
        print(f"\n  model catch on these handoffs (fire within 0-{int(0.64 / FRAME_S)} frames of the onset):")
        for thr in (0.30, 0.40, 0.50):
            hit = tot = 0
            for cid, _wav, h, _c, _a in allh:
                p = shards.get(cid)
                if not p:
                    continue
                frames, _l, _e, _m = load_shard(p)
                y = frames["teacher"][:, 5]
                win = y[h["caller_on"]:h["caller_on"] + 9]
                tot += 1
                hit += bool(len(win) and win.max() >= thr)
            print(f"    yield >= {thr:.2f}: {hit}/{tot} = {100 * hit / max(tot, 1):.0f}%")

    # sample evenly across the run-length quartiles so short (backchannel-length)
    # and long (turn-length) handoffs are both represented
    order = np.argsort(runs_ms)
    quart = [order[i::4] for i in range(4)]
    picked = []
    for q in quart:
        k = max(1, a.sample // 4)
        picked += list(rng.permutation(q)[:k])
    rows = []
    for i, idx in enumerate(picked, 1):
        cid, wav, h, _c, _a = allh[int(idx)]
        name = f"{cid}-handoff-{h['caller_on'] * FRAME_S:.2f}s.wav"
        got = cut(wav, h["caller_on"], a.clips, name, gap_ms=h["gap_ms"])
        if not got:
            continue
        path, mark = got
        rows.append({"sample_id": f"H{i:03d}", "conversation_id": cid,
                     "ts_s": round(h["caller_on"] * FRAME_S, 2), "kind": "HANDOFF",
                     "clip": os.path.basename(path), "mark_s": mark,
                     "gap_ms": h["gap_ms"], "caller_run_ms": h["caller_run_ms"],
                     "human_verdict": "", "human_notes": ""})
    cols = ["sample_id", "conversation_id", "ts_s", "kind", "clip", "mark_s", "gap_ms",
            "caller_run_ms", "human_verdict", "human_notes"]
    with open(os.path.join(a.clips, "manifest.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"\n{len(rows)} clips + {os.path.join(a.clips, 'manifest.csv')}")
    with open(os.path.join(a.clips, "handoffs.json"), "w") as fh:
        json.dump({"minutes": round(mins, 1), "n": len(allh),
                   "caller_run_ms": runs_ms.tolist()}, fh)


if __name__ == "__main__":
    main()
