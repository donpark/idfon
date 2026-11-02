"""Corpus -> training shards: run the fp32 teacher chain over dualturn sessions and
record, per 80 ms frame, what the decision model sees (the two L15 streams, frame
energy in dB, the rules' previous floor state) and what the teacher answered (its
8-vector), plus the corpus labels (registry `corpus:` sources) and the teacher's
events (gate.py's reference).

The feed contract is oracle.py's — parity7's, the same as the path-C dumps this
supersedes, so targets are cross-checkable against them.

Env: TYGER_S2S, TYGER_BUNDLE (see oracle.py). Venv: torch + transformers + datasets.
Runs the teacher on MPS (~4 min per 3-min session):

    .venv/bin/python ports/tyger-student/featurize.py --split val --sessions 2 \
        --out bench-results/student-shards/val
    .venv/bin/python ports/tyger-student/featurize.py --split train --sessions 6 \
        --out bench-results/student-shards/train

Live captures (the apps' `TurnCapture` stereo 16 kHz wavs: ch0 = mic, ch1 =
agent) take the same path with `--wavs DIR` instead of a dataset split. They
carry no corpus labels, so a live shard is for `calibrate.py` / `gate.py`
(teacher events are the reference) — never for training. Exact duplicate files
(the capture pipeline restarts) are skipped by content hash.

    .venv/bin/python ports/tyger-student/featurize.py --wavs "$HOME/Library/Application Support/Idfon/turn-captures" \
        --out bench-results/live-shards

Resumable: existing shards are skipped. shortcut: batch sizes are stand-up scale —
accumulate later batches in more dirs (or the same one) and warm-start train.py
--init on the grown set.
"""
import argparse
import hashlib
import os
import wave
from pathlib import Path

import numpy as np

from data import save_shard
from oracle import GRID, HOP, HOP_FRAMES, SR, WIN_S, Oracle, decode_channel, resample16k

DATASET = "anyreach-ai/dualturn-otospeech-turn-taking"
LABEL_KEYS = ("vad", "eot", "hold", "bot", "bc")


def count_interrupts(labels, T):
    """Interrupting onsets: bot_ch0 while the agent held the floor. Mirrors harness.floor_series /
    scripts/tyger-eval.py — pre-onset floor, because floor_series flips at the bot frame itself."""
    floor = np.zeros(T, np.int8)
    cur = 0
    for f in range(T):
        if labels["bot_ch0"][f]:
            cur = 1
        elif labels["bot_ch1"][f]:
            cur = 2
        if labels["eot_ch0"][f] and cur == 1:
            cur = 0
        if labels["eot_ch1"][f] and cur == 2:
            cur = 0
        floor[f] = cur
    pre = np.r_[0, floor[: T - 1]]
    return int(((labels["bot_ch0"] == 1) & (pre == 2)).sum())


def run_session(oracle, wavs, feature_layers=(15,)):
    """parity7's feed loop, recording per frame. Canonical hu/ha are the L15 rows (the
    teacher's own inputs); every other requested layer is recorded as hu_l{K}/ha_l{K}
    from the same encoder pass (output_hidden_states gives all layers for free).
    Returns (frames dict, events list of (frame_1based, kind))."""
    sess = oracle.EarsSession(0)
    cache = None
    hus, has_, acts, prevs, outs = [], [], [], [], []
    extra = {k: ([], []) for k in feature_layers if k != 15}
    events = []
    frame = 0
    n_hops = min(len(wavs["ch0"]), len(wavs["ch1"])) // HOP
    for h in range(n_hops):
        x = (h + 1) * HOP
        win = {ch: wavs[ch][max(0, x - WIN_S * SR):x] for ch in ("ch0", "ch1")}
        hs_u, hs_a = oracle.encode_hidden(win["ch0"]), oracle.encode_hidden(win["ch1"])
        hu, ha = hs_u[15], hs_a[15]  # the teacher reads L15 whatever the student trains on
        act = oracle.rules.frame_energy(win["ch0"])
        for i in range(-min(HOP_FRAMES, len(hu), len(ha), len(act)), 0):
            frame += 1  # parity7 counts frames 1-based
            prev = int(sess.prev_state)
            o, cache = oracle.head_step(hu[i], ha[i], float(act[i]), prev, cache)
            hus.append(hu[i])
            has_.append(ha[i])
            for k, (lu, la) in extra.items():
                lu.append(hs_u[k][i])
                la.append(hs_a[k][i])
            acts.append(float(act[i]))
            prevs.append(prev)
            outs.append(o)
            evs, _final, _reset = oracle.rules.on_frame(sess, "response", o, float(act[i]), left=-i - 1)
            for e in evs:
                if e["kind"] != "FRAME":
                    events.append((frame, e["kind"]))
    frames = {
        "hu": np.asarray(hus, np.float32),
        "ha": np.asarray(has_, np.float32),
        "energy": np.asarray(acts, np.float32),
        "prev_state": np.asarray(prevs, np.int64),
        "teacher": np.asarray(outs, np.float32),
    }
    frames.update({f"hu_l{k}": np.asarray(v[0], np.float32) for k, v in extra.items()})
    frames.update({f"ha_l{k}": np.asarray(v[1], np.float32) for k, v in extra.items()})
    return frames, events


