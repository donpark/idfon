"""Side-by-side transcripts, word-level divergence and partial cadence for
`asr-bundle-swap` runs.

There are no reference transcripts for the live captures (`corpus/` carries
transcripts but no audio; the call captures carry audio but no transcripts), so
this reports **divergence**, never WER, and never calls a difference "worse".

Word diff = `difflib.SequenceMatcher` over normalised word tokens
(lowercase, punctuation stripped), so `Hello,` / `Hello` is not a substitution.
The opcodes give substituted / inserted / deleted counts.

Usage:
  python3 tools/asr-bundle-swap/diff.py bench-results/asr-bundle-swap/transcripts.json \
      [more.json ...] [--ref en] [--markdown]

  --selfcheck   the diff and cadence arithmetic on synthetic runs, no files
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from difflib import SequenceMatcher

WORD = re.compile(r"[a-z0-9']+")


def words(text: str) -> list[str]:
    return WORD.findall(text.lower().replace("’", "'"))


def diff_counts(ref: list[str], hyp: list[str]) -> tuple[int, int, int]:
    subs = ins = dels = 0
    for tag, i1, i2, j1, j2 in SequenceMatcher(None, ref, hyp, autojunk=False).get_opcodes():
        if tag == "replace":
            subs += min(i2 - i1, j2 - j1)
            dels += max(0, (i2 - i1) - (j2 - j1))
            ins += max(0, (j2 - j1) - (i2 - i1))
        elif tag == "delete":
            dels += i2 - i1
        elif tag == "insert":
            ins += j2 - j1
    return subs, ins, dels


def examples(ref: list[str], hyp: list[str], limit: int = 4) -> list[str]:
    out = []
    for tag, i1, i2, j1, j2 in SequenceMatcher(None, ref, hyp, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        out.append(f"{tag}: {' '.join(ref[i1:i2]) or '∅'} → {' '.join(hyp[j1:j2]) or '∅'}")
        if len(out) >= limit:
            break
    return out


def pct(xs: list[float], p: float) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    rank = p / 100.0 * (len(s) - 1)
    lo = int(rank)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (rank - lo)


def cadence(run: dict) -> dict:
    ps = run.get("partials", [])
    gaps = [b["audio_s"] - a["audio_s"] for a, b in zip(ps, ps[1:])]
    added, rewrites, changes = [], 0, 0
    prev = ""
    for p in ps:
        t = p["text"]
        if t != prev:
            changes += 1
        if t.startswith(prev):
            added.append(len(t) - len(prev))
        else:
            rewrites += 1
        prev = t
    audio_s = run["audio_s"]
    return {
        "partials": len(ps),
        "text_changes": changes,
        "per_s": round(len(ps) / audio_s, 3) if audio_s else 0,
        "gap_p50": round(pct(gaps, 50), 2),
        "gap_p95": round(pct(gaps, 95), 2),
        "gap_max": round(max(gaps), 2) if gaps else 0.0,
        "added_p50": int(pct([float(a) for a in added], 50)) if added else 0,
        "rewrites": rewrites,
        "first_partial_s": round(ps[0]["audio_s"], 2) if ps else None,
        "last_partial_s": round(ps[-1]["audio_s"], 2) if ps else None,
        "tail_lag_s": round(audio_s - ps[-1]["audio_s"], 2) if ps else None,
        "final_added_chars": len(run["final"]) - len(ps[-1]["text"]) if ps else len(run["final"]),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--ref", default="en", help="bundle whose transcript is the reference")
    ap.add_argument("--markdown", action="store_true", help="emit the doc tables only")
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args()

    if args.selfcheck:
        selfcheck()
        return

    runs: list[dict] = []
    for f in args.files:
        runs += json.load(open(f))["runs"]
    by_session: dict[str, dict[str, dict]] = defaultdict(dict)
    for r in runs:
        by_session[r["session"]][r["bundle"]] = r

    bundles = sorted({r["bundle"] for r in runs},
                     key=lambda b: (b != args.ref, b))
    sessions = list(by_session)

    rows = []
    for s in sessions:
        ref = by_session[s].get(args.ref)
        ref_w = words(ref["final"]) if ref else []
        for b in bundles:
            r = by_session[s].get(b)
            if not r:
                continue
            w = words(r["final"])
            c = cadence(r)
            subs, ins, dels = diff_counts(ref_w, w) if (ref and b != args.ref) else (0, 0, 0)
            rows.append({
                "session": s, "bundle": b, "audio_s": r["audio_s"],
                "words": len(w), "subs": subs, "ins": ins, "dels": dels,
                **c,
                "final": r["final"], "examples": examples(ref_w, w) if (ref and b != args.ref) else [],
                "prompt_id": r.get("prompt_id"), "language_hint": r.get("language_hint"),
                "detected": r.get("detected_language"),
            })

    if args.markdown:
        print_markdown(rows, bundles, args.ref)
        return

    # No references: say so once, plainly.
    print("references: none for these captures (corpus/ has transcripts but no audio) "
          "— reporting divergence from `%s`, not WER\n" % args.ref)

    for b in bundles:
        rs = [r for r in rows if r["bundle"] == b]
        if not rs:
            continue
        prompt = rs[0]["prompt_id"]
        print(f"== {b}  prompt {prompt if prompt is not None else '-'}"
              f"  hint {rs[0]['language_hint'] or '-'}  detected {rs[0]['detected'] or '-'}")
        for r in rs:
            print(f"  {r['session']}  {r['audio_s']:.0f} s  {r['words']} words  "
                  f"sub/ins/del {r['subs']}/{r['ins']}/{r['dels']}  "
                  f"partials {r['partials']} ({r['text_changes']} text changes, {r['per_s']}/s, gap p50 {r['gap_p50']} s, "
                  f"p95 {r['gap_p95']} s, max {r['gap_max']} s)  "
                  f"added/update p50 {r['added_p50']}ch  rewrites {r['rewrites']}  "
                  f"first {r['first_partial_s']}s  final+{r['final_added_chars']}ch")
        print()

    print("== pairwise (same session, same audio)")
    for s in sessions:
        pairs = [(a, b) for i, a in enumerate(bundles) for b in bundles[i + 1:]
                 if a in by_session[s] and b in by_session[s]]
        for a, b in pairs:
            subs, ins, dels = diff_counts(words(by_session[s][a]["final"]),
                                          words(by_session[s][b]["final"]))
            print(f"  {s}  {a} → {b}: sub/ins/del {subs}/{ins}/{dels}")
    print()

    print("== transcripts side by side")
    for s in sessions:
        print(f"\n-- {s}")
        for b in bundles:
            r = by_session[s].get(b)
            if r:
                print(f"  [{b}] {r['final']}")
    print("\n== divergence examples (reference = %s)" % args.ref)
    for r in rows:
        if r["examples"]:
            print(f"\n-- {r['session']} [{r['bundle']}]  "
                  f"sub/ins/del {r['subs']}/{r['ins']}/{r['dels']}")
            for e in r["examples"]:
                print(f"   {e}")


def print_markdown(rows: list[dict], bundles: list[str], ref: str) -> None:
    print("| call | bundle | prompt | words | sub/ins/del vs %s | partials | gap p50 | gap p95 "
          "| text changes | added/update | rewrites | first partial | final jump |" % ref)
    print("|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
    for r in rows:
        print(f"| {r['session']} | {r['bundle']} | {r['prompt_id'] if r['prompt_id'] is not None else '-'} "
              f"| {r['words']} | {r['subs']}/{r['ins']}/{r['dels']} | {r['partials']} "
              f"| {r['gap_p50']} s | {r['gap_p95']} s | {r['text_changes']} | {r['added_p50']} ch | {r['rewrites']} "
              f"| {r['first_partial_s']} s | +{r['final_added_chars']} ch |")


def selfcheck() -> None:
    assert words("Hello, world! It's 3 o'clock.") == ["hello", "world", "it's", "3", "o'clock"]
    assert diff_counts("a b c".split(), "a b c".split()) == (0, 0, 0)
    assert diff_counts("a b c".split(), "a x c".split()) == (1, 0, 0)
    assert diff_counts("a b c".split(), "a c".split()) == (0, 0, 1)
    assert diff_counts("a c".split(), "a b c".split()) == (0, 1, 0)
    assert diff_counts("a b".split(), "a x y".split()) == (1, 1, 0)
    run = {"audio_s": 10.0, "final": "one two three",
           "partials": [{"audio_s": 1.0, "text": "one"},
                        {"audio_s": 3.0, "text": "one two"},
                        {"audio_s": 5.0, "text": "1 2"}]}
    c = cadence(run)
    assert c["partials"] == 3 and c["gap_p50"] == 2.0 and c["rewrites"] == 1
    assert c["text_changes"] == 3
    assert c["first_partial_s"] == 1.0 and c["tail_lag_s"] == 5.0
    assert c["final_added_chars"] == len("one two three") - 3
    assert pct([1, 2, 3, 4], 50) == 2.5
    print("selfcheck: tokenisation, diff counts, cadence OK")


if __name__ == "__main__":
    main()
