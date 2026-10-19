#!/usr/bin/env python3
"""Turn-taking gate on real conversations: TYGER vs labels vs our energy baseline
(docs/voice-tyger.md). Uses `anyreach-ai/dualturn-otospeech-turn-taking` (DualTurn /
OtoSpeech): real dual-channel conversations with per-frame labels at 12.5 Hz — the same
80 ms grid the model runs on — for end-of-turn (`eot`), within-turn pause (`hold`),
beginning-of-turn (`bot`) and backchannel (`bc`).

The corpus ships Mimi codec codes, not waveforms: both channels are decoded with
kyutai/mimi (transformers) before scoring, so the audio is codec-round-tripped — a known
offset vs clean mic audio (thresholds tuned here need a final check on idfon calls).

Per session (ch0 = the "user" side, ch1 = the agent/second-ear side):
  * decode codes -> 24 kHz -> 16 kHz, feed ReferenceEars one 320 ms hop at a time,
    floor state driven by ch1's VAD (speaking while the other side talks);
  * score p_end / yield / bc_prob per 80 ms frame against the labels: AUC + AP, and an
    ep_thr sweep (latency from eot, early cut-ins, misses) — same sweep for the energy
    endpointer that runs in the relay today (ported from scripts/tyger-ab.py).

    .venv/bin/python scripts/tyger-eval.py --sessions 2 --max-minutes 5

Env: TYGER_S2S (tyger-s2s clone), TYGER_BUNDLE (the HF snapshot dir). License note: the
dataset is `license: other` with no LICENSE file — internal evaluation only until checked.
"""
import argparse
import json
import os
import sys

import numpy as np

S2S = os.environ.get("TYGER_S2S", os.path.expanduser("~/dev/tyger-s2s"))
BUNDLE = os.environ.get("TYGER_BUNDLE")
sys.path.insert(0, S2S)
sys.path.insert(0, os.path.join(S2S, "scripts"))

import torch  # noqa: E402

from app.plugins.ears.tyger.session import EarsSession  # noqa: E402
from validate.reference import ReferenceEars  # noqa: E402

SR = 16_000
FRAME_MS = 80
HOP_FRAMES = 4  # 320 ms per ReferenceEars hop
DATASET = "anyreach-ai/dualturn-otospeech-turn-taking"


def resample16k(x24, rate=24_000):
    n = int(round(len(x24) * SR / rate))
    return np.interp(np.linspace(0, len(x24), n, endpoint=False), np.arange(len(x24)), x24).astype(np.float32)


def decode_channel(mimi, codes_t8):
    """Mimi RVQ codes (T, 8) -> 24 kHz float audio."""
    codes = torch.from_numpy(codes_t8.T.copy()).long()[None]  # (1, 8, T)
    with torch.no_grad():
        return mimi.decode(codes).audio_values[0, 0].numpy()


def auc(pos, neg):
    from scipy.stats import mannwhitneyu

    if not len(pos) or not len(neg):
        return float("nan")
    return float(mannwhitneyu(pos, neg).statistic) / (len(pos) * len(neg))


def ap(pos, neg):
    if not len(pos) or not len(neg):
        return float("nan")
    scores = np.concatenate([pos, neg])
    labels = np.concatenate([np.ones(len(pos)), np.zeros(len(neg))])
    order = np.argsort(-scores, kind="mergesort")
    labels = labels[order]
    hits = np.cumsum(labels)
    return float((hits[labels == 1] / np.arange(1, len(labels) + 1)[labels == 1]).mean())


def baseline_endpoints(pcm16, thr=300.0):
    """The relay's energy endpointer (live-relay.mjs): |s16| > 300, 800 ms quiet tail,
    turns under 1 s dropped. Returns fire times in seconds."""
    quiet_need, min_s, frame = int(SR * 0.8), 1.0, int(SR * 0.02)
    speaking, quiet, started, ends = False, 0, 0.0, []
    for off in range(0, len(pcm16) - frame + 1, frame):
        t = (off + frame) / SR
        loud = bool((np.abs(pcm16[off : off + frame]) > thr).any())
        if loud:
            if not speaking:
                speaking, started = True, t
            quiet = 0
            continue
        if not speaking:
            continue
        quiet += frame
        if quiet < quiet_need:
            continue
        speaking = False
        if (t - quiet_need / SR) - started >= min_s:
            ends.append(t)
    return ends


def sweep(ends, eot_s, horizon_s=1.2):
    """Ground-truth turn ends -> (latencies, early, miss) for a list of fire times."""
    lat, early, miss = [], 0, 0
    for f in eot_s:
        first = next((t for t in ends if f - 1.6 <= t < f), None)
        if first is not None:
            early += 1
            continue
        first = next((t for t in ends if f <= t <= f + horizon_s), None)
        if first is None:
            miss += 1
        else:
            lat.append(first - f)
    return lat, early, miss


