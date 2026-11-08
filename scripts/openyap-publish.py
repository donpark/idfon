#!/usr/bin/env python3
"""Build the publishable Open Yap 1k turn-range dataset.

The public Open Yap 1k sample is 16 conversations (8.92 h) released CC-BY-4.0.
This script filters the gated turn ranges to those 16 conversations and writes
the dataset bundle: ranges.jsonl, manifest.csv, SHA256SUMS and validation.json.
No audio ships; each row names the source conversation and the clip window so a
reader with the public audio re-cuts it locally.

The 16 ids are the public HF repo's conversations
(https://huggingface.co/datasets/TheAgenticDataCompany/open-yap-1k). They are
hardcoded so the build works offline; --verify-public re-fetches the repo's
metadata.jsonl and checks the list.

Usage:
  python scripts/openyap-publish.py \
    --manifest bench-results/openyap-ranges-2026-11-07/manifest_gated.jsonl \
    --out docs/open-yap-turn-annotations

  python scripts/openyap-publish.py --out docs/open-yap-turn-annotations --selfcheck
"""
import argparse
import csv
import hashlib
import json
import os
import sys
import urllib.request
from collections import Counter

PUBLIC_IDS = [
    "conv_04692967d40e", "conv_0c917fc63b3b", "conv_10cf7f6ff081",
    "conv_14f897f75018", "conv_2e4aec4666d8", "conv_31982da49c73",
    "conv_31bedfc99b53", "conv_5a798c657bb0", "conv_756ee444d825",
    "conv_aa4777220a1e", "conv_b98b64206aee", "conv_bcff0c2a0be7",
    "conv_cb37687ec915", "conv_d4005da6db98", "conv_e11edcca8521",
    "conv_f5c0b02f01e2",
]
META_URL = ("https://huggingface.co/datasets/TheAgenticDataCompany/"
            "open-yap-1k/resolve/main/metadata.jsonl")

# The published bundle may not carry speaker profiles or external identities.
FORBIDDEN = {"speaker_id", "age_range", "gender", "country", "education_level",
             "native_language", "accent", "clip", "audio"}

COLS = ["sample_id", "conversation_id", "kind", "dir", "mark", "mark_s",
        "clip_start", "clip_end", "gap_ms", "next_ms", "turn_start", "turn_end",
        "lead_ender", "lead_next", "audio_ender_dom", "audio_next_dom",
        "relationship", "duration_s", "turns_per_minute"]


def verify_public() -> list[str]:
    """Fetch the public repo's conversation ids and compare with the hardcoded list."""
    raw = urllib.request.urlopen(META_URL, timeout=20).read().decode()
    ids = sorted(json.loads(line)["key"] for line in raw.splitlines() if line.strip())
    if ids != sorted(PUBLIC_IDS):
        sys.exit(f"public id list drifted: repo {ids} vs hardcoded {sorted(PUBLIC_IDS)}")
    print(f"public ids match the HF repo ({len(ids)} conversations)")
    return ids


def build(manifest: str, out: str) -> None:
    public = set(PUBLIC_IDS)
    rows = []
    for line in open(manifest):
        if not line.strip():
            continue
        r = json.loads(line)
        if r["conversation_id"] not in public:
            continue
        # The window a reader re-cuts; the mark sits 1.2 s into a 6 s clip
        # unless the turn starts too early to give it that lead.
        r["clip_start"] = round(max(0.0, r["mark"] - 1.2), 3)
        r["clip_end"] = round(r["clip_start"] + 6.0, 3)
        r["mark_s"] = round(r["mark"] - r["clip_start"], 3)
        r["sample_id"] = f"{r['conversation_id']}:{r['kind']}:{r['mark']:.2f}"
        rows.append(r)

    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "ranges.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

    with open(os.path.join(out, "manifest.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)

    by_kind = dict(sorted(Counter(r["kind"] for r in rows).items()))
    by_dir = dict(sorted(Counter(r["dir"] for r in rows).items()))
    by_conv = len({r["conversation_id"] for r in rows})
    # duration_s repeats per row; count each conversation once.
    hours = round(sum({r["conversation_id"]: r["duration_s"] for r in rows}.values()) / 3600, 2)
    summary = {"rows": len(rows), "conversations": by_conv,
               "by_kind": by_kind, "by_dir": by_dir, "hours": hours}
    with open(os.path.join(out, "validation.json"), "w") as f:
        json.dump(summary, f, indent=2, sort_keys=True)
        f.write("\n")

    with open(os.path.join(out, "SHA256SUMS"), "w") as f:
        for name in ("ranges.jsonl", "manifest.csv"):
            h = hashlib.sha256(open(os.path.join(out, name), "rb").read()).hexdigest()
            f.write(f"{h}  {name}\n")

    print(json.dumps(summary, indent=2))


def selfcheck(out: str) -> None:
    """Validate the built bundle: ids, schema, no PII, checksums."""
    rows = [json.loads(line) for line in open(os.path.join(out, "ranges.jsonl")) if line.strip()]
    assert rows, "empty ranges.jsonl"
    public = set(PUBLIC_IDS)
    bad = {r["conversation_id"] for r in rows} - public
    assert not bad, f"rows outside the public 16: {sorted(bad)[:5]}"
    keys = set().union(*(r.keys() for r in rows))
    leaked = keys & FORBIDDEN
    assert not leaked, f"forbidden fields in rows: {sorted(leaked)}"
    for r in rows:
        assert r["kind"] in {"handoff", "silent_tail", "overlap", "backchannel"}, r["kind"]
        assert r["dir"] in {"a2b", "b2a"}, r["dir"]
        assert r["clip_start"] >= 0 and r["clip_end"] > r["clip_start"], r
        assert abs(r["clip_start"] + r["mark_s"] - r["mark"]) < 0.001, r
    for line in open(os.path.join(out, "SHA256SUMS")):
        digest, name = line.split()
        got = hashlib.sha256(open(os.path.join(out, name), "rb").read()).hexdigest()
        assert got == digest, f"checksum mismatch: {name}"
    summary = json.load(open(os.path.join(out, "validation.json")))
    assert summary["rows"] == len(rows), summary
    print(f"selfcheck OK: {len(rows)} rows, {summary['conversations']} conversations, "
          f"{summary['by_kind']}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest",
                    default="bench-results/openyap-ranges-2026-11-07/manifest_gated.jsonl")
    ap.add_argument("--out", default="docs/open-yap-turn-annotations")
    ap.add_argument("--verify-public", action="store_true",
                    help="re-fetch the HF metadata and check the 16-id list")
    ap.add_argument("--selfcheck", action="store_true",
                    help="validate an existing bundle instead of building")
    args = ap.parse_args()
    if args.verify_public:
        verify_public()
    if args.selfcheck:
        selfcheck(args.out)
        return
    build(args.manifest, args.out)


if __name__ == "__main__":
    main()
