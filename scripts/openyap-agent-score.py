"""Score a turn-range audit against the voice agent's actions, not the label set.

The four label kinds are gap strata. The agent has two situations and four
explicit actions:

  agent SILENT  (handoff / silent_tail)  -> WAIT or START SPEAKING
  agent SPEAKING (overlap / backchannel) -> CONTINUE SPEAKING or STOP SPEAKING

The human question on the review page was "is the caller still talking?".
  yes = caller still talking -> WAIT (agent silent) / STOP SPEAKING (agent speaking)
  no  = caller gave up        -> START SPEAKING (agent silent) / CONTINUE (agent speaking)

"Hold" is ambiguous (it means "keep the floor" to a product person and "wait"
to a caller-side reviewer), so this script uses the explicit action names only.

Columns measured after the decision instant are weak labelers, not runtime
inputs. A rule using them cannot be the online rule.

    python3 scripts/openyap-agent-score.py "manifest.csv"
"""
from __future__ import annotations

import csv
import sys

# kind -> (agent situation, action when the caller is still talking, action when the caller yielded)
ACTION = {
    "handoff": ("silent", "wait", "start speaking"),
    "silent_tail": ("silent", "wait", "start speaking"),
    "overlap": ("speaking", "stop speaking", "continue speaking"),
    "backchannel": ("speaking", "stop speaking", "continue speaking"),
}
KINDS = ("handoff", "silent_tail", "overlap", "backchannel")

# Columns measured AFTER the decision instant. A rule using these is a weak
# labeler, not an online decision rule — the agent cannot see the next turn's
# length or the end of the caller's turn when it decides.
RETROSPECTIVE = ("next_ms", "gap_ms", "turn_end", "lead_next", "audio_next_dom")

# Action-specific error cost: (false_wait, false_start). "False wait" = the
# agent waited when the caller had yielded (dead air). "False start" = the agent
# spoke while the caller was still talking (interruption). The review says there
# is no single global asymmetry: for a silent agent a false start is the costly
# one; for a speaking agent a false wait (talking over the caller) is costly.
COST = {
    "handoff": (1, 4),
    "silent_tail": (1, 3),
    "overlap": (4, 1),
    "backchannel": (2, 2),
}


def _f(r: dict, k: str) -> float:
    try:
        return float(r[k])
    except (KeyError, TypeError, ValueError):
        return 0.0


def _acts(r: dict, kind: str) -> bool:
    """True = 'caller still talking' (wait / stop speaking). next_ms long means the
    next speaker took the floor, i.e. the caller YIELDED, so it predicts False."""
    return _f(r, "next_ms") <= 1300 or (kind == "backchannel" and _f(r, "gap_ms") > -780)


def _cost(sub: list[dict], t: float, k: str) -> tuple[int, int, int]:
    """Return (cost, false_wait, false_start) for threshold t on kind k."""
    fw = fs = 0
    for r in sub:
        still_talking = _f(r, "next_ms") <= t or (k == "backchannel" and _f(r, "gap_ms") > -780)
        truth = r["human_verdict"] == "yes"  # caller still talking -> wait/stop
        if still_talking == truth:
            continue
        if still_talking:
            fw += 1  # predicted wait, caller actually yielded -> dead air
        else:
            fs += 1  # predicted start, caller actually still talking -> interruption
    cw, cs = COST[k]
    return fw * cw + fs * cs, fw, fs


