"""Draw endpoint clips for the #197 listening session.

The endpoint question is *has the caller finished, may the agent safely take the
floor?* -- so the clips split by whether the ENDPOINT event fired on the corpus's
own `eot` label or off it. Labels and event frames come from the replay shards;
the audio is not stored there (Switchboard rows carry Mimi codes), so this streams
the dualturn-switchboard dataset and decodes each chosen session once.

    .venv/bin/python scripts/endpoint-clips.py \\
        --shards bench-results/switchboard-shards/test-138 \\
        --out bench-results/endpoint-audit-2026-11-06 --per-class 10

  --selfcheck   the distance/selection arithmetic, no network or model
"""
from __future__ import annotations

import argparse
import csv
import glob
import os
import sys
import wave

import numpy as np

FRAME_S = 0.08          # replay frame = 80 ms
SR = 16_000
GRID = 12.5
CLIP_S = 6.0            # total clip length
LEAD_S = 3.0            # seconds before the mark


def scan(shards: str, tol_frames: int):
    """(session, frame, dist_frames) for every ENDPOINT fire, split on/off eot."""
    on, off = [], []
    for p in sorted(glob.glob(os.path.join(shards, "*.npz"))):
        z = np.load(p, allow_pickle=True)
        sid = os.path.basename(p)[:-4]
        eot = np.flatnonzero(z["lab_eot_ch0"]) if "lab_eot_ch0" in z else np.array([])
        for f, k in zip(z["ev_frames"].tolist(), [str(x) for x in z["ev_kinds"]]):
            if k != "ENDPOINT":
                continue
            d = int(np.abs(eot - f).min()) if len(eot) else 10 ** 9
            (on if d <= tol_frames else off).append((sid, int(f), d))
    return on, off


def choose(on, off, per_class: int):
    """Prefer sessions that supply both classes, so clips stay comparable."""
    by_on = {}
    for r in on:
        by_on.setdefault(r[0], []).append(r)
    by_off = {}
    for r in off:
        by_off.setdefault(r[0], []).append(r)
    both = sorted(set(by_on) & set(by_off))
    picked, used = [], set()
    n_on = n_off = 0
    for sid in both:
        if n_on >= per_class and n_off >= per_class:
            break
        if n_on < per_class:
            picked.append(by_on[sid][0]); n_on += 1
        if n_off < per_class:
            picked.append(by_off[sid][0]); n_off += 1
        used.add(sid)
    for r in on:
        if n_on >= per_class:
            break
        if r[0] not in used:
            picked.append(r); n_on += 1
    for r in off:
        if n_off >= per_class:
            break
        if r[0] not in used:
            picked.append(r); n_off += 1
    return picked


def decode_channel(mimi, codes_t8):
    """Mimi RVQ codes (T, 8) -> 24 kHz float audio."""
    import torch
    codes = torch.from_numpy(np.asarray(codes_t8).T.copy()).long()[None]
    with torch.no_grad():
        return mimi.decode(codes).audio_values[0, 0].numpy()


def resample16k(x24, rate=24_000):
    n = int(round(len(x24) * SR / rate))
    return np.interp(np.linspace(0, len(x24), n, endpoint=False),
                     np.arange(len(x24)), x24).astype(np.float32)


def write_wav(path: str, stereo: np.ndarray):
    """stereo (n, 2) float32 in [-1, 1] -> 16 kHz s16 wav."""
    pcm = np.clip(stereo, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.reshape(-1).tobytes())


def cut(audio, mark_s: float, clip_s: float = CLIP_S, lead_s: float = LEAD_S):
    """Slice a stereo clip with the mark `lead_s` in; pads edges with silence."""
    n = int(round(clip_s * SR))
    start = int(round((mark_s - lead_s) * SR))
    out = np.zeros((n, 2), np.float32)
    lo = max(0, -start)
    hi = min(n, len(audio) - start)
    if hi > lo:
        out[lo:hi] = audio[start + lo:start + hi]
    return out