def main():
    ap_ = argparse.ArgumentParser()
    ap_.add_argument("--sessions", type=int, default=2)
    ap_.add_argument("--skip", type=int, default=0, help="skip this many sessions of the split first")
    ap_.add_argument("--max-minutes", type=float, default=5.0)
    ap_.add_argument("--split", default="val")
    ap_.add_argument("--ep-sweep", default="0.80,0.85,0.91,0.95")
    ap_.add_argument("--out", default=None)
    args = ap_.parse_args()

    from datasets import load_dataset
    from transformers import AutoModel

    torch.set_num_threads(4)  # their plugin's default: more threads mostly spin-wait
    mimi = AutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()
    ears = ReferenceEars(BUNDLE, device="cpu")
    thr_sweep = [float(x) for x in args.ep_sweep.split(",")]

    rows = iter(load_dataset(DATASET, split=args.split, streaming=True))
    for _ in range(args.skip):
        next(rows)
    report = {"dataset": DATASET, "split": args.split, "skip": args.skip, "sessions": []}
    for row in rows:
        if len(report["sessions"]) >= args.sessions:
            break
        T = int(row["num_frames"])
        limit = min(T, int(args.max_minutes * 60 * 12.5))
        codes = {ch: np.array(row[f"codes_{ch}"], dtype=np.int16).reshape(T, 8)[:limit] for ch in ("ch0", "ch1")}
        labels = {f"{k}_{ch}": np.array(row[f"{k}_{ch}"], dtype=np.int8)[:limit] for k in ("vad", "eot", "hold", "bot", "bc") for ch in ("ch0", "ch1")}
        print(f"\n== {row['session_id']} ({row.get('dataset', '?')}): {limit / 12.5:.0f}s of {row['duration_s']:.0f}s", flush=True)

        wavs = {ch: resample16k(decode_channel(mimi, codes[ch])) for ch in ("ch0", "ch1")}
        print(f"decoded to 16 kHz: {len(wavs['ch0']) / SR:.1f}s per channel", flush=True)
        n = min(len(wavs["ch0"]), len(wavs["ch1"])) // (HOP_FRAMES * SR * FRAME_MS // 1000) * (HOP_FRAMES * SR * FRAME_MS // 1000)
        sess = EarsSession(0)
        scores = {"p_end": [], "yield": [], "bc": []}
        events = []
        for h in range(0, n // (HOP_FRAMES * SR * FRAME_MS // 1000)):
            if h % 25 == 0:
                print(f"  hop {h}/{n // (HOP_FRAMES * SR * FRAME_MS // 1000)} frames scored={len(scores['p_end'])}", flush=True)
            s = h * HOP_FRAMES * SR * FRAME_MS // 1000
            user = wavs["ch0"][s : s + HOP_FRAMES * SR * FRAME_MS // 1000]
            agent = wavs["ch1"][s : s + HOP_FRAMES * SR * FRAME_MS // 1000]
            mode = "speaking" if labels["vad_ch1"][h * HOP_FRAMES : (h + 1) * HOP_FRAMES].mean() > 0.5 else "listen"
            for ev in ears.feed(sess, user, agent, mode):
                if ev["kind"] == "FRAME":
                    scores["p_end"].append(ev.get("p_end", 0.0))
                    scores["yield"].append(ev.get("yield_prob", 0.0))
                    scores["bc"].append(ev.get("bc_prob", 0.0))
                else:
                    events.append((len(scores["p_end"]), ev))
        L = len(scores["p_end"])
        lab = {k: v[:L] for k, v in labels.items()}
        sc = {k: np.array(v[:L]) for k, v in scores.items()}
        eot_frames = np.flatnonzero(lab["eot_ch0"])
        turn_frames = np.flatnonzero((lab["vad_ch0"] == 1) & (lab["eot_ch0"] == 0))
        hold_frames = np.flatnonzero(lab["hold_ch0"] == 1)
        bot_int = np.flatnonzero((lab["bot_ch0"] == 1) & (lab["vad_ch1"] == 1))
        bc_frames = np.flatnonzero(lab["bc_ch0"] == 1)

        res = {"session_id": row["session_id"], "frames": L, "eot": int(len(eot_frames)),
               "endpoint_auc": round(auc(sc["p_end"][eot_frames], sc["p_end"][turn_frames]), 4),
               "endpoint_ap": round(ap(sc["p_end"][eot_frames], sc["p_end"][turn_frames]), 4),
               "barge_auc": round(auc(sc["yield"][bot_int], sc["yield"][turn_frames]), 4) if len(bot_int) else None,
               "bc_auc": round(auc(sc["bc"][bc_frames], sc["bc"][turn_frames]), 4) if len(bc_frames) else None,
               "holds": int(len(hold_frames)), "interrupting_bots": int(len(bot_int)), "bc": int(len(bc_frames))}

        eot_s = (eot_frames * FRAME_MS / 1000).tolist()
        res["ep_sweep"] = {}
        for thr in thr_sweep:
            run = sc["p_end"] >= thr
            fires = [f for f in range(1, L) if run[f] and not run[f - 1]]  # threshold crossings
            fire_s = [f * FRAME_MS / 1000 for f in fires]
            lat, early, miss = sweep(fire_s, eot_s)
            res["ep_sweep"][str(thr)] = {
                "latency_med": round(float(np.median(lat)), 2) if lat else None,
                "early": early, "miss": miss,
            }
        base_s = baseline_endpoints((wavs["ch0"][:n] * 32767).astype(np.int16))
        lat, early, miss = sweep(base_s, eot_s)
        res["baseline"] = {"latency_med": round(float(np.median(lat)), 2) if lat else None, "early": early, "miss": miss,
                           "fires": len(base_s)}
        report["sessions"].append(res)
        print(json.dumps(res, indent=2), flush=True)

    out = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench-results", "tyger-eval.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
