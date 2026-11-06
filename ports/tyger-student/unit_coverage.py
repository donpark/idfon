"""Independent-unit accounting for the registry's decision points.

Every report so far counts frames or pooled events. A graduation claim needs
independent units: a head can be right on 99.9% of frames and wrong on every
interruption, because frames, and usually events, within one call are not
independent. This prints, per head and per shard set:

  units   sessions holding at least one positive
  pos     positives in total
  /unit   positives per session that has one
  miss95  95% Clopper-Pearson upper bound on the miss rate when no miss has been
          seen yet in `pos` independent positives: 1 - 0.05 ** (1/pos)
  u95     the same bound with each session counted once, not each event: the
          conservative reading, since events in one call share a caller, a mic
          and an acoustic setting. Report both; never quote miss95 alone.
  need    independent UNITS required for `--target` (default 2%)

A head is graduable only at `units >= need`: 149 independent calls at 2%. The
event count is context, never the verdict -- a thousand events in one call are
one acoustic condition. Neither count proves anything until misses are measured
against a frozen policy; `u95` is an upper bound on the *absence* of evidence,
not a demonstrated miss rate. Corpus heads count the onsets of their `lab_<key>` (a frame
where the label rises 0 -> 1). Teacher heads count the shard's `ev_kinds` for
the kinds they emit; `state` and `hazard` emit no events and inherit their
siblings' units. Live shards carry no corpus labels, so they count teacher
events only -- which measures the teacher, never the truth.

    .venv/bin/python ports/tyger-student/unit_coverage.py \
        --shards bench-results/student-shards/train bench-results/student-shards/val \
                 bench-results/live-shipping-fixed
"""
from __future__ import annotations

import argparse
import glob
import json
import math
import os
import sys
import tempfile

import numpy as np

from data import iter_shards, load_shard, save_shard
from registry import HEADS, corpus_key

FRAME_S = 0.08
# the shard event kinds each emitting head produces (rules layer: turns.rs)
EVENT_KIND = {"endpoint": "ENDPOINT", "barge": "BARGE", "backchannel": "BACKCHANNEL"}


def need(target: float) -> int:
    """Independent positives for a target miss-rate bound, at 95% one-sided and zero misses seen."""
    return math.ceil(math.log(0.05) / math.log(1.0 - target))


def upper(pos: int) -> float:
    """95% Clopper-Pearson upper bound on the miss rate after `pos` independent positives, none missed."""
    return 1.0 - 0.05 ** (1.0 / pos) if pos else 1.0


def onsets(series) -> int:
    """Rising edges 0 -> 1: one positive per labelled event, not per frame."""
    s = np.asarray(series, dtype=np.int8)
    return int(((s[1:] == 1) & (s[:-1] == 0)).sum()) + int(bool(len(s) and s[0]))


def count(shards: str, target: float) -> dict:
    """Per head, the independent-unit counts over one shard set."""
    rows: dict[str, dict] = {}
    frames = sessions = speaking = 0
    prev_seen: set[int] = set()
    on = {head.id: False for head in HEADS}
    for _path, fr, labels, events, meta in iter_shards(shards):
        sessions += 1
        frames += int(meta.get("frames") or len(fr["energy"]))
        if "mode" in fr:
            speaking += int((fr["mode"] == 1).sum())
        prev_seen.update(int(v) for v in np.unique(fr["prev_state"]))
        for head in HEADS:
            row = rows.setdefault(head.id, {"units": 0, "pos": 0})
            key = corpus_key(head)
            n = 0
            if key and key in labels:
                on[head.id] = True
                n = onsets(labels[key])
            elif head.id in EVENT_KIND and events is not None:
                n = int(sum(1 for k in events[1] if k == EVENT_KIND[head.id]))
            elif head.id in ("state", "hazard"):
                row.setdefault("note", "no event of its own")
            row["pos"] += n
            row["units"] += int(n > 0)
    for head in HEADS:
        row = rows[head.id]
        row["per_unit"] = round(row["pos"] / row["units"], 1) if row["units"] else 0.0
        row["miss95"] = round(upper(row["pos"]), 4)
        row["u95"] = round(upper(row["units"]), 4)
        row["need"] = need(target)
        row["ok"] = row["units"] >= row["need"]  # the session bound is the verdict; events are context
        if corpus_key(head) and not on[head.id]:
            row["note"] = "no corpus labels in this set"
        row.setdefault("note", "")
    return {"shards": shards, "sessions": sessions, "minutes": round(frames * FRAME_S / 60, 1),
            "speaking": round(speaking / frames, 3) if frames else 0.0,
            "prev_state": sorted(prev_seen), "target": target, "heads": rows}


