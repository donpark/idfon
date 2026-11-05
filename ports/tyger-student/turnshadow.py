"""TurnShadow — the diff harness that gates a tier swap-over (epic #132 P7, #161).

Runs a candidate export tier against the **authoritative path** (today: the fp32
student the apps ship) on recorded sessions, and reports the three things a swap
must not silently change:

- **per-axis disagreement** — per-frame |Δ| of the 8-vector (state logits, hazard,
  yield, bc, p_end) between the two paths;
- **decision flips** — the events each path's rules emit, matched same-kind within
  ±tol frames, with the unmatched ones listed by kind and frame;
- **latency delta** — per-frame ms each side, with the measured contention stamp.

Shadow only. Nothing here feeds a live call: the authoritative path is replayed
from a checkpoint, the candidate from an artifact, and both are read-only. A tier
that fails to load or throws mid-replay is reported `unavailable` — the run
continues (fail-open: classic turn-taking is untouched by construction and is not
modeled here; it is the apps' `Segmenter`, a different seam).

Swap-over gate (which flips block):
  blocking      any ENDPOINT flip (miss/extra = turn structure changes),
                any BARGE flip (stops playback; the safety path),
                any per-head prob > the P4 envelope (2e-3),
                p95 step cost above the frame budget's headroom (`--max-ms`, 8 ms)
  reported only BACKCHANNEL flips (the known boundary-jitter class:
                docs/voice-tyger-ondevice.md, parity7) — tolerated, counted,
                and never averaged away in the report.

Usage:
  .venv/bin/python ports/tyger-student/turnshadow.py \
      --matrix bench-results/matrix --fp32 bench-results/shared-consistent-l03/student.pt \
      [--adapters l4-streaming] [--tiers onnx,mlx] [--sessions 2] [--frames 500] [--tol 2]
Output: <matrix>/shadow.json + shadow.md
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

import runners  # noqa: E402
from data import iter_shards  # noqa: E402
from export import load_student  # noqa: E402
from gate import aligned_count  # noqa: E402
from oracle import HOP_FRAMES, Oracle  # noqa: E402

BLOCKING_KINDS = ("ENDPOINT", "BARGE")
AXES = ("state", "hazard", "yield", "bc", "p_end")
DEFAULTS = {"ep_thr": 0.9146, "barge_thr": 0.5, "bc_thr": 0.5}


def replay(step, oracle, frames, thr, deb, width, layers):
    """One session through one path: carried GRU state + the rules' live floor state
    (gate.py's live semantics) -> (events, per-frame 8-vectors)."""
    sess = oracle.EarsSession(0, ep_thr=thr[0], ep_deb=deb[0], barge_thr=thr[1],
                              barge_deb=deb[1], bc_thr=thr[2], bc_deb=deb[2])
    hidden = np.zeros((layers, 1, width), np.float32)
    last_mode = None
    modes = frames.get("mode")
    events, out8 = [], []
    for f in range(len(frames["energy"])):
        mode = "speaking" if modes is not None and int(modes[f]) else "listen"
        if mode != last_mode:
            if oracle.rules.switch_mode(sess, mode):
                hidden = np.zeros((layers, 1, width), np.float32)
            last_mode = mode
        out, hidden = step(frames["hu"][f], frames["ha"][f], float(frames["energy"][f]),
                           int(sess.prev_state), hidden)
        out8.append(out)
        evs, _final, reset = oracle.rules.on_frame(
            sess, mode, out, float(frames["energy"][f]), left=3 - (f % HOP_FRAMES))
        if reset:
            hidden = np.zeros((layers, 1, width), np.float32)
        for e in evs:
            if e["kind"] != "FRAME":
                events.append((f + 1, e["kind"]))  # parity7 counts frames 1-based
    return events, np.stack(out8)


def axis_diff(a, b):
    """Per-frame |Δ| per decision axis (state = the 4 logits treated as one block)."""
    d = {"state": float(np.abs(a[:, :4] - b[:, :4]).max())}
    for i, name in enumerate(AXES[1:], start=4):
        d[name] = float(np.abs(a[:, i] - b[:, i]).max())
    mean = {"state": float(np.abs(a[:, :4] - b[:, :4]).mean())}
    for i, name in enumerate(AXES[1:], start=4):
        mean[name] = float(np.abs(a[:, i] - b[:, i]).mean())
    p95 = {"state": float(np.percentile(np.abs(a[:, :4] - b[:, :4]), 95))}
    for i, name in enumerate(AXES[1:], start=4):
        p95[name] = float(np.percentile(np.abs(a[:, i] - b[:, i]), 95))
    return {"max": d, "mean": mean, "p95": p95}


def match_events(a, b, tol):
    """parity7's greedy same-kind matching within ±tol frames (gate.aligned_count's
    semantics) but returning the unmatched events, which is what a shadow reports."""
    used = set()
    aligned = []
    for i, (fa, ka) in enumerate(a):
        for j, (fb, kb) in enumerate(b):
            if j not in used and ka == kb and abs(fa - fb) <= tol:
                used.add(j)
                aligned.append(i)
                break
    only_a = [e for i, e in enumerate(a) if i not in set(aligned)]
    only_b = [e for j, e in enumerate(b) if j not in used]
    return len(aligned), only_a, only_b


def shadow_cell(tier, variant, path, adapter, ref_step, width, layers, shard_dir,
                sessions, max_frames, tol, thr, deb, max_ms):
    cand, meta = runners.load(tier, path, width, layers)
    oracle = Oracle(device="cpu")  # rules only; both paths are their own chains
    missing, spurious, flips = {}, {}, []
    worst = {"max": {k: 0.0 for k in AXES}, "mean": {k: 0.0 for k in AXES},
             "p95": {k: 0.0 for k in AXES}}
    n_frames = n_ref = n_cand = aligned = seen = 0
    last = None
    for i, (_p, frames, _l, events, smeta) in enumerate(iter_shards(str(shard_dir))):
        if seen >= sessions:
            break
        if events is None:
            continue
        n = min(max_frames, len(frames["energy"]))
        frames = {k: (v[:n] if isinstance(v, np.ndarray) else v) for k, v in frames.items()}
        last = frames
        ev_ref, out_ref = replay(ref_step, oracle, frames, thr, deb, width, layers)
        ev_cand, out_cand = replay(cand, oracle, frames, thr, deb, width, layers)
        d = axis_diff(out_ref, out_cand)
        for k in AXES:
            worst["max"][k] = max(worst["max"][k], d["max"][k])
            worst["p95"][k] = max(worst["p95"][k], d["p95"][k])
            worst["mean"][k] += d["mean"][k]
        al, only_ref, only_cand = match_events(ev_ref, ev_cand, tol)
        for e in only_ref:
            missing[e[1]] = missing.get(e[1], 0) + 1
            flips.append({"session": smeta["session_id"], "frame": int(e[0]),
                          "kind": e[1], "side": "missing"})
        for e in only_cand:
            spurious[e[1]] = spurious.get(e[1], 0) + 1
            flips.append({"session": smeta["session_id"], "frame": int(e[0]),
                          "kind": e[1], "side": "spurious"})
        n_frames += n
        n_ref += len(ev_ref)
        n_cand += len(ev_cand)
        aligned += al
        seen += 1
    if not seen:
        raise RuntimeError("no recorded sessions with events")
    for k in AXES:
        worst["mean"][k] /= seen
    agree = aligned / max(n_ref, n_cand) if max(n_ref, n_cand) else 1.0
    zero = np.zeros((layers, 1, width), np.float32)
    ms_ref, _ = runners.ms_per_frame(ref_step, last["hu"][0], last["ha"][0],
                                     float(last["energy"][0]), int(last["prev_state"][0]),
                                     zero, reps=100)
    ms_cand, p95_cand = runners.ms_per_frame(cand, last["hu"][0], last["ha"][0],
                                             float(last["energy"][0]),
                                             int(last["prev_state"][0]), zero, reps=100)
    blocking = [f for f in flips if f["kind"] in BLOCKING_KINDS]
    too_slow = p95_cand > max_ms
    probs_over = any(worst["max"][k] > 2e-3 for k in AXES[1:])
    verdict = ("block" if blocking or too_slow or probs_over else "ok")
    return {"tier": tier, "variant": variant, "artifact": str(path), "runner": meta,
            "frames": n_frames, "events_ref": n_ref, "events_cand": n_cand,
            "agree": round(agree, 4), "axis_delta": worst, "flips": flips,
            "flips_by_kind": {"missing": missing, "spurious": spurious},
            "ms_frame": {"ref": round(ms_ref, 4), "cand": round(ms_cand, 4),
                         "p95_cand": round(p95_cand, 4), "delta": round(ms_cand - ms_ref, 4)},
            "max_ms": max_ms, "verdict": verdict,
            "reasons": ([f"{len(blocking)} endpoint/barge flips"] if blocking else [])
                       + ([f"p95 {p95_cand:.2f} ms > {max_ms}"] if too_slow else [])
                       + (["per-head drift above 2e-3"] if probs_over else []),
            "contended": runners.contention()}


def selfcheck():
    """match_events must stay parity7-shaped: greedy, same-kind, within ±tol."""
    a = [(10, "ENDPOINT"), (20, "BACKCHANNEL"), (40, "BARGE")]
    b = [(12, "ENDPOINT"), (20, "BACKCHANNEL"), (60, "BARGE")]
    al, only_a, only_b = match_events(a, b, 2)
    assert (al, only_a, only_b) == (2, [(40, "BARGE")], [(60, "BARGE")]), (al, only_a, only_b)
    al, only_a, only_b = match_events([(5, "ENDPOINT")], [(5, "BARGE")], 2)
    assert (al, only_a, only_b) == (0, [(5, "ENDPOINT")], [(5, "BARGE")]), "kinds must not cross-match"
    print("selfcheck ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix", default=str(ROOT / "bench-results/matrix"),
                    help="a run of export_matrix.py (matrix.json + the cell artifacts)")
    ap.add_argument("--fp32", default=str(ROOT / "bench-results/shared-consistent-l03/student.pt"),
                    help="the authoritative path's checkpoint (the current fp32 student)")
    ap.add_argument("--adapters", default=None, help="comma list (default: matrix.json's)")
    ap.add_argument("--tiers", default=None, help="comma list of tiers to shadow")
    ap.add_argument("--sessions", type=int, default=2, help="recorded sessions per cell")
    ap.add_argument("--frames", type=int, default=500, help="frames per session")
    ap.add_argument("--tol", type=int, default=2, help="same-kind match tolerance, frames")
    ap.add_argument("--out", default=None,
                    help="report path (default: <matrix>/shadow.json; the md derives from it). "
                         "A second run with --fp32 <the candidate's own checkpoint> isolates the "
                         "tier from the checkpoint swap")
    ap.add_argument("--max-ms", type=float, default=8.0,
                    help="p95 per-frame budget for a swap (80 ms frame / 10x headroom)")
    ap.add_argument("--selfcheck", action="store_true", help="check the pure logic, shadow nothing")
    args = ap.parse_args()
    if args.selfcheck:
        selfcheck()
        return

    mat = json.loads((Path(args.matrix) / "matrix.json").read_text())
    adapters = ([a.strip() for a in args.adapters.split(",")] if args.adapters
                else list(mat["adapters"]))
    tiers = [t.strip() for t in args.tiers.split(",")] if args.tiers else None
    width = layers = None
    rows = []
    for adapter in adapters:
        info = mat["adapters"][adapter]
        shard_dir = Path(info["shards"])
        traits = info.get("traits") or {}
        dec = traits.get("decider") or DEFAULTS
        thr = (dec["ep_thr"], dec["barge_thr"], dec["bc_thr"])
        deb = (dec.get("ep_deb", 2), dec.get("barge_deb", 2), dec.get("bc_deb", 2))
        model, _ = load_student(args.fp32, tap=adapter)
        width, layers = model.width, model.layers
        ref = runners.torch_step(model)
        print(f"\n== {adapter}: authoritative fp32 student, {args.sessions} session(s) x "
              f"{args.frames} frames, traits {thr}", flush=True)
        for c in [c for c in mat["cells"]
                  if c["adapter"] == adapter and c.get("exports") and (not tiers or c["tier"] in tiers)]:
            if not c["loads"]["loads"]:
                rows.append({"adapter": adapter, "tier": c["tier"], "variant": c["variant"],
                             "status": "unavailable", "detail": c["loads"]["detail"],
                             "verdict": "no-shadow"})
                print(f"  {c['tier']}-{c['variant']}: unavailable ({c['loads']['detail']})",
                      flush=True)
                continue
            t0 = time.perf_counter()
            try:
                r = shadow_cell(c["tier"], c["variant"], c["path"], adapter, ref, width,
                                layers, shard_dir, args.sessions, args.frames, args.tol,
                                thr, deb, args.max_ms)
            except Exception as e:  # fail-open: a tier that throws is not shadowable
                rows.append({"adapter": adapter, "tier": c["tier"], "variant": c["variant"],
                             "status": "error", "detail": f"{type(e).__name__}: {str(e)[:200]}",
                             "verdict": "no-shadow"})
                print(f"  {c['tier']}-{c['variant']}: ERROR {str(e)[:100]}", flush=True)
                continue
            r["adapter"] = adapter
            r["verify_s"] = round(time.perf_counter() - t0, 1)
            rows.append(r)
            fk = r["flips_by_kind"]
            print(f"  {c['tier']}-{c['variant']}: agree {r['agree']:.2%} "
                  f"({r['events_ref']} ref / {r['events_cand']} cand), "
                  f"missing {sum(fk['missing'].values())} spurious "
                  f"{sum(fk['spurious'].values())}, "
                  f"probs max {max(r['axis_delta']['max'][k] for k in AXES[1:]):.2e}, "
                  f"{r['ms_frame']['cand']:.3f} ms/frame (ref {r['ms_frame']['ref']:.3f}) -> "
                  f"{r['verdict'].upper()} {r['reasons'] or ''}", flush=True)

    out = Path(args.out) if args.out else Path(args.matrix) / "shadow.json"
    result = {"issue": "donpark/idfon#161", "authoritative": args.fp32,
              "sessions": args.sessions, "frames": args.frames, "tol": args.tol,
              "max_ms": args.max_ms, "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
              "contention": runners.contention(), "rows": rows}
    runners.dump_json(out, result)
    out.with_suffix(".md").write_text(markdown(result))
    blocked = [r for r in rows if r["verdict"] == "block"]
    print(f"\n{len(rows)} cells shadowed, {len(blocked)} block a swap-over -> "
          f"{out} + {out.with_suffix('.md').name}")
    raise SystemExit(1 if blocked else 0)


def markdown(res):
    L = ["# TurnShadow — candidate tiers against the authoritative path", "",
         f"{res['authoritative']}  |  {res['sessions']} recorded sessions x {res['frames']} "
         f"frames, ±{res['tol']} frames  |  generated {res['generated']}", "",
         "| adapter | tier | agree | missing | spurious | p_end max|Δ| | yield max|Δ| | "
         "cand ms/f | ref ms/f | verdict |",
         "| --- | --- | ---: | --- | --- | ---: | ---: | ---: | ---: | --- |"]
    for r in res["rows"]:
        if r.get("status"):
            L.append(f"| {r['adapter']} | {r['tier']}-{r['variant']} | — | — | — | — | — | — | — | "
                     f"{r['verdict']} ({r.get('detail', '')}) |")
            continue
        fk = r["flips_by_kind"]
        miss = ", ".join(f"{k} {v}" for k, v in sorted(fk["missing"].items())) or "0"
        spur = ", ".join(f"{k} {v}" for k, v in sorted(fk["spurious"].items())) or "0"
        L.append(f"| {r['adapter']} | {r['tier']}-{r['variant']} | {r['agree']:.2%} | {miss} | "
                 f"{spur} | {r['axis_delta']['max']['p_end']:.2e} | "
                 f"{r['axis_delta']['max']['yield']:.2e} | {r['ms_frame']['cand']:.3f} | "
                 f"{r['ms_frame']['ref']:.3f} | {r['verdict']} |")
    L += ["", "Verdicts: `ok` = no ENDPOINT/BARGE flip, per-head drift ≤ 2e-3, p95 step ≤ "
          f"{res['max_ms']} ms. `block` = a swap-over needs a product decision (see the issue). "
          "Backchannel flips are reported, not averaged away.", ""]
    for r in [r for r in res["rows"] if r.get("flips")]:
        L.append(f"### {r['adapter']} {r['tier']}-{r['variant']} flips")
        L.append("")
        for f in r["flips"][:40]:
            L.append(f"- {f['side']:8s} {f['kind']:12s} frame {f['frame']:5d}  "
                     f"({f['session'][:16]}…)")
        if len(r["flips"]) > 40:
            L.append(f"- … {len(r['flips']) - 40} more in shadow.json")
        L.append("")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    main()
