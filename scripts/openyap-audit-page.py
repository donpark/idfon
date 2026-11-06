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
import math
import os
import sys
import wave

import numpy as np

MARK_S = 2.0
VAD = 0.00316   # -50 dBFS, the rules' voiced threshold


def level_db(path: str, mark_s: float) -> tuple[float, float]:
    """RMS in dBFS of the caller and agent at the mark (one 80 ms frame)."""
    with wave.open(path) as w:
        sr = w.getframerate()
        raw = w.readframes(w.getnframes())
    a = np.frombuffer(raw, np.int16).reshape(-1, 2).astype(np.float32) / 32768.0
    i = int(mark_s * sr)
    hop = int(0.08 * sr)
    out = []
    for ch in (0, 1):
        rms = float(np.sqrt(np.mean(a[i:i + hop, ch] ** 2)))
        out.append(20 * math.log10(rms) if rms > 1e-9 else -120.0)
    return out[0], out[1]


def main() -> None:
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    path = os.path.join(d, "manifest.csv")
    rows = list(csv.DictReader(open(path)))
    for r in rows:
        r["human_verdict"] = ""
        r["human_notes"] = ""
        r.setdefault("mark_s", "2.0")
        clip = os.path.join(d, r["clip"])
        caller, agent = (level_db(clip, float(r["mark_s"]))
                         if os.path.exists(clip) else (-120.0, -120.0))
        r["caller_db"] = round(caller)
        r["agent_db"] = round(agent)
    clips = json.dumps(rows)
    # An endpoint bundle carries `class_` (on/off the corpus eot label); a barge
    # bundle does not. The rubric question changes with the event, so pick by column.
    endpoint = bool(rows) and "class_" in rows[0]
    title = ("Endpoint audit — " if endpoint else "Barge audit — ") + os.path.basename(os.path.abspath(d))
    if endpoint:
        rubric_html = """
  <section class="rubric">
    <div class="col yes">
      <h2>Say <b>Yes</b> — the caller has finished; the agent may take the floor</h2>
      <ul>
        <li>the caller's utterance is complete: a question answered, a statement closed</li>
        <li>a natural pause where a reply would land correctly</li>
        <li>trailing off or a filled pause that still reads as "done" ("...so, yeah")</li>
      </ul>
    </div>
    <div class="col no">
      <h2>Say <b>No</b> — the caller is not finished</h2>
      <ul>
        <li>the caller is mid-utterance: a word cut off, a breath before continuing</li>
        <li>a list or story still in progress; the next clause is clearly coming</li>
        <li>the mark lands in a pause *inside* the turn, not at its end</li>
      </ul>
    </div>
    <div class="tie">
      <b>Tiebreak:</b> if the agent speaking right now would be <b>correct</b>, say Yes.
      If it would talk over a caller who is about to continue, say No.
      Judge around the mark (\u00b10.5 s), not what comes later.
      Left channel = the speaker whose turn it is; right = the other party.
    </div>
  </section>"""
    else:
        rubric_html = """
  <section class="rubric">
    <div class="col yes">
      <h2>Say <b>Yes</b> — the caller is claiming the floor at the mark</h2>
      <ul>
        <li><b>the caller is mid-utterance with content</b>, whether they started at the mark or before it</li>
        <li>starting a new turn: a question, an answer, a statement, a \u201cwait\u2014\u201d</li>
        <li>cutting in while the agent is still talking</li>
        <li>a short but turn-shaped utterance: \u201cwhat?\u201d, \u201chang on\u201d, \u201cno no no\u201d</li>
      </ul>
    </div>
    <div class="col no">
      <h2>Say <b>No</b> — not a claim on the floor</h2>
      <ul>
        <li>filler or acknowledgement: \u201cmm-hm\u201d, \u201cyeah\u201d, \u201cright\u201d, laughter</li>
        <li>noise: cough, breath, chair, click, mic bump, the agent\u2019s own audio</li>
        <li>a word cut off and restarted, a stutter, or the caller clearly stopped (silence)</li>
      </ul>
    </div>
    <div class="tie">
      <b>Tiebreak:</b> if answering the caller right now would be <b>correct</b>, say Yes.
      If staying silent would be <b>correct</b>, say No.
      \u201cAlready talking\u201d is <b>not</b> a reason for No: if the mark lands inside the caller\u2019s turn and
      they are saying something, say Yes. Judge around the mark (\u00b10.5 s), not what comes later.
      Left channel = caller, right = agent; after you vote, the levels at the mark are shown.
    </div>
  </section>"""

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
  .rubric {{ display:grid; grid-template-columns:1fr 1fr; gap:10px 22px; background:var(--card);
             border:1px solid var(--line); border-radius:12px; padding:14px 16px; }}
  .rubric h2 {{ font-size:13px; margin:0 0 6px; font-weight:600; letter-spacing:.2px; }}
  .rubric ul {{ margin:0; padding-left:18px; color:var(--dim); font-size:13px; }}
  .rubric li {{ margin:3px 0; }}
  .rubric .yes h2 {{ color:var(--yes); }}
  .rubric .no h2 {{ color:var(--no); }}
  .rubric .tie {{ grid-column:1 / span 2; color:var(--dim); font-size:13px;
                  border-top:1px solid var(--line); padding-top:9px; }}
  @media (max-width: 720px) {{ .rubric {{ grid-template-columns:1fr; }} .rubric .tie {{ grid-column:1; }} }}
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
  .said {{ color:var(--ink); font-size:13px; margin-top:4px; opacity:.85; }}
  mark {{ background:#243041; color:var(--ink); border-radius:4px; padding:0 4px; }}
  footer {{ position:fixed; bottom:0; left:0; right:0; background:rgba(14,17,22,.96);
            border-top:1px solid var(--line); padding:10px 22px; display:flex; gap:14px; align-items:center; }}
</style>
<header>
  <h1>{html.escape(title)}</h1>
  <div class="q">At the mark, <b>was the caller taking the floor</b> — cutting in or starting a new
  turn — or was this just a pause, a noise, or a backchannel? Each clip starts just before the
  agent’s last words and the mark is where the barge fired (shown per row).</div>
  <div class="sub">6 s stereo clip, caller left / agent right; the agent stops shortly after the clip starts.
  Keys: <b>Y</b> yes, <b>N</b> no, <b>space</b> play/pause, <b>J</b>/<b>K</b> next/previous.</div>
  <div class="bar">
    <span class="pill" id="progress">0 / 0</span>
    <span class="pill" id="counts">yes 0 · no 0</span>
    <button id="export">Export CSV</button>
    <button id="reset">Reset votes</button>
  </div>
</header>
<main>
  {rubric_html}
  <div id="items" style="display:grid; gap:10px"></div>
</main>
<footer><span class="sub" id="hint">Verdicts save automatically in this browser.</span></footer>
<script>
const ROWS = {clips};
const KEY = "barge-audit:" + document.title;
let votes = JSON.parse(localStorage.getItem(KEY) || "{{}}");
const save = () => localStorage.setItem(KEY, JSON.stringify(votes));

const detail = (r) => {{
  const bits = [];
  if (r.threshold !== undefined && r.threshold !== "") bits.push("yield threshold " + r.threshold);
  if (r.gap_ms !== undefined) bits.push("gap " + r.gap_ms + " ms");
  if (r.p_backchannel !== undefined) bits.push("p(backchannel) " + r.p_backchannel);
  if (r.move !== undefined) bits.push(r.move);
  if (r.yield_peak !== undefined) bits.push("yield peak " + r.yield_peak);
  if (r.caller_run_ms !== undefined) bits.push("caller spoke " + r.caller_run_ms + " ms");
  bits.push("at the mark: caller " + r.caller_db + " dB, agent " +
            (r.agent_db <= -60 ? "silent" : r.agent_db + " dB"));
  return bits.join(" · ");
}};

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
      <div class="meta">mark ${{r.mark_s}} s · ${{r.kind.toLowerCase()}} · ${{Math.round(r.ts_s)}} s into the call
        <span class="reveal" data-reveal>· ${{detail(r)}}</span></div>
      ${{r.text ? `<div class="said">“${{r.text.replace(/</g, "&lt;")}}”</div>` : ""}}
    </div>
    <div class="votes">
      <button data-v="yes" class="${{v.verdict === 'yes' ? 'on-yes' : ''}}" title="caller took the floor">Yes</button>
      <button data-v="no" class="${{v.verdict === 'no' ? 'on-no' : ''}}" title="pause / noise / backchannel">No</button>
    </div>
    <div class="notes"><input placeholder="note (optional)" value="${{v.notes ? v.notes.replace(/"/g, '&quot;') : ''}}"></div>`;
  const audio = el.querySelector("audio");
  const play = el.querySelector(".play");
  play.onclick = () => {{
    if (audio.paused) {{ audio.currentTime = 0; audio.play().catch(() => {{}}); }} else audio.pause();
  }};
  // start every playback from the mark-relative beginning, never where it stopped
  audio.onplay = () => {{
    if (audio.currentTime > 0.01) audio.currentTime = 0;
    play.textContent = "❚❚";
  }};
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
  // move to the next unvoted row, never play it: playback stays a deliberate act
  const next = ROWS.find((r, i) => !votes[r.sample_id]?.verdict && i > ROWS.indexOf(row));
  if (next) {{
    document.querySelector(`[data-sample="${{next.sample_id}}"]`)
      .scrollIntoView({{ block: "center", behavior: "smooth" }});
  }}
}}

