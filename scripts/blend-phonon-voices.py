#!/usr/bin/env python3
"""Blend the idfon voice set from a Phonon export's speaker embeddings.

Each idfon voice is a weighted average of two catalog voices' `emb` tensor
(`[1, T, D]`, the exported form the engine reads). The older
`docs/voice-compare-audio/voices/` files are the pre-export `speaker_wavs`
form (`[1, D, T]`, no `emb`) and the engine rejects them —
"voice Ada has no `emb` tensor", 2026-11-01 — so the blends are computed here
from the export itself, before the confusable parents are pruned from the pack.

Pure stdlib: safetensors is a u64 header length, a JSON header, then the raw
tensor bytes.

    scripts/blend-phonon-voices.py <export-voices-dir>
"""
import json
import struct
import sys
from pathlib import Path

# Same recipes as scripts/phonon-voice-compare.py (approved 2026-10-31).
VOICES = {
    "Clara": [("Maeve", 0.5), ("Harper", 0.5)],
    "Nora": [("Everly", 0.55), ("Imogen", 0.45)],
    "Iris": [("Hadley", 0.5), ("Delia", 0.5)],
    "Ada": [("Zoey", 0.5), ("Freya", 0.5)],
    "June": [("Elodie-Rose", 0.5), ("Juniper", 0.5)],
    "Owen": [("Edwin", 0.5), ("Preston", 0.5)],
    "Felix": [("Easton", 0.5), ("Alfie", 0.5)],
    "Milo": [("Trevor", 0.5), ("Micah", 0.5)],
    "Theo": [("Hugh", 0.5), ("Spencer", 0.5)],
}

TENSOR = "emb"


def read_emb(path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        head = json.loads(f.read(n))
        if TENSOR not in head:
            raise SystemExit(f"{path} has no `{TENSOR}` tensor (keys: {sorted(head)})")
        info = head[TENSOR]
        if info["dtype"] != "F32":
            raise SystemExit(f"{path}: {TENSOR} is {info['dtype']}, expected F32")
        start, end = info["data_offsets"]
        f.seek(8 + n + start)
        raw = f.read(end - start)
    return info["shape"], raw


def write_emb(path, shape, raw):
    head = {TENSOR: {"dtype": "F32", "shape": shape, "data_offsets": [0, len(raw)]}}
    blob = json.dumps(head).encode()
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(blob)))
        f.write(blob)
        f.write(raw)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__.strip())
    voices = Path(sys.argv[1])
    for name, recipe in VOICES.items():
        shape = raw = None
        frame = None
        for parent, weight in recipe:
            src = voices / f"{parent}.safetensors"
            if not src.is_file():
                raise SystemExit(f"blend {name}: parent {parent} missing from {voices}")
            shape, data = read_emb(src)
            if frame is None:
                frame = shape
                acc = [0.0] * (len(data) // 4)
            elif shape != frame:
                raise SystemExit(f"blend {name}: {parent} shape {shape} != {frame}")
            value = struct.unpack(f"<{len(data) // 4}f", data)
            for i, v in enumerate(value):
                acc[i] += v * weight
        write_emb(voices / f"{name}.safetensors", frame,
                  struct.pack(f"<{len(acc)}f", *acc))
        print(f"  {name:6s} = {' + '.join(f'{p}*{w}' for p, w in recipe)}  {frame}")


if __name__ == "__main__":
    main()
