"""Pre-decode dualturn audio to the wav cache `pass_gate.py --emit-shards` reads.

`pass_gate.py`'s `session_wav` opens the 25 GB dualturn split once *per session*;
a 60-session shard set would re-stream the split 120 times. This script streams each
split exactly once, decodes only the shard's session ids (both ears) to 16 kHz, and
writes `<sid>.npy` / `<sid>-ch1.npy` in the cache dir. The subsequent
`pass_gate.py --emit-shards --artifact ...` run then hits the cache and never touches
the dataset. Frames are cut to the shard's T (+8, matching pass_gate's causal tail),
so each session decodes ~3 min, not the full 16 min.

Usage:
  .venv/bin/python ports/tyger-student/precache_wavs.py \
      --shards /Users/don/dev/idfon/bench-results/tap4-shards/train --split train \
      --out bench-results/asr-tap/wav
"""
import argparse
import glob
import os
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

DATASET = "anyreach-ai/dualturn-otospeech-turn-taking"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", required=True, help="reference shard dir (tap4-shards/{train,val})")
    ap.add_argument("--split", required=True, help="dualturn split the shard dir came from")
    ap.add_argument("--out", required=True, help="wav cache dir (pass_gate --wav-cache)")
    ap.add_argument("--limit", type=int, default=0, help="stop after N decoded sessions (0 = all)")
    args = ap.parse_args()

    refs = {Path(p).stem: Path(p) for p in sorted(glob.glob(os.path.join(args.shards, "*.npz")))}
    if not refs:
        sys.exit(f"no shards in {args.shards}")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    todo = {sid for sid in refs if not ((out / f"{sid}.npy").exists() and (out / f"{sid}-ch1.npy").exists())}
    print(f"{len(refs)} shards, {len(todo)} to decode from split {args.split!r}", flush=True)
    if not todo:
        return

    import torch
    from datasets import load_dataset
    from transformers import AutoModel

    from oracle import decode_channel, resample16k

    mimi = AutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()
    done = 0
    t0 = time.time()
    for row in load_dataset(DATASET, split=args.split, streaming=True):
        sid = row["session_id"]
        if sid not in todo:
            continue
        T = len(np.load(refs[sid], allow_pickle=True)["energy"])
        need = T + 16  # > pass_gate's T + 8, so _cached's length check always passes
        codes = {ch: np.array(row[f"codes_{ch}"], dtype=np.int16).reshape(int(row["num_frames"]), 8)[:need]
                 for ch in ("ch0", "ch1")}
        for ch, name in (("ch0", f"{sid}.npy"), ("ch1", f"{sid}-ch1.npy")):
            wav = resample16k(decode_channel(mimi, codes[ch]))
            np.save(out / name, wav.astype(np.float32))
        todo.discard(sid)
        done += 1
        print(f"  {done:3d} {sid[:16]}… {T} frames  {time.time() - t0:.0f}s", flush=True)
        if args.limit and done >= args.limit:
            break
        if not todo:
            break
    if todo:
        sys.exit(f"split {args.split!r} ended with {len(todo)} sessions undecoded: {sorted(todo)[:3]}")
    print(f"decoded {done} session(s) in {time.time() - t0:.0f}s -> {out}", flush=True)


if __name__ == "__main__":
    main()