def read_capture(path):
    """A TurnCapture wav: stereo 16 kHz s16, ch0 mic / ch1 agent. -> wavs dict."""
    with wave.open(str(path)) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (2, 2, SR), path
        raw = w.readframes(w.getnframes())
    pcm = np.frombuffer(raw, np.int16).astype(np.float32) / 32768.0
    return {"ch0": pcm[0::2], "ch1": pcm[1::2]}, raw


def main():
    import torch

    ap = argparse.ArgumentParser()
    ap.add_argument("--split", default="val")
    ap.add_argument("--wavs", default=None,
                    help="live captures: a dir of TurnCapture wavs (no labels; calibrate/gate only)")
    ap.add_argument("--skip", type=int, default=0, help="skip this many sessions of the split first")
    ap.add_argument("--sessions", type=int, default=6)
    ap.add_argument("--minutes", type=float, default=3.0)
    ap.add_argument("--dataset", default=DATASET)
    ap.add_argument("--min-interrupts", type=int, default=0,
                    help="skip sessions with fewer interrupting onsets than this (labels-only filter; "
                         "skipped rows still consume a --sessions slot)")
    ap.add_argument("--feature-layers", default="15",
                    help="comma-separated encoder layers to record as student features "
                         "(L15 is always recorded canonically; one pass yields all layers)")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parents[2] / "bench-results" / "student-shards"))
    ap.add_argument("--device", default="mps")
    args = ap.parse_args()

    oracle = Oracle(device=args.device).load_bundle()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    layers = [int(x) for x in args.feature_layers.split(",")]

    if args.wavs:
        paths = sorted(Path(args.wavs).glob("*.wav"))
        if not paths:
            print(f"no wavs in {args.wavs}")
            return
        seen = {}
        made = 0
        for path in paths[args.skip:]:
            if args.sessions and made >= args.sessions:
                break
            wavs, raw = read_capture(path)
            digest = hashlib.sha256(raw).hexdigest()
            if digest in seen:
                print(f"{path.name} = {seen[digest]} (duplicate), skipped", flush=True)
                continue
            seen[digest] = path.name
            sid = f"live-{path.stem}"
            out_path = out / f"{sid}.npz"
            if out_path.exists():
                print(f"{sid[:24]}… cached", flush=True)
                made += 1
                continue
            limit = int(args.minutes * 60 * SR)
            wavs = {ch: x[:limit] for ch, x in wavs.items()}
            frames, events = run_session(oracle, wavs, feature_layers=layers)
            L = len(frames["energy"])
            if not L:
                print(f"{sid[:24]}… no frames scored, skipped", flush=True)
                continue
            save_shard(out_path, sid, frames, {},
                       events=(np.array([f for f, _ in events], np.int32),
                               np.array([k for _, k in events])))
            made += 1
            print(f"{sid[:24]}… {L} frames ({L / GRID:.0f}s), {len(events)} events -> {out_path.name}", flush=True)
        print(f"\n{made} live shard(s) in {out}")
        return

    from datasets import load_dataset
    from transformers import AutoModel

    mimi = AutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()
    rows = iter(load_dataset(args.dataset, split=args.split, streaming=True))
    for _ in range(args.skip):
        next(rows)
    made = 0
    for _ in range(args.sessions):
        try:
            row = next(rows)
        except StopIteration:
            break
        sid = row["session_id"]
        out_path = out / f"{sid}.npz"
        if out_path.exists():
            print(f"{sid[:16]}… cached", flush=True)
            made += 1
            continue
        T = int(row["num_frames"])
        limit = min(T, int(args.minutes * 60 * GRID))
        codes = {ch: np.array(row[f"codes_{ch}"], dtype=np.int16).reshape(T, 8)[:limit] for ch in ("ch0", "ch1")}
        labels = {f"{k}_{ch}": np.array(row[f"{k}_{ch}"], dtype=np.int8)[:limit]
                  for k in LABEL_KEYS for ch in ("ch0", "ch1")}
        if args.min_interrupts:
            n_int = count_interrupts(labels, limit)
            if n_int < args.min_interrupts:
                print(f"{sid[:16]}… {n_int} interrupting onsets < {args.min_interrupts}, skipped", flush=True)
                continue
        wavs = {ch: resample16k(decode_channel(mimi, codes[ch])) for ch in ("ch0", "ch1")}
        frames, events = run_session(oracle, wavs, feature_layers=layers)
        L = len(frames["energy"])
        if not L:
            print(f"{sid[:16]}… no frames scored, skipped", flush=True)
            continue
        save_shard(out_path, sid, frames, {k: v[:L] for k, v in labels.items()},
                   events=(np.array([f for f, _ in events], np.int32),
                           np.array([k for _, k in events])))
        made += 1
        print(f"{sid[:16]}… {L} frames ({L / GRID:.0f}s), {len(events)} events -> {out_path.name}", flush=True)
    print(f"\n{made} shard(s) in {out}")


if __name__ == "__main__":
    main()
