# App icon

Status: **current** — shipped 2026-10-19 on both apps.

## The icon

Photoreal "neu neutral" render: three extruded pieces on a matte warm-gray
panel — a thick **I** bar, the **D** stem nearly touching the handset bowl
(like a handset hanging on a phone box hook), and the handset retinted Western
Electric pink **#F2A8B5**. Bars stay monochrome. Masters (1024²):

- `design/app-icon/final/AppIcon-1024-ios.png` — full-bleed square, RGB (no
  alpha: App Store Connect rejects alpha)
- `design/app-icon/final/AppIcon-1024-macos.png` — Big Sur squircle mask
  (radius ≈22.4%) on transparency

## Where it is wired

- **iOS**: `ios/Idfon/Assets.xcassets/AppIcon.appiconset` (single 1024),
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in both app-target configs,
  `CFBundleIconName` in `Idfon/Info.plist`. iOS squircle-masks the square
  itself. The folder group is synchronized, so the catalog is auto-included.
- **macOS**: `mac/Assets/AppIcon.iconset` (16→512@2x, squircle-masked) →
  `mac/build.sh` runs `iconutil` into `Contents/Resources/AppIcon.icns`;
  `CFBundleIconFile` in `mac/Info.plist`. The mac bundle is assembled by hand
  in `build.sh` (no asset compiler).
- **Rebuild scope**: `mac/` and `ios/` only — resources, no code.

## Retint pipeline (handset to any color)

The handset can be recolored without re-rendering (scripts need `python3` with
`pillow` + `numpy`):

- `design/app-icon/mask/handset-mask.png` — soft mask, white = handset piece,
  frame-aligned with `styled/styled-neu-neutral-v4-a-centered.png`
- `retint.py <hex> [base] [out]` — luminance-preserving tint normalized so the
  handset surface lands on the exact hex (e.g. `retint.py 73BAC4` for the
  Western Electric teal alternate)
- `finalize.py` — visual centering (mass centroid of the pieces, not the bbox)
  + export into both apps' asset targets; idempotent — it re-derives the mask
  from `mask/gpt-mask-raw.png` (`make_mask.py`) on every run, because the
  centering shift is written back to `mask/handset-mask.png` in place and a
  re-run on an already-shifted mask would drift it out of the render's frame
  (this happened once: the tint spilled onto the D stem until the mask was
  re-derived)

The mask came from GPT-Image-2 asked for a black/white shape mask of the
render (it masks all three pieces; `make_mask.py` keeps the rightmost blob).
Lesson: ask the image model for masks — it beat hand-rolled CV segmentation.

## Design record

The final base render pair is kept at
`design/app-icon/styled/styled-neu-neutral-v4-a.png` (raw) and
`…-a-centered.png` (visually centered, the shipped frame). The design
exploration (candidates, style studies, superseded rolls, contact sheets,
one-off generation scripts) is deliberately **not** kept in the repo — it
lives only in a dangling commit (`17789ed`) until git gc, and the decisions
are recorded in `MEMORY.md`.