function refresh() {{
  const done = ROWS.filter((r) => votes[r.sample_id]?.verdict);
  const yes = done.filter((r) => votes[r.sample_id].verdict === "yes").length;
  document.getElementById("progress").textContent = `${{done.length}} / ${{ROWS.length}}`;
  document.getElementById("counts").textContent = `yes ${{yes}} · no ${{done.length - yes}}`;
}}

document.getElementById("export").onclick = () => {{
  // each bundle's own columns: the handoff manifest carries the strata the
  // fires manifest does not (mark_s, gap_ms, caller_run_ms)
  const cols = ROWS.length ? Object.keys(ROWS[0]) : ["sample_id", "human_verdict", "human_notes"];
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

const list = document.getElementById("items");
ROWS.forEach((r, i) => list.appendChild(item(r, i)));
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
    if (a.paused) {{ a.currentTime = 0; a.play().catch(() => {{}}); }} else a.pause(); }}
  if (e.key === "y" || e.key === "Y") cast(cur.dataset.sample, "yes", cur);
  if (e.key === "n" || e.key === "N") cast(cur.dataset.sample, "no", cur);
}});
</script>"""
    out = os.path.join(d, "index.html")
    open(out, "w").write(page)
    print(f"{len(rows)} clips -> {out}")


if __name__ == "__main__":
    main()
