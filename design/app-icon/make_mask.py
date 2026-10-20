#!/usr/bin/env python3
"""Build the reusable handset mask from the GPT-Image-2 mask (mask/gpt-mask-raw.png).
The model masks all three pieces; keep only the rightmost white blob (the handset),
feather the edge. Output: mask/handset-mask.png (white = handset, aligned with
styled/styled-neu-neutral-v4-a.png). Retint any color with retint.py <hex>.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

b = np.array(Image.open("mask/gpt-mask-raw.png").convert("L")).astype(int) > 128
cnt = b.sum(axis=0)
runs, x = [], 0
while x < 1024:
    if cnt[x] > 0:
        x0 = x
        while x < 1024 and cnt[x] > 0:
            x += 1
        runs.append((x0, x))
    else:
        x += 1
print("white runs (x0, x1):", runs)
x0, x1 = runs[-1]
handset = b.copy()
handset[:, :x0] = False

ys, xs = np.where(handset)
print(f"handset mask: x {xs.min()}..{xs.max()} y {ys.min()}..{ys.max()} | {int(handset.sum())} px")
alpha = Image.fromarray((handset * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(1.5))
Path("mask").mkdir(exist_ok=True)
alpha.save("mask/handset-mask.png")
print("wrote mask/handset-mask.png")
