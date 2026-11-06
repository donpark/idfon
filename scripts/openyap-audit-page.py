"""A local listening page for a barge audit bundle (manifest.csv + clips).

The judgement is semantic, so the page keeps it blind: the yield threshold and the
channel meters stay hidden until a verdict is cast. Verdicts persist in
localStorage and export as CSV in the manifest's column order.

    .venv/bin/python scripts/openyap-audit-page.py bench-results/openyap-audit-2026-11-06
    open bench-results/openyap-audit-2026-11-06/index.html
"""
from __future__ import annotations

import csv
import html
import json
import os
import sys


def main() -> None:
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    path = os.path.join(d, "manifest.csv")
    rows = list(csv.DictReader(open(path)))
    for r in rows:
        r["human_verdict"] = ""
        r["human_notes"] = ""
    clips = json.dumps(rows)
    title = "Barge audit — " + os.path.basename(os.path.abspath(d))

    page = f"""<!doctype html>
<meta charset="utf-8">
<title>{html.escape(title)}</title>
<style>
  :root {{ color-scheme: dark; --bg:#0e1116; --card:#171c24; --line:#2a3341; --ink:#e6edf3;
           --dim:#8b98a9; --yes:#3fb950; --no:#f85149; --accent:#58a6ff; }}
  * {{ box-sizing: border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--ink);
         font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }}
  header {{ position:sticky; top:0; z-index:2; background:rgba(14,17,22,.94);
            backdrop-filter:blur(8px); border-bottom:1px solid var(--line); padding:14px 22px; }}
  h1 {{ font-size:16px; margin:0 0 4px; font-weight:600; letter-spacing:.2px; }}
  .q {{ color:var(--ink); }}
  .sub {{ color:var(--dim); font-size:13px; }}
  .bar {{ display:flex; gap:14px; align-items:center; margin-top:10px; flex-wrap:wrap; }}
  .pill {{ border:1px solid var(--line); border-radius:999px; padding:2px 10px; font-size:12px; color:var(--dim); }}
  button {{ font:inherit; border-radius:8px; border:1px solid var(--line); background:var(--card);
            color:var(--ink); padding:7px 13px; cursor:pointer; }}
  button:hover {{ border-color:#3d4a5c; }}
  button.primary {{ background:var(--accent); border-color:var(--accent); color:#0b1017; font-weight:600; }}
  main {{ margin:0 auto; padding:18px 22px 130px; display:grid; gap:10px; max-width:1100px; }}
  .item {{ scroll-margin-bottom:90px; background:var(--card); border:1px solid var(--line); border-radius:12px; padding:12px 14px;
           display:grid; grid-template-columns:64px 1fr auto; gap:14px; align-items:center; }}
  .item.done {{ border-color:#2b4d33; }}
  .id {{ color:var(--dim); font:12px ui-monospace,SFMono-Regular,Menlo,monospace; }}
  .meta {{ color:var(--dim); font-size:12px; margin-top:2px; }}
  audio {{ width:100%; height:34px; }}
  .votes {{ display:flex; gap:6px; }}
  .votes button {{ min-width:44px; }}
  .votes .on-yes {{ background:var(--yes); border-color:var(--yes); color:#06120a; }}
  .votes .on-no {{ background:var(--no); border-color:var(--no); color:#180606; }}
  .notes {{ grid-column:2 / span 2; }}
  .notes input {{ width:100%; background:#0f141b; border:1px solid var(--line); color:var(--ink);
                  border-radius:8px; padding:6px 9px; font:13px inherit; }}
  .reveal {{ color:var(--dim); font-size:12px; }}
  mark {{ background:#243041; color:var(--ink); border-radius:4px; padding:0 4px; }}
  footer {{ position:fixed; bottom:0; left:0; right:0; background:rgba(14,17,22,.96);
            border-top:1px solid var(--line); padding:10px 22px; display:flex; gap:14px; align-items:center; }}
</style>
<header>
  <h1>{html.escape(title)}</h1>
  <div class="q">At the mark (2.0 s), <b>was the caller taking the floor</b> — cutting in or starting a new
  turn — or was this just a pause, a noise, or a backchannel?</div>
  <div class="sub">6 s stereo clip, caller left / agent right. Thresholds are hidden until you vote.
  Keys: <b>Y</b> yes, <b>N</b> no, <b>space</b> play/pause, <b>J</b>/<b>K</b> next/previous.</div>
  <div class="bar">
    <span class="pill" id="progress">0 / 0</span>
    <span class="pill" id="counts">yes 0 · no 0</span>
    <button id="export">Export CSV</button>
    <button id="reset">Reset votes</button>
  </div>
</header>
<main id="items"></main>
<footer><span class="sub" id="hint">Verdicts save automatically in this browser.</span></footer>
<script>
const ROWS = {clips};
const KEY = "barge-audit:" + document.title;
let votes = JSON.parse(localStorage.getItem(KEY) || "{{}}");
const save = () => localStorage.setItem(KEY, JSON.stringify(votes));

const fmt = (t) => (t >= 0 ? "+" : "") + t.toFixed(2) + " s from the mark";

function item(r, i) {{
  const v = votes[r.sample_id] || {{}};
  const el = document.createElement("div");
  el.className = "item" + (v.verdict ? " done" : "");
  el.dataset.sample = r.sample_id;
  el.innerHTML = `
    <div><div class="id">${{r.sample_id}}</div><div class="meta">${{i + 1}}/${{ROWS.length}}</div></div>
    <div>
      <div style="display:flex; gap:8px; align-items:center">
        <button class="play" title="play / pause (space)">▶</button>
        <audio controls preload="metadata" style="flex:1"
               src="${{encodeURIComponent(r.clip)}}"></audio>
      </div>
      <div class="meta">${{r.kind.toLowerCase()}} · ${{Math.round(r.ts_s)}} s into the call
        <span class="reveal" data-reveal>· threshold ${{r.threshold}}</span></div>
    </div>
    <div class="votes">
      <button data-v="yes" class="${{v.verdict === 'yes' ? 'on-yes' : ''}}" title="caller took the floor">Yes</button>
      <button data-v="no" class="${{v.verdict === 'no' ? 'on-no' : ''}}" title="pause / noise / backchannel">No</button>
    </div>
    <div class="notes"><input placeholder="note (optional)" value="${{v.notes ? v.notes.replace(/"/g, '&quot;') : ''}}"></div>`;
  const audio = el.querySelector("audio");
  const play = el.querySelector(".play");
  play.onclick = () => {{ audio.paused ? audio.play().catch(() => {{}}) : audio.pause(); }};
  audio.onplay = () => {{ play.textContent = "❚❚"; }};
  audio.onpause = () => {{ play.textContent = "▶"; }};
  audio.onerror = () => {{
    play.textContent = "!";
    el.querySelector("[data-reveal]").textContent = "· audio failed to load: " + decodeURIComponent(audio.getAttribute("src"));
    el.querySelector("[data-reveal]").style.visibility = "visible";
  }};
  el.querySelectorAll("button[data-v]").forEach((b) => b.onclick = () => cast(r.sample_id, b.dataset.v, el));
  el.querySelector("input").oninput = (e) => {{
    votes[r.sample_id] = Object.assign(votes[r.sample_id] || {{}}, {{ notes: e.target.value }});
    save();
  }};
  return el;
}}

function cast(id, verdict, el) {{
  const row = ROWS.find((r) => r.sample_id === id);
  votes[id] = Object.assign(votes[id] || {{}}, {{ verdict }});
  save();
  el.querySelectorAll("button[data-v]").forEach((b) => {{
    b.classList.toggle(b.dataset.v === "yes" ? "on-yes" : "on-no", b.dataset.v === verdict);
  }});
  el.classList.add("done");
  el.querySelector("[data-reveal]").style.visibility = "visible";
  refresh();
  // advance to the next unvoted clip
  const next = ROWS.find((r, i) => !votes[r.sample_id]?.verdict && i > ROWS.indexOf(row));
  if (next) {{
    const n = document.querySelector(`[data-sample="${{next.sample_id}}"]`);
    n.scrollIntoView({{ block: "center", behavior: "smooth" }});
    n.querySelector("audio").play().catch(() => {{}});
  }}
}}

function refresh() {{
  const done = ROWS.filter((r) => votes[r.sample_id]?.verdict);
  const yes = done.filter((r) => votes[r.sample_id].verdict === "yes").length;
  document.getElementById("progress").textContent = `${{done.length}} / ${{ROWS.length}}`;
  document.getElementById("counts").textContent = `yes ${{yes}} · no ${{done.length - yes}}`;
}}

document.getElementById("export").onclick = () => {{
  const cols = ["sample_id", "conversation_id", "ts_s", "kind", "threshold", "clip", "human_verdict", "human_notes"];
  const rows = ROWS.map((r) => cols.map((c) => {{
    if (c === "human_verdict") return votes[r.sample_id]?.verdict || "";
    if (c === "human_notes") return (votes[r.sample_id]?.notes || "").replace(/"/g, '""');
    return r[c];
  }}).map((x) => /[",\\n]/.test(String(x)) ? `"${{x}}"` : x).join(","));
  const blob = new Blob([[cols.join(","), ...rows].join("\\n")], {{ type: "text/csv" }});
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "manifest.csv";
  a.click();
}};

document.getElementById("reset").onclick = () => {{
  if (!confirm("Clear every verdict in this browser?")) return;
  votes = {{}}; save(); location.reload();
}};

const main = document.getElementById("items");
ROWS.forEach((r, i) => main.appendChild(item(r, i)));
// reveal thresholds only for rows already voted
ROWS.forEach((r) => {{
  const el = document.querySelector(`[data-sample="${{r.sample_id}}"] [data-reveal]`);
  if (el) el.style.visibility = votes[r.sample_id]?.verdict ? "visible" : "hidden";
}});
refresh();

let idx = -1;
document.addEventListener("keydown", (e) => {{
  if (e.target.tagName === "INPUT") return;
  const items = [...document.querySelectorAll(".item")];
  if (e.key === "j" || e.key === "J") {{ idx = Math.min(items.length - 1, idx + 1); items[idx].scrollIntoView({{ block: "center" }}); }}
  if (e.key === "k" || e.key === "K") {{ idx = Math.max(0, idx - 1); items[idx].scrollIntoView({{ block: "center" }}); }}
  const cur = idx >= 0 ? items[idx] : null;
  if (!cur) return;
  if (e.key === " ") {{ e.preventDefault(); const a = cur.querySelector("audio");
    a.paused ? a.play() : a.pause(); }}
  if (e.key === "y" || e.key === "Y") cast(cur.dataset.sample, "yes", cur);
  if (e.key === "n" || e.key === "N") cast(cur.dataset.sample, "no", cur);
}});
</script>"""
    out = os.path.join(d, "index.html")
    open(out, "w").write(page)
    print(f"{len(rows)} clips -> {out}")


if __name__ == "__main__":
    main()
