#!/usr/bin/env python3
"""Autoresearch toward a measured audio target (the improvement pipeline's
driver; docs/voice-calibration.md).

Measure the target's style metrics, then search the knob space toward them:
each generation proposes candidate texts mechanically (frame x core
mutations of the survivors, plus a little exploration), probes them through
the mouth's model via the reaction bench, keeps the best, and writes a round
report — the lesson draft that becomes a registry entry after the human ear
gate.

    scripts/voice-autoresearch.py                          # 4 generations
    scripts/voice-autoresearch.py --target-dir refs/ -g 6  # toward a collection
    scripts/voice-autoresearch.py --selftest               # no model, no ptts

Proposals are mechanical on purpose. An LLM reads the reports and drafts
registry lessons; it does not invent knobs inside the loop.
"""
import argparse
import hashlib
import json
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.join(HERE, "voice-reaction-bench.py")
WORK = os.path.expanduser("~/.cache/idfon/voice-autoresearch")

# The reaction grammar: a hesitation core inside spoken frames.
CORES = ["um", "uhm", "umm", "ehm", "hmm", "hm", "mhm", "mm-hm",
         "oh", "ah", "well", "so", "yeah", "right", "okay", "let me see"]
FRAMES = ["{c}, one moment.", "{c}, let me check.", "So, {c}, one moment.",
          "Well, {c}, one moment.", "Oh, {c}, one moment.", "{c}. One moment.",
          "Let me see. {c}, one moment.", "{c}, checking the time in Tokyo."]


def slug(text):
    return "t" + hashlib.sha256(text.encode()).hexdigest()[:8]


def propose(population, seen, budget):
    """Mechanical mutations of the survivors plus a little exploration. The
    living population is always part of the seen set. Population entries are
    bench rows (dicts with at least `text`)."""
    seen.update(item["text"] for item in population)
    out = []
    longest_first = sorted(CORES, key=len, reverse=True)

    def core_of(text):
        low = text.lower()
        return next((c for c in longest_first if low.startswith(c) or f" {c}" in low), None)

    for item in population:
        text = item["text"]
        core = core_of(text)
        for frame in FRAMES:
            out.append(frame.format(c=core or "um"))
        for c in CORES:
            if c != core and core:
                out.append(text.replace(core, c))
    for frame in FRAMES:  # exploration over the whole grammar
        for c in CORES:
            out.append(frame.format(c=c))
    fresh = []
    for t in out:
        t = t.strip()
        if t and t not in seen:
            seen.add(t)
            fresh.append(t)
        if len(fresh) >= budget:
            break
    return fresh


def probe(texts, args, workdir):
    """Render + measure + score through the reaction bench; returns {text: row}."""
    cand = os.path.join(workdir, "candidates.txt")
    with open(cand, "w") as f:
        for t in texts:
            f.write(f"{slug(t)}|{t}\n")
    out_json = os.path.join(workdir, "probe.json")
    cmd = [sys.executable, BENCH, "--candidates", cand, "--ptts", args.ptts,
           "--out", os.path.join(workdir, "wavs"), "--json-out", out_json, "--quiet"]
    if args.utmos:
        cmd.append("--utmos")
    if args.target:
        cmd += ["--target", args.target]
    elif args.target_dir:
        cmd += ["--target-dir", args.target_dir]
    subprocess.run(cmd, check=True, capture_output=True, text=True)
    rows = json.load(open(out_json))["rows"]
    return {r["text"]: r for r in rows}, json.load(open(out_json))["target"]


def selftest():
    seen = set()
    pop = [{"text": "Um, one moment."}, {"text": "hmm, let me check."}]
    fresh = propose(pop, seen, 24)
    assert fresh and len(fresh) == len(set(fresh)), "proposals are unique"
    assert all(t not in {p["text"] for p in pop} for t in fresh), "proposals are new"
    fake = {t: {"text": t, "score": float(i)} for i, t in enumerate(fresh)}
    top = sorted(fake.values(), key=lambda r: r["score"])[:4]
    assert [r["score"] for r in top] == [0.0, 1.0, 2.0, 3.0], "selection keeps the best"
    print("selftest OK")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target")
    ap.add_argument("--target-dir")
    ap.add_argument("--seeds", help="file of slug|text starting points")
    ap.add_argument("-g", "--generations", type=int, default=4)
    ap.add_argument("--population", type=int, default=8)
    ap.add_argument("--ptts", default="ptts")
    ap.add_argument("--utmos", action="store_true", help="add the UTMOS quality floor")
    ap.add_argument("--workdir", default=WORK)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return

    os.makedirs(args.workdir, exist_ok=True)
    seeds = ["Um, one moment.", "hmm, let me check.", "So, um, one moment.",
             "Well, one moment.", "Mhm.", "Let me see. One moment."]
    if args.seeds:
        seeds = [l.split("|", 1)[1].strip() for l in open(args.seeds) if "|" in l]
    seen = set(seeds)
    population = [{"text": s, "score": 0.0} for s in seeds]
    history, best_ever, target = [], None, None

    for gen in range(1, args.generations + 1):
        fresh = propose(population, seen, args.population * 3)
        if not fresh:
            break
        scored, target = probe([r["text"] for r in population] + fresh, args, args.workdir)
        population = sorted(scored.values(), key=lambda r: r["score"])[:args.population]
        best = population[0]
        improved = best_ever is None or best["score"] < best_ever["score"]
        best_ever = best if improved else best_ever
        history.append({"gen": gen, "probed": len(scored),
                        "best": best["text"], "best_score": best["score"],
                        "median": round(statistics.median(r["score"] for r in scored.values()), 3)})
        print(f"gen {gen}: probed {len(scored):3}  best {best['score']:.3f}  «{best['text']}»")

    rows = sorted(population, key=lambda r: r["score"])
    report = os.path.join(args.workdir, "report.md")
    with open(report, "w") as f:
        f.write("# Autoresearch round report\n\n")
        f.write(f"Target: `{json.dumps(target)}`\n\n")
        f.write("## Trajectory\n\n| gen | probed | best | score | median |\n|---|---|---|---|---|\n")
        for h in history:
            f.write(f"| {h['gen']} | {h['probed']} | {h['best']} | {h['best_score']} | {h['median']} |\n")
        f.write("\n## Final population\n\n| score | text | swell | head | crest | pitch |\n|---|---|---|---|---|---|\n")
        for r in rows:
            f.write(f"| {r['score']} | {r['text']} | {r.get('swell_ms')} | {r.get('head_rms')} "
                    f"| {r.get('crest_db')} | {r.get('pitch_hz')} |\n")
        f.write("\n## Lesson draft (for the registry, after the ear gate)\n\n")
        f.write(f"- Winner: **{best_ever['text']}** (score {best_ever['score']}).\n")
        f.write("- Full trajectory and metric table above; turn observations into "
                "`docs/voice-calibration.md` entries by hand (or with an LLM reader).\n")
    print(f"\nbest: {best_ever['text']}  (score {best_ever['score']})")
    print(f"report: {report}")


if __name__ == "__main__":
    main()