def report(rep: dict) -> None:
    h = rep["heads"]
    print(f"\n{rep['shards']}  —  {rep['sessions']} sessions, {rep['minutes']} min, "
          f"speaking {100 * rep['speaking']:.0f}% of frames, prev_state {rep['prev_state']}")
    if rep["speaking"] == 0:
        print("  ! listen-only replay: no BARGE can fire and the SPEAK gate never opens,")
        print("    so event references here cannot support any barge claim")
    print(f"  {'head':<12} {'units':>5} {'pos':>5} {'/unit':>6} {'miss95':>7} {'u95':>7} {'need':>5}  verdict")
    for head in HEADS:
        r = h[head.id]
        verdict = "OK" if r["ok"] else f"short {r['need'] - r['units']} units"
        print(f"  {head.id:<12} {r['units']:>5} {r['pos']:>5} {r['per_unit']:>6} "
              f"{r['miss95']:>7} {r['u95']:>7} {r['need']:>5}  {verdict}"
              f"{('  (' + r['note'] + ')') if r['note'] else ''}")


def selfcheck() -> None:
    """The bound arithmetic, the onset count, and one synthetic shard through the loader."""
    assert need(0.02) == 149 and need(0.01) == 299, (need(0.02), need(0.01))
    assert abs(upper(30) - 0.0950) < 5e-4, upper(30)
    assert abs(upper(300) - 0.00994) < 5e-5, upper(300)
    assert upper(0) == 1.0 and upper(10) > upper(100)
    assert onsets([0, 1, 1, 0, 1]) == 2 and onsets([1, 1, 0]) == 1 and onsets([0, 0]) == 0
    T = 40
    frames = {"hu": np.zeros((T, 2), np.float32), "ha": np.zeros((T, 2), np.float32),
              "energy": np.zeros(T, np.float32), "prev_state": np.zeros(T, np.int64),
              "teacher": np.zeros((T, 8), np.float32)}
    lab = np.zeros(T, np.int8)
    lab[[5, 6, 20]] = 1
    with tempfile.TemporaryDirectory() as tmp:
        save_shard(os.path.join(tmp, "s.npz"), "sess-1", frames, {"hold_ch0": lab},
                   events=([7, 9, 30], ["ENDPOINT", "BARGE", "ENDPOINT"]))
        rep = count(tmp, 0.02)
        rows = rep["heads"]
        assert rep["sessions"] == 1 and rep["minutes"] == round(T * FRAME_S / 60, 1)
        assert rows["hold"]["pos"] == 2, rows["hold"]  # two onsets, not three frames
        assert rows["endpoint"]["pos"] == 2 and rows["barge"]["pos"] == 1
        assert not rows["endpoint"]["ok"] and rows["endpoint"]["units"] == 1  # 1 unit, not 2 events
        assert rows["state"]["pos"] == 0 and not rows["endpoint"]["ok"]
        assert rep["speaking"] == 0.0, rep["speaking"]  # no mode track: the listen-only warning
        assert rows["state"]["note"] == "no event of its own"
        frames["mode"] = np.ones(T, np.int8)
        save_shard(os.path.join(tmp, "s2.npz"), "sess-2", frames, {})
        assert count(tmp, 0.02)["speaking"] == 0.5
    print("selfcheck ok")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", nargs="+", default=[], help="shard directories (one or more)")
    ap.add_argument("--target", type=float, default=0.02, help="miss-rate bound a head must reach (default 2%%)")
    ap.add_argument("--json", action="store_true", help="machine-readable report instead of the table")
    ap.add_argument("--selfcheck", action="store_true", help="arithmetic and loader checks, no files")
    a = ap.parse_args()
    if a.selfcheck:
        return selfcheck()
    if not a.shards:
        ap.error("--shards is required (or --selfcheck)")
    reps = [count(d, a.target) for d in a.shards]
    if a.json:
        print(json.dumps(reps, indent=2))
        return
    for rep in reps:
        report(rep)


if __name__ == "__main__":
    main()
