"""The barge operating point: catch vs false fires over Open Yap 1K.

The existing audit (`bench-results/human-audit-openyap.md`) says the teacher's
barge proposals are 63% real and that the misses are real cut-ins at scores just
under the shipped 0.5 -- but it sampled *episodes that already fired*, plus a
fixed near-miss probe, so it cannot say what a lower threshold would cost. This
sweeps the threshold over whole conversations and reports both sides:

  fires     speaking episodes whose peak yield reaches the threshold (one
            decision per episode: the unit the product and the audit use)
  catch     interrupting onsets (caller channel opens while the agent's is
            voiced) with a fire within 640 ms -- tyger-eval's definition
  false     fires with no such onset in the window
  falsemin  false fires per minute, the number a threshold is chosen on

It also writes blinded 6 s stereo clips (caller left, agent right, mark at
2.0 s) and a manifest in `human-audit-openyap.csv`'s column order, so a human
can fill `human_verdict` on a *random* sample rather than a stratified one.

    .venv/bin/python scripts/openyap-barge-sweep.py \\
        --shards bench-results/openyap-shards-v2 --wavs /tmp/openyap/wav \\
        --clips /tmp/openyap/audit --thrs 0.30,0.35,0.40,0.45,0.50

  --selfcheck   the episode/onset arithmetic on synthetic frames, no files
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

VAD = 0.00316          # -50 dB, mode_track's voiced threshold
FRAME_S = 0.08
CATCH_S = 0.64         # tyger-eval: an interruption is caught within 640 ms
CLIP_S = 6.0
MARK_S = 2.0


def energy(path: str, secs: float | None = None) -> tuple[np.ndarray, np.ndarray]:
    """Per-80 ms-frame RMS of a stereo wav -> (caller, agent)."""
    with wave.open(path) as w:
        rate = w.getframerate()
        n = w.getnframes() if secs is None else min(w.getnframes(), int(rate * secs))
        raw = w.readframes(n)
    a = np.frombuffer(raw, np.int16).reshape(-1, 2).astype(np.float32) / 32768.0
    hop = int(rate * FRAME_S)
    f = lambda x: np.array([np.sqrt(np.mean(x[i:i + hop] ** 2)) for i in range(0, len(x) + 1 - hop, hop)])
    return f(a[:, 0]), f(a[:, 1])


def episodes(mode: np.ndarray) -> list[tuple[int, int]]:
    """Maximal [start, end) runs of speaking frames."""
    out, start = [], None
    for i, v in enumerate(mode):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append((start, i)); start = None
    if start is not None:
        out.append((start, len(mode)))
    return out


def interrupting_onsets(caller: np.ndarray, agent: np.ndarray, quiet: int = 3, hold: int = 2) -> list[int]:
    """Caller speech onsets while the agent is voiced.

    `quiet` frames of caller silence must precede the onset (a click or a burst
    inside one caller phrase is not an interruption) and `hold` frames of speech
    must follow it. The agent must be voiced on the frame before the onset,
    because the rules flip their floor state on that frame.
    """
    voiced = caller > VAD
    pre_agent = np.r_[False, agent[:-1] > VAD]
    out = []
    for i in range(quiet, len(voiced) - hold):
        if not voiced[i] or voiced[i - 1] or not pre_agent[i]:
            continue
        if voiced[i - quiet:i].any() or not voiced[i:i + hold].all():
            continue
        out.append(i)
    return out


def fires_at(y: np.ndarray, mode: np.ndarray, thr: float, deb: int = 2,
             refractory: bool = False, edge: bool = False) -> list[int]:
    """Frame indices where the barge branch fires: `deb` consecutive speaking frames at or
    above thr. With `refractory`, one event per speaking episode (the shipped rule)."""
    out, run = [], 0
    fired_this_episode = False
    armed = True   # needs a drop below the threshold before the next fire
    for i, v in enumerate(y >= thr):
        if i and not mode[i - 1]:
            fired_this_episode = False   # a new speaking episode
        if v and mode[i]:
            run = run + 1 if armed else 0
        else:
            run = 0
            if edge:
                armed = True
        if run >= deb:
            if not (refractory and fired_this_episode):
                out.append(i)
                fired_this_episode = True
            run = 0
            if edge:
                armed = False
    return out


def sweep(y: np.ndarray, mode: np.ndarray, caller: np.ndarray, agent: np.ndarray,
          thrs: list[float], refractory: bool = False, edge: bool = False) -> dict[float, dict]:
    onsets = interrupting_onsets(caller, agent)
    win = int(round(CATCH_S / FRAME_S))
    res = {}
    for thr in thrs:
        fired = fires_at(y, mode, thr, refractory=refractory, edge=edge)
        hit = [o for o in onsets if any(o - 1 <= f <= o + win for f in fired)]
        false = [f for f in fired if not any(o - 1 <= f <= o + win for o in onsets)]
        # one decision per speaking episode: first fire inside each episode (the audit's unit)
        firsts = {}
        for f in fired:
            eps = [i for i, (s0, e0) in enumerate(episodes(mode)) if s0 <= f < e0]
            if eps:
                firsts.setdefault(eps[0], f)
        ded = list(firsts.values())
        ded_false = [f for f in ded if not any(o - 1 <= f <= o + win for o in onsets)]
        res[thr] = {"fires": len(fired), "catch": len(hit), "onsets": len(onsets), "false": len(false),
                    "ded": len(ded), "ded_false": len(ded_false)}
    return res


def write_clips(wav: str, fired: list[int], out_dir: str, cid: str, limit: int, rng,
                lead: float = MARK_S, agent_before: bool = True) -> list[dict]:
    """Cut 6 s clips whose lead reaches the agent's last utterance.

    A fire sits in the mode release tail, so a fixed 2 s lead can land entirely
    after the agent stopped and the clip then answers nothing. Each clip starts
    0.8 s before the agent's last voiced frame before the fire, so the listener
    hears the agent stop and then the caller; the mark (the fire) moves with it.
    """
    rows = []
    for i in rng.permutation(len(fired))[:limit]:
        f = fired[int(i)]
        t_fire = f * FRAME_S
        t0 = max(0.0, t_fire - lead)
        if t0 + CLIP_S > 300:
            continue
        name = f"{cid}-barge-{t_fire:.2f}s.wav"
        subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t0:.2f}", "-t", f"{CLIP_S}", "-i", wav,
                        "-ac", "2", "-acodec", "pcm16le" if False else "pcm_s16le",
                        os.path.join(out_dir, name), "-y"], check=True)
        rows.append({"conversation_id": cid, "ts_s": round(t_fire, 2), "kind": "BARGE", "clip": name,
                     "mark_s": round(t_fire - t0, 2), "agent_before": agent_before})
    return rows


def selfcheck() -> None:
    """Onset, firing and sweep arithmetic on synthetic frames (no files, no models)."""
    mode = np.ones(40, np.int8)
    caller = np.zeros(40); agent = np.zeros(40)
    agent[:20] = .5
    caller[10:] = .5                       # caller starts at 10 while the agent is voiced
    assert interrupting_onsets(caller, agent) == [10], interrupting_onsets(caller, agent)
    assert interrupting_onsets(np.zeros(40), agent) == []
    y = np.zeros(40); y[10:12] = .6        # one debounce-completing run at the onset
    assert fires_at(y, mode, 0.5) == [11], fires_at(y, mode, 0.5)
    # refractory: a second run in the same episode is suppressed, a new episode fires
    y2 = np.zeros(40); y2[10:12] = .6; y2[20:22] = .6
    assert fires_at(y2, mode, 0.5) == [11, 21]
    assert fires_at(y2, mode, 0.5, refractory=True) == [11]
    y3 = np.zeros(40); y3[10:13] = .6; y3[20:23] = .6
    assert fires_at(y3, mode, 0.5, edge=True) == [11, 21], fires_at(y3, mode, 0.5, edge=True)
    # a dip below the threshold re-arms inside one episode
    y4 = np.zeros(40); y4[10:12] = .6; y4[13] = .1; y4[14:16] = .6
    assert fires_at(y4, mode, 0.5, edge=True) == [11, 15], fires_at(y4, mode, 0.5, edge=True)
    assert fires_at(y, np.zeros(40, np.int8), 0.5) == []   # never fires while listening
    r = sweep(y, mode, caller, agent, [0.5])[0.5]
    assert (r["fires"], r["catch"], r["false"], r["onsets"]) == (1, 1, 0, 1), r
    y[30:32] = .9                          # a second fire with no onset anywhere near
    r = sweep(y, mode, caller, agent, [0.5])[0.5]
    assert (r["fires"], r["catch"], r["false"]) == (2, 1, 1), r
    print("selfcheck ok")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards")
    ap.add_argument("--wavs")
    ap.add_argument("--clips", default=None, help="write blinded audit clips + manifest here")
    ap.add_argument("--thrs", default="0.30,0.35,0.40,0.45,0.50")
    ap.add_argument("--per-thr", type=int, default=10, help="clips to sample per threshold, across all sessions")
    ap.add_argument("--seed", type=int, default=125)
    ap.add_argument("--refractory", action="store_true",
                    help="one barge per speaking episode, as the shipped rules now do")
    ap.add_argument("--edge", action="store_true",
                    help="one barge per threshold crossing (re-arms after yield drops)")
    ap.add_argument("--selfcheck", action="store_true")
    a = ap.parse_args()
    if a.selfcheck:
        return selfcheck()
    if not (a.shards and a.wavs):
        ap.error("--shards and --wavs are required (or --selfcheck)")

    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ports", "tyger-student"))
    from data import load_shard

    thrs = [float(x) for x in a.thrs.split(",")]
    shards = sorted(glob.glob(os.path.join(a.shards, "*.npz")))
    if not shards:
        sys.exit(f"no shards in {a.shards}")
    rng = np.random.default_rng(a.seed)
    if a.clips:
        os.makedirs(a.clips, exist_ok=True)

    agg = {t: {"fires": 0, "catch": 0, "onsets": 0, "false": 0, "ded": 0, "ded_false": 0} for t in thrs}
    pending: dict[float, list[tuple[str, str, int]]] = {t: [] for t in thrs}
    rows = []
    mins = 0.0
    for shard in shards:
        frames, _labels, _events, meta = load_shard(shard)
        cid = str(meta["session_id"]).replace("live-", "")
        wav = os.path.join(a.wavs, cid + ".wav")
        if not os.path.exists(wav):
            continue
        caller, agent = energy(wav, secs=300)
        mode = frames["mode"]
        T = min(len(mode), len(caller), len(agent))
        mode, caller, agent = mode[:T], caller[:T], agent[:T]
        y = frames["teacher"][:T, 5]
        mins += T * FRAME_S / 60
        r = sweep(y, mode, caller, agent, thrs, refractory=a.refractory, edge=a.edge)
        for t in thrs:
            for k in agg[t]:
                agg[t][k] += r[t][k]
            if a.clips and r[t]["fires"]:
                for f in fires_at(y, mode, t, refractory=a.refractory):
                    # lead back to the agent's last voiced frame *in this session*
                    before = np.flatnonzero(agent[:f + 1] > VAD)
                    lead = 2.0 if not len(before) else min(2.0, max(0.4, (f - before[-1]) * FRAME_S + 0.8))
                    pending[t].append((wav, cid, f, float(lead), bool(len(before))))

    print(f"{len(shards)} shards, {mins:.1f} min")
    print(f"  {'thr':>5} | {'fires':>6} {'false/min':>9} {'prec':>5} {'recall':>6} | "
          f"{'per-ep':>6} {'pe-prec':>7} {'pe-false/min':>12}")
    for t in thrs:
        x = agg[t]
        print(f"  {t:>5.2f} | {x['fires']:>6} {x['false']/mins:>9.2f} "
              f"{100*(x['fires']-x['false'])/max(x['fires'],1):>4.0f}% {100*x['catch']/max(x['onsets'],1):>5.0f}% | "
              f"{x['ded']:>6} {100*(x['ded']-x['ded_false'])/max(x['ded'],1):>6.0f}% {x['ded_false']/mins:>12.2f}")
    print("  (left: one event per debounce run as the rules emit; right: one decision per speaking episode, the audit's unit)")
    if a.clips:
        for t in thrs:
            pool = pending[t]
            for i in rng.permutation(len(pool))[:a.per_thr]:
                wav, cid, f, lead, agent_before = pool[int(i)]
                for row in write_clips(wav, [f], a.clips, cid, 1, rng, lead=lead,
                                       agent_before=agent_before):
                    row["threshold"] = t
                    rows.append(row)
    if a.clips and rows:
        path = os.path.join(a.clips, "manifest.csv")
        cols = ["sample_id", "conversation_id", "ts_s", "kind", "threshold", "clip", "mark_s",
                "agent_before", "human_verdict", "human_notes"]
        with open(path, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
            w.writeheader()
            for i, r in enumerate(rows, 1):
                r["sample_id"] = f"S{i:03d}"
                w.writerow(r)
        print(f"\n{len(rows)} blinded clips + {path}")


if __name__ == "__main__":
    main()
