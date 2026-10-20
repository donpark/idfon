#!/usr/bin/env python3
"""Retint the handset piece to any color using the reusable mask.

Usage: .venv/bin/python retint.py <hex> [base.png] [out.png]
  e.g. .venv/bin/python retint.py F2A8B5

Defaults are the centered final pair (base + mask share a frame).

The mask (mask/handset-mask.png) is a soft alpha over the handset piece.
Tinting preserves the render's shading: luminance is kept, chroma is replaced,
normalised so a typical surface area lands exactly on the requested color.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

hexcol = sys.argv[1].lstrip("#")
target = np.array([int(hexcol[i : i + 2], 16) for i in (0, 2, 4)], dtype=float)
base_path = sys.argv[2] if len(sys.argv) > 2 else "styled/styled-neu-neutral-v4-a-centered.png"
out_path = sys.argv[3] if len(sys.argv) > 3 else f"mask/retint-{hexcol}.png"

base = np.array(Image.open(base_path).convert("RGB")).astype(float)
alpha = np.array(Image.open("mask/handset-mask.png").convert("L")).astype(float) / 255.0

lum = base @ [0.299, 0.587, 0.114]
sel = alpha > 0.5
ref = float(np.median(lum[sel]))  # typical handset surface luminance
tinted = np.clip(target[None, None, :] * (lum / ref)[:, :, None], 0, 255)
out = base * (1 - alpha[:, :, None]) + tinted * alpha[:, :, None]

Path(out_path).parent.mkdir(parents=True, exist_ok=True)
Image.fromarray(out.astype(np.uint8), "RGB").save(out_path)
print(f"wrote {out_path}  (#{hexcol}, surface lum {ref:.0f})")
