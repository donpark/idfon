"""Draw the v0 release sample from the gated Open Yap ranges.

The gated set is 161,432 ranges; a hand-auditable release is smaller. This draws
a stratified sample (kind x gap bucket). The published artefact is the label
record only: the Data Use Agreement permits redistributing annotated ranges,
not the audio. Each row carries the source conversation and the clip window, so
a reader who already has the dataset can re-cut the same audio locally with
`--clips`.

Stratification matters because the gated set is dominated by overlaps (69%) and
by short gaps; a uniform sample would measure overlap behaviour and little else.

Usage:
  python scripts/openyap-v0.py \
    --manifest bench-results/openyap-ranges-2026-11-07/manifest_gated.jsonl \
    --out bench-results/openyap-v0-2026-11-07 --n 1000

  # internal audition only -- never publish the resulting clips
  python scripts/openyap-v0.py ... --clips
"""
import argparse
import csv
import importlib.util
import json
import os
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_ranges():
    spec = importlib.util.spec_from_file_location(
        "openyap_ranges", os.path.join(ROOT, "scripts", "openyap-ranges.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def bucket(r: dict) -> str:
    """The gap stratum an event falls in."""
    g = r["gap_ms"]
    k = r["kind"]
    if k == "handoff":
        return "handoff_short" if g <= 160 else "handoff_long"
    if k == "silent_tail":
        return "tail_short" if g <= 640 else "tail_long"
    if k == "overlap":
        return "overlap_short" if g >= -500 else "overlap_long"
    return "backchannel"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--data", default="datasets/open-yap-1k_2026-11-07_flac_372fb0fd")
    ap.add_argument("--out", required=True)
    ap.add_argument("--n", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--clip-s", type=float, default=6.0)
    ap.add_argument("--clips", action="store_true",
                    help="materialise audio too (internal audition; not redistributable)")
    args = ap.parse_args()

    rows = [json.loads(l) for l in open(args.manifest) if l.strip()]
    strata = defaultdict(list)
    for r in rows:
        strata[bucket(r)].append(r)

    # Equal per stratum, so a 2% stratum is not drowned by the 69% one.
    per = max(1, args.n // len(strata))
    import random
    rng = random.Random(args.seed)
    picked = []
    for name in sorted(strata):
        pool = strata[name]
        take = min(per, len(pool))
        picked.extend(rng.sample(pool, take))
    rng.shuffle(picked)

    os.makedirs(args.out, exist_ok=True)
    ranges_mod = load_ranges()
    clips_dir = os.path.join(args.out, "clips")
    if args.clips:
        os.makedirs(clips_dir, exist_ok=True)
    made = 0
    for r in picked:
        # The window a reader can re-cut from the dataset; the mark is inside it.
        r["clip_start"] = round(max(0.0, r["mark"] - 1.2), 3)
        r["clip_end"] = round(r["clip_start"] + args.clip_s, 3)
        r["mark_s"] = 1.2          # the mark's offset in a 6 s clip
        if args.clips and ranges_mod._clip(r, args.data, clips_dir, args.clip_s):
            made += 1
            # the page resolves clip paths against the bundle dir
            r["clip"] = f"clips/{r['conversation_id']}_{r['kind']}_{r['mark']:.2f}.wav"

    with open(os.path.join(args.out, "ranges.jsonl"), "w") as f:
        for r in picked:
            f.write(json.dumps(r) + "\n")
    cols = ["sample_id", "conversation_id", "kind", "dir", "mark", "mark_s",
            "clip_start", "clip_end", "gap_ms", "next_ms", "turn_start", "turn_end",
            "lead_ender", "lead_next", "audio_ender_dom", "audio_next_dom",
            "relationship"]
    if args.clips:
        cols.append("clip")
    with open(os.path.join(args.out, "manifest.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for i, r in enumerate(picked):
            r = dict(r)
            r["sample_id"] = f"{r['conversation_id']}:{r['kind']}:{r['mark']:.2f}"
            w.writerow(r)

    from collections import Counter
    print(f"picked {len(picked)} rows, {made} clips" if args.clips
          else f"picked {len(picked)} ranges (no audio)")
    print("by stratum:", dict(Counter(bucket(r) for r in picked)))
    print("by kind:", dict(Counter(r["kind"] for r in picked)))


if __name__ == "__main__":
    main()
