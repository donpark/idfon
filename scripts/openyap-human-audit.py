#!/usr/bin/env python3
"""Build a stratified human-audit sample from openyap-tyger-labels.py output.

Collapses thresholded Tyger proposals into episodes, samples strata (BARGE,
BACKCHANNEL, ENDPOINT, and near-miss contrast windows the teacher did NOT
propose), cuts short stereo clips (ch0 = user track, ch1 = agent track) from the
source tar, and writes a review sheet with blank human verdict columns. Audio
stays outside the checkout.

Example:
  python3 scripts/openyap-human-audit.py /path/open-yap-1k-sample.tar \
    --labels /tmp/openyap-labels-v0.2 --out /tmp/openyap-audit --per-kind 8

Then listen to each clip and fill review.csv: human_verdict (yes/no/unsure).
"""

import argparse
import csv
import json
import random
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]

HTML_TEMPLATE = r'''<!doctype html>
<meta charset="utf-8">
<title>Tyger pseudo-label human audit</title>
<style>
  :root { color-scheme: light dark; --bg:#101216; --card:#1a1e25; --fg:#e8eaed; --muted:#9aa3af;
          --line:#2a3038; --yes:#2e7d4f; --no:#b4483c; --unsure:#9a7b2f; --accent:#5b8def; }
  @media (prefers-color-scheme: light) { :root { --bg:#f6f7f9; --card:#fff; --fg:#1c2026; --muted:#6b7280;
          --line:#e3e6ea; --yes:#2e7d4f; --no:#c0453a; --unsure:#b08a2e; --accent:#3562c4; } }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:14px/1.45 ui-sans-serif,system-ui,sans-serif; }
  header { position:sticky; top:0; z-index:2; background:var(--bg); padding:16px 20px 12px;
           border-bottom:1px solid var(--line); display:flex; gap:16px; align-items:baseline; flex-wrap:wrap; }
  #filters { display:flex; gap:8px; flex-wrap:wrap; padding:12px 20px 0; max-width:1100px; margin:0 auto; }
  #filters button.on { border-color:var(--accent); color:var(--accent); box-shadow:0 0 0 1px var(--accent); }
  h1 { font-size:16px; margin:0; }
  .progress { color:var(--muted); }
  .bar { flex:1 1 160px; height:6px; background:var(--line); border-radius:3px; overflow:hidden; min-width:120px; }
  .bar i { display:block; height:100%; width:0; background:var(--accent); transition:width .25s ease; }
  button { font:inherit; cursor:pointer; border:1px solid var(--line); background:var(--card); color:var(--fg);
           border-radius:8px; padding:6px 12px; transition:transform .08s ease, background .15s ease, border-color .15s ease; }
  button:hover { border-color:var(--accent); }
  button:active { transform:scale(.97); }
  .copy { background:var(--accent); border-color:var(--accent); color:#fff; }
  main { padding:16px 20px 48px; display:grid; gap:12px; max-width:1100px; margin:0 auto; }
  .row { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:12px 16px;
         display:grid; grid-template-columns:minmax(220px,1fr) auto; gap:10px 16px; align-items:center;
         animation:in .25s ease backwards; }
  .row.sel { border-color:var(--accent); box-shadow:0 0 0 1px var(--accent); }
  .row.done .qid { opacity:.55; }
  @keyframes in { from { opacity:0; transform:translateY(6px); } }
  .qid { display:flex; gap:10px; align-items:baseline; flex-wrap:wrap; }
  .id { font-family:ui-monospace,monospace; color:var(--muted); font-size:12px; }
  .badge { font-size:11px; letter-spacing:.04em; padding:2px 8px; border-radius:99px; border:1px solid var(--line); }
  .badge.BARGE { color:#e0806e; border-color:#e0806e55; }
  .badge.BACKCHANNEL { color:#6ec9b0; border-color:#6ec9b055; }
  .badge.ENDPOINT { color:#8fa8f0; border-color:#8fa8f055; }
  .badge.BARGE_NEAR_MISS { color:#d3b45e; border-color:#d3b45e55; }
  .q { flex-basis:100%; }
  .meta { color:var(--muted); font-size:12px; }
  .controls { display:flex; gap:8px; align-items:center; flex-wrap:wrap; justify-content:flex-end; }
  .v { padding:6px 14px; }
  .v.yes.on { background:var(--yes); border-color:var(--yes); color:#fff; }
  .v.no.on { background:var(--no); border-color:var(--no); color:#fff; }
  .v.unsure.on { background:var(--unsure); border-color:var(--unsure); color:#fff; }
  .notes { grid-column:1/-1; width:100%; font:inherit; color:var(--fg); background:var(--bg);
           border:1px solid var(--line); border-radius:8px; padding:6px 10px; }
  .keys { color:var(--muted); font-size:12px; margin-left:auto; }
  audio { height:32px; }
</style>
<header>
  <h1>Tyger pseudo-label human audit</h1>
  <span class="progress" id="progress"></span>
  <div class="bar"><i id="barfill"></i></div>
  <button class="copy" id="copy">Copy filled CSV</button>
  <button id="reset">Reset</button>
  <span class="keys">1/2/3 = yes/no/unsure · space = replay · ↑↓ = move</span>
</header>
<nav id="filters"></nav>
<main id="list"></main>
<script>
  const items = __ITEMS__;
  const KEY = 'tyger-audit-v1';
  const store = JSON.parse(localStorage.getItem(KEY) || '{}');
  const save = () => localStorage.setItem(KEY, JSON.stringify(store));
  const list = document.getElementById('list');
  let sel = 0;
  const rows = items.map((it, i) => {
    const el = document.createElement('div');
    el.className = 'row';
    el.style.animationDelay = Math.min(i * 25, 400) + 'ms';
    el.innerHTML = `
      <div class="qid">
        <span class="id">${it.sample_id}</span>
        <span class="badge ${it.kind}">${it.kind.replaceAll('_', ' ')}</span>
        <span class="meta">${it.conversation_id} @ ${it.ts_s}s · score ${it.teacher_score} · mark at 0:02 in clip</span>
        <div class="q">${it.question}</div>
      </div>
      <div class="controls">
        <audio controls preload="none" src="clips/${it.clip}"></audio>
        <button class="v yes" data-v="yes">yes</button>
        <button class="v no" data-v="no">no</button>
        <button class="v unsure" data-v="unsure">unsure</button>
      </div>
      <input class="notes" placeholder="notes (optional)">`;
    const [yes, no, unsure] = el.querySelectorAll('.v');
    const notes = el.querySelector('.notes');
    const paint = () => {
      for (const b of [yes, no, unsure]) b.classList.toggle('on', store[it.sample_id]?.v === b.dataset.v);
      notes.value = store[it.sample_id]?.n || '';
      el.classList.toggle('done', !!store[it.sample_id]?.v);
    };
    for (const b of [yes, no, unsure]) b.addEventListener('click', () => {
      store[it.sample_id] = { ...(store[it.sample_id] || {}), v: b.dataset.v };
      save(); paint(); header();
    });
    notes.addEventListener('input', () => {
      store[it.sample_id] = { ...(store[it.sample_id] || {}), n: notes.value };
      save(); header();
    });
    el.addEventListener('click', () => { sel = i; mark(); });
    paint();
    list.appendChild(el);
    return el;
  });
  function mark() { rows.forEach((r, i) => r.classList.toggle('sel', i === sel)); }
  let active = 'all';
  const visIdx = () => items.map((_, i) => i).filter(i => active === 'all' || items[i].kind === active);
  const fbtns = [];
  for (const k of ['all', 'BARGE', 'BACKCHANNEL', 'ENDPOINT', 'BARGE_NEAR_MISS']) {
    const n = k === 'all' ? items.length : items.filter(it => it.kind === k).length;
    const b = document.createElement('button');
    b.textContent = (k === 'all' ? 'All' : k.replaceAll('_', ' ')) + ' · ' + n;
    b.addEventListener('click', () => {
      active = k;
      fbtns.forEach((f, j) => f.classList.toggle('on', fbtns[j] === b));
      rows.forEach((r, i) => r.style.display = (active === 'all' || items[i].kind === active) ? '' : 'none');
      const v = visIdx(); if (v.length && !v.includes(sel)) { sel = v[0]; mark(); }
    });
    fbtns.push(b);
    document.getElementById('filters').appendChild(b);
  }
  fbtns[0].classList.add('on');
  function header() {
    const done = items.filter(it => store[it.sample_id]?.v).length;
    document.getElementById('progress').textContent = `${done} / ${items.length} reviewed`;
    document.getElementById('barfill').style.width = (100 * done / items.length) + '%';
  }
  document.getElementById('copy').addEventListener('click', async () => {
    const head = 'sample_id,conversation_id,ts_s,kind,teacher_score,teacher_margin,raw_proposals,clip,question,human_verdict,human_notes';
    const esc = s => /[",\n]/.test(s) ? '"' + s.replaceAll('"', '""') + '"' : s;
    const lines = items.map(it => {
      const s = store[it.sample_id] || {};
      return [it.sample_id, it.conversation_id, it.ts_s, it.kind, it.teacher_score, it.teacher_margin,
              it.raw_proposals, it.clip, it.question, s.v || '', s.n || ''].map(esc).join(',');
    });
    await navigator.clipboard.writeText([head, ...lines].join('\n'));
    document.getElementById('copy').textContent = 'Copied — paste to the agent';
    setTimeout(() => document.getElementById('copy').textContent = 'Copy filled CSV', 1800);
  });
  document.getElementById('reset').addEventListener('click', () => {
    if (confirm('Clear all verdicts?')) { for (const k of Object.keys(store)) delete store[k]; save();
      rows.forEach(r => r.querySelector('.notes').value = ''); location.reload(); }
  });
  document.addEventListener('keydown', e => {
    const it = items[sel], row = rows[sel];
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'AUDIO') return;
    if (e.key === '1' || e.key === '2' || e.key === '3') {
      const v = { 1: 'yes', 2: 'no', 3: 'unsure' }[e.key];
      store[it.sample_id] = { ...(store[it.sample_id] || {}), v }; save();
      row.querySelector(`.v.${v}`).click();
    } else if (e.key === ' ') {
      e.preventDefault();
      const a = row.querySelector('audio');
      a.paused ? a.play() : a.pause();
    } else if (e.key === 'ArrowDown') {
      const v = visIdx(), at = v.indexOf(sel);
      if (at < v.length - 1) { sel = v[at + 1]; mark(); rows[sel].scrollIntoView({ block: 'center', behavior: 'smooth' }); }
    } else if (e.key === 'ArrowUp') {
      const v = visIdx(), at = v.indexOf(sel);
      if (at > 0) { sel = v[at - 1]; mark(); rows[sel].scrollIntoView({ block: 'center', behavior: 'smooth' }); }
    }
  });
  mark(); header();
</script>
'''

