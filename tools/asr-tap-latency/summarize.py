"""Markdown tables for docs/voice-tyger-ondevice.md from the probe's JSON."""
import json
import sys
from pathlib import Path


def fmt(d, keys=("p50", "p95", "max"), nd=1):
    return " / ".join("—" if d.get(k) is None else f"{d[k]:.{nd}f}" for k in keys)


def main(paths):
    for p in paths:
        doc = json.loads(Path(p).read_text())
        print(f"\n### {Path(p).name}  (buffer {doc['buffer_frames']}, hook {doc['hook']})")
        print("| session | mode | frames | chunks | frame delay p50/p95/max | chunk lag p50/p95/max "
              "| pre-hook p50 | post-hook p50/p95 | decode p50/p95 | measured − offline p50/p95/max |")
        print("| --- | --- | ---: | ---: | --- | --- | ---: | --- | --- | --- |")
        for s in doc["sessions"]:
            print(f"| {s['session'][-9:]} | {s['mode']} | {s['frames']} | {s['chunks']} "
                  f"| {fmt(s['delay_ms'])} | {fmt(s['chunk_lag_ms'])} "
                  f"| {s['pre_hook_ms'].get('p50', 0):.1f} | {fmt(s['post_hook_ms'], ('p50', 'p95'))} "
                  f"| {fmt(s['decode_ms'], ('p50', 'p95'))} | {fmt(s['vs_offline_ms'])} |")
        for s in doc["sessions"]:
            rows = {int(k[1:]): v["p50"] for k, v in s["by_row_ms"].items()}
            print(f"  {s['session'][-9:]} {s['mode']:8s} by row p50: "
                  + "  ".join(f"k{k} {rows[k]:.0f}" for k in sorted(rows)))
        for s in doc["sessions"]:
            print(f"  {s['session'][-9:]} {s['mode']:8s} tokens {s['tokens']} "
                  f"last-token {s['token_last_s']:.2f}s of {s['seconds']:.0f}s  "
                  f"transcript \"{s['transcript'][:70]}\"")


if __name__ == "__main__":
    main(sys.argv[1:])
