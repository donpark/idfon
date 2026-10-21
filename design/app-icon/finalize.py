#!/usr/bin/env python3
"""Finalize the app icon: pink-handset retint + visual centering, then export.

- visual centering: shift the frame so the three pieces' mass centroid (from the
  clean GPT shape mask) lands on the canvas center — mass, not bbox
- base + handset mask are shifted together so the reusable retint pair stays
  frame-aligned (styled/styled-neu-neutral-v4-a-centered.png + mask/handset-mask.png)
- export: final/ masters, ios AppIcon.appiconset, mac AppIcon.iconset
"""
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

# Visual centering: the all-three-pieces mask centroid (mass, not bbox) must hit
# the canvas center. Raw sources in, centered pair out — deterministic.
b = np.array(Image.open("mask/gpt-mask-raw.png").convert("L")).astype(int) > 128
ys, xs = np.where(b)
dx = int(np.clip(round(512 - xs.mean()), -80, 80))
dy = int(np.clip(round(512 - ys.mean()), -80, 80))
print(f"mass centroid ({xs.mean():.0f}, {ys.mean():.0f}) -> shift dx {dx}, dy {dy}")


def shift(img, dx, dy):
    out = Image.new(img.mode, img.size, (0,) * len(img.getbands()))
    out.paste(img, (dx, dy))
    if dx > 0:
        out.paste(img.crop((0, 0, 2, 1024)).resize((dx + 2, 1024)), (0, 0))
    elif dx < 0:
        out.paste(img.crop((1022, 0, 1024, 1024)).resize((-dx + 2, 1024)), (1024 + dx - 2, 0))
    if dy > 0:
        out.paste(img.crop((0, 0, 1024, 2)).resize((1024, dy + 2)), (0, 0))
    elif dy < 0:
        out.paste(img.crop((0, 1022, 1024, 1024)).resize((1024, -dy + 2)), (0, 1024 + dy - 2))
    return out


# re-derive the raw-frame mask first: the shift below overwrites handset-mask.png
# in place, so a re-run would otherwise shift an already-shifted mask (drift)
subprocess.run([sys.executable, "make_mask.py"], check=True)

base = shift(Image.open("styled/styled-neu-neutral-v4-a.png").convert("RGB"), dx, dy)
base.save("styled/styled-neu-neutral-v4-a-centered.png")
shift(Image.open("mask/handset-mask.png").convert("L"), dx, dy).save("mask/handset-mask.png")

subprocess.run([sys.executable, "retint.py", "F2A8B5",
                "styled/styled-neu-neutral-v4-a-centered.png", "final/AppIcon-1024-ios.png"],
               check=True)

root = Path("/Users/don/dev/idfon")
# RGB, no alpha: App Store Connect rejects icons with an alpha channel
Image.open("final/AppIcon-1024-ios.png").convert("RGB").save(
    root / "ios/Idfon/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")

mask = Image.new("L", (4096, 4096), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, 4095, 4095], radius=916, fill=255)
mac_master = Image.open("final/AppIcon-1024-ios.png").convert("RGBA")
mac_master.putalpha(mask.resize((1024, 1024), Image.LANCZOS))
mac_master.save("final/AppIcon-1024-macos.png")

iconset = root / "mac/Assets/AppIcon.iconset"
for name, px in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                 ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                 ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512),
                 ("icon_512x512@2x", 1024)]:
    (mac_master if px == 1024 else mac_master.resize((px, px), Image.LANCZOS)).save(iconset / f"{name}.png")
print("exported: final/ masters, iOS appiconset, mac iconset")