QUESTIONS = {
    "BARGE": "Did the user cut in over the agent and take or contest the floor near the mark?",
    "BACKCHANNEL": "Did the agent give any brief response while the user kept the floor — mumbles, quiet vocalizations, and short words count, not just mm-hm/yeah? Count late, clipped, or rushed responses as yes and note the defect (late/clipped/rushed) in notes.",
    "ENDPOINT": "Had the user's turn actually ended at the mark (agent answering there would be correct)?",
    "BARGE_NEAR_MISS": "Was there a real user cut-in in this window that was NOT proposed? (miss probe)",
}

# One episode per contiguous run of frames in a given mode.
def speaking_episodes(records):
    runs, start = [], None
    for i, r in enumerate(records):
        speaking = r["state"]["mode"] == "speaking"
        if speaking and start is None:
            start = i
        elif not speaking and start is not None:
            runs.append((start, i - 1))
            start = None
    if start is not None:
        runs.append((start, len(records) - 1))
    return runs


def collapse(records, kind, gap_frames, episode_of):
    """Group consecutive same-kind proposals whose frames are within gap_frames."""
    hits = []
    for i, r in enumerate(records):
        for e in r.get("teacher_proposal", {}).get("events", []):
            if e["kind"] == kind:
                hits.append((i, e))
    out = []
    for i, e in hits:
        if out and episode_of(i) == episode_of(out[-1][0]) and i - out[-1][0] <= gap_frames:
            out[-1][2] += 1  # raw proposal count
            out[-1][3] = max(out[-1][3], e["value"])
            continue
        out.append([i, e, 1, e["value"]])
    return out