def selfcheck() -> None:
    """Distance split and clip slicing arithmetic."""
    # 1) distance split: a fire 3 frames from an eot is on, 200 frames is off
    eot = np.array([37, 775])
    assert min(abs(40 - eot.min()), abs(40 - eot.max())) == 3
    assert np.abs(eot - 575).min() == 200
    # 2) clip slicing: mark at 3 s lands LEAD_S into the clip, edges pad
    audio = np.ones((SR * 10, 2), np.float32) * 0.5
    c = cut(audio, mark_s=3.2)
    assert c.shape == (int(CLIP_S * SR), 2)
    assert np.allclose(c[:, 0], 0.5)          # fully inside the audio
    c0 = cut(audio, mark_s=0.5)                # near the start: padded with zeros
    assert c0[0, 0] == 0.0 and c0[-1, 0] == 0.5
    # 3) selection: sessions with both classes come first, then fill to per_class.
    #    Two on-candidates and one off-candidate at per_class=2 yields 3 clips.
    fake_on = [("a", 10, 2), ("b", 20, 3)]
    fake_off = [("a", 30, 40)]
    sel = choose(fake_on, fake_off, per_class=2)
    assert len(sel) == 3, sel
    assert sum(1 for s in sel if s[2] <= 10) == 2, sel   # on
    assert sum(1 for s in sel if s[2] > 10) == 1, sel    # off
    print("selfcheck ok")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--per-class", type=int, default=10)
    ap.add_argument("--tolerance", type=int, default=10, help="frames; 10 = 0.8 s")
    ap.add_argument("--clip-s", type=float, default=CLIP_S)
    ap.add_argument("--lead-s", type=float, default=LEAD_S)
    ap.add_argument("--dataset", default="anyreach-ai/dualturn-switchboard-turn-taking")
    ap.add_argument("--split", default="test")
    ap.add_argument("--max-rows", type=int, default=200, help="stop streaming after this many rows")
    ap.add_argument("--selfcheck", action="store_true")
    a = ap.parse_args()

    if a.selfcheck:
        return selfcheck()
    if not (a.shards and a.out):
        ap.error("--shards and --out are required (or --selfcheck)")

    os.makedirs(a.out, exist_ok=True)
    on, off = scan(a.shards, a.tolerance)
    print(f"ENDPOINT fires on-eot: {len(on)}  off-eot: {len(off)}", flush=True)
    picked = choose(on, off, a.per_class)
    targets = {}
    for sid, f, d in picked:
        targets.setdefault(sid, []).append((f, d))
    print(f"picked {len(picked)} clips from {len(targets)} sessions", flush=True)

    import torch
    from datasets import load_dataset
    from transformers import AutoModel

    print("loading mimi...", flush=True)
    mimi = AutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()
    print("streaming dataset...", flush=True)
    rows = iter(load_dataset(a.dataset, split=a.split, streaming=True))

    manifest = []
    found = set()
    for i, row in enumerate(rows):
        if i >= a.max_rows:
            break
        sid = row["session_id"]
        if sid not in targets:
            continue
        found.add(sid)
        T = int(row["num_frames"])
        audio = np.stack([
            resample16k(decode_channel(mimi, np.array(row[f"codes_{ch}"], dtype=np.int16).reshape(T, 8)))
            for ch in ("ch0", "ch1")
        ], axis=1)
        for f, d in targets[sid]:
            mark_s = f * FRAME_S
            name = f"{sid}_f{f}_{'on' if d <= a.tolerance else 'off'}.wav"
            write_wav(os.path.join(a.out, name), cut(audio, mark_s, a.clip_s, a.lead_s))
            manifest.append(dict(sample_id=f"{sid}:{f}", conversation_id=sid, ts_s=round(mark_s, 2),
                                 kind="ENDPOINT", clip=name, mark_s=round(a.lead_s, 2),
                                 eot_dist_frames=d, eot_dist_s=round(d * FRAME_S, 2),
                                 class_="on" if d <= a.tolerance else "off",
                                 human_verdict="", human_notes=""))
        print(f"  {sid}: {len(targets[sid])} clips", flush=True)
        if len(found) == len(targets):
            break

    if not manifest:
        sys.exit("no target sessions found in the stream; raise --max-rows or check the split")
    cols = ["sample_id", "conversation_id", "ts_s", "kind", "clip", "mark_s",
            "eot_dist_frames", "eot_dist_s", "class_", "human_verdict", "human_notes"]
    with open(os.path.join(a.out, "manifest.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(manifest)
    print(f"{len(manifest)} clips + manifest.csv in {a.out}", flush=True)
    missing = set(targets) - found
    if missing:
        print(f"! {len(missing)} sessions not found within {a.max_rows} rows: {sorted(missing)[:5]}", flush=True)


if __name__ == "__main__":
    main()
