"""Find training data worth having: pool the handoffs the turn model gets wrong.

The tone reader is a curator here, not a component. It labels each handoff's caller
turn from the words (backchannel vs turn, move shape, emotion), which is the axis
the audio model cannot separate on its own -- a 300 ms "mm-hm" and a 300 ms "wait"
look alike to the yield head. Pooling by that label turns 80 minutes of public
conversation into a short, targeted audition list.

Pools (each clip is 6 s, agent audible first, mark at the caller's onset):

  missed_short_turn   <=600 ms caller turn, not a backchannel, model did not fire
                      -- the blind spot: 59% of short turns go uncaught
  caught_short_turn   the same shape, caught -- the control for tuning
  backchannel         p(backchannel) >= --bc-tau: hard negatives (must NOT fire)
  missed_close        move is `closes` and the model missed it: turn-end material

    .venv/bin/python scripts/openyap-curate.py --wavs /tmp/openyap/wav \\
        --transcripts /tmp/openyap/tar --model /tmp/tonemodel \\
        --shards bench-results/openyap-shards-v2 --out /tmp/openyap/curated

  --selfcheck   pool assignment on synthetic handoff rows, no models
"""
from __future__ import annotations

import argparse
import csv
import glob
import importlib.util
import json
import os
import sys

import numpy as np

FRAME_S = 0.08
WINDOW_FRAMES = 9      # 640 ms after the caller onset


def _mod(name: str, filename: str):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), filename)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def pool_of(row: dict, bc_tau: float, short_ms: int) -> str | None:
    """Which audition pool a handoff belongs to, if any."""
    if row["p_backchannel"] >= bc_tau:
        return "backchannel"
    if row["caller_run_ms"] <= short_ms:
        return "caught_short_turn" if row["fired"] else "missed_short_turn"
    if row["move"] == "closes" and not row["fired"]:
        return "missed_close"
    return None


def selfcheck() -> None:
    base = {"p_backchannel": 0.1, "caller_run_ms": 400, "fired": False, "move": "answers"}
    assert pool_of(base, 0.7, 600) == "missed_short_turn"
    assert pool_of({**base, "fired": True}, 0.7, 600) == "caught_short_turn"
    assert pool_of({**base, "p_backchannel": 0.9}, 0.7, 600) == "backchannel"
    assert pool_of({**base, "caller_run_ms": 1500}, 0.7, 600) is None
    assert pool_of({**base, "caller_run_ms": 1500, "move": "closes"}, 0.7, 600) == "missed_close"
    # a long backchannel-length label still wins over length: backchannels are short by nature
    assert pool_of({**base, "caller_run_ms": 900, "p_backchannel": 0.95}, 0.7, 600) == "backchannel"
    print("selfcheck ok")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wavs")
    ap.add_argument("--transcripts")
    ap.add_argument("--model")
    ap.add_argument("--shards")
    ap.add_argument("--out")
    ap.add_argument("--per-pool", type=int, default=12)
    ap.add_argument("--bc-tau", type=float, default=0.7)
    ap.add_argument("--short-ms", type=int, default=600)
    ap.add_argument("--yield-thr", type=float, default=0.5)
    ap.add_argument("--seed", type=int, default=125)
    ap.add_argument("--selfcheck", action="store_true")
    a = ap.parse_args()
    if a.selfcheck:
        return selfcheck()
    if not (a.wavs and a.transcripts and a.model and a.shards and a.out):
        ap.error("--wavs, --transcripts, --model, --shards and --out are required")

    H = _mod("openyap_handoffs", "openyap-handoffs.py")
    T = _mod("openyap_tone", "openyap-tone.py")
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ports", "tyger-student"))
    from data import load_shard

    tone = T.Tone(a.model)
    shards = {os.path.basename(p)[5:-4]: p for p in glob.glob(os.path.join(a.shards, "*.npz"))}
    os.makedirs(a.out, exist_ok=True)

    rows = []
    for wav in sorted(glob.glob(os.path.join(a.wavs, "*.wav"))):
        cid = os.path.basename(wav)[:-4]
        meta = os.path.join(a.transcripts, cid + ".json")
        if not os.path.exists(meta) or cid not in shards:
            continue
        words = json.load(open(meta))["transcripts"]["a"]["words"]
        caller, agent = H.energy(wav)
        frames, _l, _e, _m = load_shard(shards[cid])
        y = frames["teacher"][:, 5]
        for h in H.handoffs(caller, agent):
            t_on = h["caller_on"] * FRAME_S
            text = T.turn_text(words, t_on, h["caller_off"] * FRAME_S)
            if not text:
                continue
            win = y[h["caller_on"]:h["caller_on"] + WINDOW_FRAMES]
            peak = float(win.max()) if len(win) else 0.0
            fired = peak >= a.yield_thr
            t = tone.read(text)
            row = {"conversation_id": cid, "caller_on": h["caller_on"], "wav": wav,
                   "gap_ms": h["gap_ms"], "caller_run_ms": h["caller_run_ms"],
                   "move": t["move"], "emotion": t["emotion"],
                   "p_backchannel": t["p_backchannel"], "yield_peak": round(peak, 3),
                   "fired": fired, "text": t["text"]}
            row["pool"] = pool_of(row, a.bc_tau, a.short_ms)
            if row["pool"]:
                rows.append(row)

    rng = np.random.default_rng(a.seed)
    out_rows = []
    print(f"\n{'pool':<20}{'found':>7}{'clips':>7}   what it is for")
    why = {"missed_short_turn": "the blind spot: short turns that never fire",
           "caught_short_turn": "control: short turns that do fire",
           "backchannel": "hard negatives: must not fire",
           "missed_close": "turn ends the model does not see"}
    for name in ("missed_short_turn", "caught_short_turn", "backchannel", "missed_close"):
        pool = [r for r in rows if r["pool"] == name]
        pick = [pool[int(i)] for i in rng.permutation(len(pool))[:a.per_pool]]
        made = 0
        for r in pick:
            fname = f"{r['conversation_id']}-{name}-{r['caller_on'] * FRAME_S:.2f}s.wav"
            got = H.cut(r["wav"], r["caller_on"], a.out, fname, gap_ms=r["gap_ms"])
            if not got:
                continue
            _path, mark = got
            out_rows.append({"sample_id": f"{name[:2].upper()}{made + 1:03d}",
                             "conversation_id": r["conversation_id"], "pool": name,
                             "ts_s": round(r["caller_on"] * FRAME_S, 2), "kind": name,
                             "clip": fname, "mark_s": mark,
                             "caller_run_ms": r["caller_run_ms"], "gap_ms": r["gap_ms"],
                             "move": r["move"], "emotion": r["emotion"],
                             "p_backchannel": round(r["p_backchannel"], 2),
                             "yield_peak": r["yield_peak"], "text": r["text"]})
            made += 1
        print(f"{name:<20}{len(pool):>7}{made:>7}   {why[name]}")

    cols = ["sample_id", "conversation_id", "pool", "ts_s", "kind", "clip", "mark_s",
            "caller_run_ms", "gap_ms", "move", "emotion", "p_backchannel", "yield_peak", "text"]
    path = os.path.join(a.out, "manifest.csv")
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in out_rows:
            w.writerow(r)
    print(f"\n{len(out_rows)} clips + {path}")
    with open(os.path.join(a.out, "rows.jsonl"), "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    total = len(rows)
    print(f"{total} handoffs pooled from {len(glob.glob(os.path.join(a.shards, '*.npz')))} sessions"
          f" ({sum(1 for r in rows if r['fired'])} fired)")


if __name__ == "__main__":
    main()