def load_conversations(labels_dir):
    convs = {}
    for path in sorted(Path(labels_dir).glob("*.jsonl")):
        key = re.sub(r"-[0-9a-f]{12}-tyger$|-tyger$", "", path.stem)
        convs[key] = [json.loads(line) for line in path.open() if line.strip()]
    return convs


def episode_index_factory(records):
    ep_of = {}
    for n, (a, b) in enumerate(speaking_episodes(records)):
        for i in range(a, b + 1):
            ep_of[i] = n
    return ep_of.get, speaking_episodes(records)


def sample_rows(convs, per_kind, seed):
    rows, rng = [], random.Random(seed)
    for key, records in sorted(convs.items()):
        ep_get, runs = episode_index_factory(records)
        # BARGE: one row per speaking episode that produced a proposal.
        barge = collapse(records, "BARGE", 15, lambda i: ep_get(i))
        # Near-miss contrast: speaking episodes with a strong score but no proposal.
        proposed_eps = {ep_get(i) for i, _, _, _ in barge}
        near_miss = []
        for n, (a, b) in enumerate(runs):
            if n in proposed_eps:
                continue
            best = max((r["answers"]["barge_in"]["noul"] for r in records[a:b + 1]), default=0)
            if best >= 0.35:
                near_miss.append([a + (b - a) // 2, {"kind": "BARGE_NEAR_MISS", "value": best}, 1, best])
        bc = collapse(records, "BACKCHANNEL", 15, lambda i: i // 20)
        ep = collapse(records, "ENDPOINT", 15, lambda i: i // 20)
        for kind, items in (("BARGE", barge), ("BACKCHANNEL", bc), ("ENDPOINT", ep),
                            ("BARGE_NEAR_MISS", near_miss)):
            bucket = [it for it in items]
            if kind in ("BARGE", "BARGE_NEAR_MISS"):  # spread over score margin
                bucket.sort(key=lambda it: it[3])
            take = len(bucket) if kind == "ENDPOINT" else min(per_kind, len(bucket))
            if take == 0:
                continue
            step = max(1, len(bucket) // take)
            picked = bucket[::step][:take] if kind in ("BARGE", "BARGE_NEAR_MISS") \
                else rng.sample(bucket, take)
            for i, e, raw, best in picked:
                rows.append({
                    "conversation_id": key,
                    "frame": records[i].get("frame", i),
                    "ts_s": round(records[i]["ts"], 2),
                    "kind": kind,
                    "teacher_score": round(best, 3),
                    "teacher_margin": round(e.get("margin", 0), 3),
                    "raw_proposals": raw,
                })
    rows.sort(key=lambda r: (r["conversation_id"], r["ts_s"]))
    for n, row in enumerate(rows, 1):
        row["sample_id"] = f"S{n:03d}"
    return rows


def extract_flacs(archive, key, user_track, tmp):
    agent_track = "b" if user_track == "a" else "a"
    out = {}
    with tarfile.open(archive, mode="r:") as tf:
        for role, track in (("user", user_track), ("agent", agent_track)):
            member = tf.getmember(f"{key}.{track}.flac")
            dest = tmp / f"{key}.{role}.flac"
            src = tf.extractfile(member)
            with src, dest.open("wb") as f:
                shutil.copyfileobj(src, f, 1 << 20)
            out[role] = dest
    return out


def cut_clip(user_flac, agent_flac, ts_s, wav, pre_s=2.0, post_s=4.0):
    start = max(0.0, ts_s - pre_s)
    graph = ("[0:a]aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono[u];"
             "[1:a]aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono[a];"
             "[u][a]amerge=inputs=2[out]")
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-i", str(user_flac), "-i", str(agent_flac),
         "-filter_complex", graph, "-map", "[out]", "-ss", str(start), "-t", str(pre_s + post_s),
         "-ac", "2", "-c:a", "pcm_s16le", str(wav)],
        check=True)


def write_html(rows, out_dir, clip_paths):
    items = [{**{k: row[k] for k in ("sample_id", "conversation_id", "ts_s", "kind",
                                     "teacher_score", "teacher_margin")},
              "clip": clip_paths[row["sample_id"]].name,
              "question": QUESTIONS[row["kind"]]}
             for row in rows]
    page = HTML_TEMPLATE.replace("__ITEMS__", json.dumps(items))
    path = out_dir / "review.html"
    path.write_text(page)
    return path


def write_sheet(rows, out_dir, clip_paths):
    csv_path = out_dir / "review.csv"
    fields = ["sample_id", "conversation_id", "ts_s", "kind", "teacher_score", "teacher_margin",
              "raw_proposals", "clip", "question", "human_verdict", "human_notes"]
    with csv_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for row in rows:
            w.writerow({**{k: row[k] for k in fields if k in row},
                        "clip": clip_paths[row["sample_id"]].name,
                        "question": QUESTIONS[row["kind"]],
                        "human_verdict": "", "human_notes": ""})
    md = ["# Human audit sample — Tyger pseudo-labels", "",
          "Each clip is 6 s stereo: left = user track, right = agent track. Fill "
          "`human_verdict` in review.csv (yes/no/unsure). These are **proposals to "
          "check**, not ground truth.", ""]
    for row in rows:
        md.append(f"- **{row['sample_id']}** [{row['kind']}] {row['conversation_id']} "
                  f"@ {row['ts_s']}s (score {row['teacher_score']}) — {QUESTIONS[row['kind']]}")
        md.append(f"  - `{clip_paths[row['sample_id']].name}`")
    (out_dir / "review.md").write_text("\n".join(md) + "\n")
    return csv_path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("tar", nargs="?", help="local Open Yap public-sample WebDataset tar")
    ap.add_argument("--labels", help="directory of *-tyger.jsonl label files")
    ap.add_argument("--out", help="output directory; must be outside the repo")
    ap.add_argument("--user-track", choices=("a", "b"), default="a")
    ap.add_argument("--per-kind", type=int, default=8)
    ap.add_argument("--seed", type=int, default=125)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        records = [{"ts": i * 0.08, "state": {"mode": "speaking" if 10 <= i < 40 else "listen"},
                    "answers": {"barge_in": {"noul": 0.6 if i == 20 else 0.0}},
                    "teacher_proposal": {"events": [{"kind": "BARGE", "value": 0.6, "margin": 0.1}]
                                         if i in (20, 21, 22) else []}} for i in range(50)]
        ep_get, runs = episode_index_factory(records)
        assert runs == [(10, 39)], runs
        barge = collapse(records, "BARGE", 15, ep_get)
        assert len(barge) == 1 and barge[0][2] == 3, barge  # 3 raw proposals -> 1 episode
        assert ep_get(20) == ep_get(22) != ep_get(9)
        print("openyap-human-audit self-test: OK")
        return

    if not all((args.tar, args.labels, args.out)):
        ap.error("tar, --labels, and --out are required")
    archive, out_dir = Path(args.tar).resolve(), Path(args.out).resolve()
    if out_dir == ROOT or ROOT in out_dir.parents:
        ap.error("output must be outside the repository; audio is local-only")
    if not shutil.which("ffmpeg"):
        ap.error("ffmpeg is required")

    convs = load_conversations(args.labels)
    if not convs:
        ap.error(f"no *-tyger.jsonl under {args.labels}")
    rows = sample_rows(convs, args.per_kind, args.seed)
    out_dir.mkdir(parents=True, exist_ok=True)
    clip_dir = out_dir / "clips"
    clip_dir.mkdir(exist_ok=True)

    clip_paths = {}
    by_conv = {}
    for row in rows:
        by_conv.setdefault(row["conversation_id"], []).append(row)
    with tempfile.TemporaryDirectory(prefix="openyap-audit-") as td:
        tmp = Path(td)
        for key, items in sorted(by_conv.items()):
            flacs = extract_flacs(archive, key, args.user_track, tmp)
            for row in items:
                wav = clip_dir / f"{row['sample_id']}-{row['kind']}-{row['conversation_id']}-{row['ts_s']}s.wav"
                cut_clip(flacs["user"], flacs["agent"], row["ts_s"], wav)
                clip_paths[row["sample_id"]] = wav
                print(f"{row['sample_id']} {row['kind']:>16} {row['conversation_id']} @{row['ts_s']}s")
    csv_path = write_sheet(rows, out_dir, clip_paths)
    html_path = write_html(rows, out_dir, clip_paths)
    print(f"\n{len(rows)} review items -> {csv_path} (clips in {clip_dir})")
    print(f"review UI -> {html_path} (open in Chrome; clips play from ./clips)")


if __name__ == "__main__":
    main()