def _best_threshold(sub: list[dict], k: str) -> tuple[int, float, int, int]:
    best = None
    for t in range(200, 3001, 40):
        c, fw, fs = _cost(sub, t, k)
        if best is None or c < best[0]:
            best = (c, t, fw, fs)
    return best


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else "manifest.csv"
    rows = [r for r in csv.DictReader(open(path)) if r.get("human_verdict", "").strip()]
    if not rows:
        print("no human_verdict rows")
        return

    yes = sum(1 for r in rows if r["human_verdict"] == "yes")
    print(f"votes: {len(rows)}  ({yes} caller-still-talking / {len(rows) - yes} caller-yielded)\n")

    print(f"{'kind':12} {'situation':10} {'n':>3} {'wait':>5} {'start':>5} {'start%':>6}")
    for k in KINDS:
        sub = [r for r in rows if r["kind"] == k]
        if not sub:
            continue
        wait = sum(1 for r in sub if r["human_verdict"] == "yes")
        start = len(sub) - wait
        sit = ACTION[k][0]
        print(f"{k:12} {sit:10} {len(sub):3d} {wait:5d} {start:5d} "
              f"{100 * start / len(sub):5.0f}%")

    print("\n--- next_ms split (act = the next turn is long) ---")
    best = (0.0, None)
    for t in range(300, 2501, 100):
        acc = sum(1 for r in rows
                  if (float(r["next_ms"]) > t) == (r["human_verdict"] == "no"))
        if acc > best[0]:
            best = (acc, t)
        if t % 300 == 0:
            print(f"  next_ms > {t:4d} ms : {acc:2d}/{len(rows)} = {acc / len(rows):.0%}")
    acc, t = best
    print(f"\nbest split: next_ms > {t} ms -> {acc}/{len(rows)} = {acc / len(rows):.0%} "
          "agree with the human's wait/start")

    print("\n--- label as an action trigger ---")
    print("  the label kind names the caller's turn; the agent's action depends on")
    print("  whether the agent is silent or speaking, which the label does not carry")
    for k in KINDS:
        sub = [r for r in rows if r["kind"] == k]
        if not sub:
            continue
        sit, when_talking, when_yielded = ACTION[k]
        agree = sum(1 for r in sub if r["human_verdict"] == "yes")
        print(f"  {k:12} ({sit:8}) label-as-'{when_talking}': human says yes "
              f"{agree}/{len(sub)} = {agree / len(sub):.0%}")

    print("\n--- per-kind cost-sensitive threshold ---")
    print(f"  {'kind':12} {'thr':>6} {'acc':>6} {'false_wait':>10} {'false_start':>11} {'cost':>6}")
    for k in KINDS:
        sub = [r for r in rows if r["kind"] == k]
        if not sub:
            continue
        c, t, fw, fs = _best_threshold(sub, k)
        ok = len(sub) - fw - fs
        print(f"  {k:12} {t:6.0f} {ok / len(sub):6.2f} {fw:10d} {fs:11d} {c:6d}")

    print("\n  causal columns at the decision instant:")
    print("   ", ", ".join(c for c in rows[0] if c not in RETROSPECTIVE))
    print("  RETROSPECTIVE (do not use as an online rule):")
    print("   ", ", ".join(RETROSPECTIVE))

    # The "hmm in a void" case: silent_tail rows with a long gap before the next
    # speaker. Those are the "invite more" moments, not turn ends.
    voids = [r for r in rows if r["kind"] == "silent_tail" and float(r["gap_ms"]) > 600]
    if voids:
        emit = sum(1 for r in voids if r["human_verdict"] == "yes")
        print(f"\n  silent_tail gap>600 (void -> hmm): human says wait "
              f"{emit}/{len(voids)} = {emit / len(voids):.0%}")

    # When the manifest carries the auto-label columns, measure how the rule did.
    auto = [r for r in rows if r.get("auto_verdict", "").strip()]
    if auto:
        print("\n--- auto-label vs human (this band) ---")
        hit = sum(1 for r in auto if r["auto_verdict"] == r["human_verdict"])
        print(f"  agreement {hit}/{len(auto)} = {hit / len(auto):.0%}")
        for k in KINDS:
            sub = [r for r in auto if r["kind"] == k]
            if not sub:
                continue
            ok = sum(1 for r in sub if r["auto_verdict"] == r["human_verdict"])
            print(f"  {k:12} {ok}/{len(sub)} = {ok / len(sub):.0%}")
        miss = [r for r in auto if r["auto_verdict"] != r["human_verdict"]]
        if miss:
            print("  misses:")
            for r in miss:
                print(f"    {r['kind']:12} gap={float(r['gap_ms']):>8.0f} next={float(r['next_ms']):>7.0f} "
                      f"auto={r['auto_verdict']:3} human={r['human_verdict']}")


if __name__ == "__main__":
    main()
