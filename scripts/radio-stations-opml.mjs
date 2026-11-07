#!/usr/bin/env node
// Curate or search a menu contact's OPML from real online talk-radio stations.
//
//   node scripts/radio-stations-opml.mjs --out shows.opml
//   node scripts/radio-stations-opml.mjs --tag "talk,news" --limit 8 --group country
//   node scripts/radio-stations-opml.mjs --query "bbc radio" --json
//   node scripts/radio-stations-opml.mjs --country Germany --tag news --append shows.opml
//   node scripts/radio-stations-opml.mjs --json --tag talk --limit 3 --order random
//
// Discovers candidates on Radio Browser, keeps only the ones that actually
// serve audio *right now* (the "live at any given time" filter: a station that
// answers with a stream, not a dead URL or a web page), and writes the nested
// OPML the apps render (docs/live-radio.md "Menu contact"). Piping the output
// into `shows.opml` beside a radio agent's `live.json` (`opml: "shows.opml"`)
// is the whole setup: the holder serves it at /menu.opml and clicking a
// station in the app starts its real-time audio.
//
// `--query`/`--country` search the directory at any time; `--json` prints the
// matches for an agent tool and `--append` adds them to an existing menu under
// a "Found" section (deduped by stream URL).
//
// Radio Browser is a discovery/health hint only — the directory is never the
// relay (epic #118, #120). `--no-check` skips the liveness probe (offline use).
//
// shortcut: no schedule awareness — "live now" means the stream answers, not
// that a live show is on; refine against programme data when #120 lands.

import { readFileSync, writeFileSync } from "node:fs";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const flag = (name) => args.includes(`--${name}`);

const LIMIT = Number(opt("limit", "12"));
const QUERY = opt("query", "");
const COUNTRY = opt("country", "");
// `--tag` wins; an unfiltered search must not silently become "talk".
const TAGS = args.includes("--tag") ? opt("tag", "") : QUERY || COUNTRY ? "" : "talk";
const ORDER = opt("order", "clickcount"); // clickcount | random
const GROUP = opt("group", "country"); // country | none
const OUT = opt("out", "");
const APPEND = opt("append", "");
const JSON_OUT = flag("json");
const CHECK = !flag("no-check");
const USER_AGENT = "idfon-radio-stations/1 (menu contact curation)";

const escapeXml = (text) =>
  text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

/** A station answers with audio-ish bytes right now (not a dead URL or page). */
async function isLive(url) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 6000);
  try {
    const response = await fetch(url, {
      headers: { "User-Agent": USER_AGENT },
      signal: controller.signal,
    });
    const type = (response.headers.get("content-type") || "").toLowerCase();
    if (!response.ok || type.includes("text/html")) return false;
    // Read a little real payload to prove bytes flow, then let go.
    const reader = response.body?.getReader?.();
    if (!reader) return type.startsWith("audio/") || type.includes("mpegurl");
    const { value } = await reader.read();
    await reader.cancel();
    return (value?.length ?? 0) > 0;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

async function discover() {
  const params = new URLSearchParams({
    hidebroken: "true",
    order: ORDER,
    limit: String(LIMIT * 4),
  });
  if (ORDER !== "random") params.set("reverse", "true");
  if (QUERY) params.set("name", QUERY);
  if (COUNTRY) params.set("country", COUNTRY);
  if (TAGS) params.set("tag", TAGS);
  const response = await fetch(
    `https://de1.api.radio-browser.info/json/stations/search?${params}`,
    { headers: { "User-Agent": USER_AGENT } },
  );
  if (!response.ok) throw new Error(`radio-browser: HTTP ${response.status}`);
  const stations = await response.json();
  // Dedupe on the resolved stream URL; prefer higher-bitrate mirrors.
  const seen = new Map();
  for (const station of stations) {
    const stream = (station.url_resolved || station.url || "").trim();
    if (!/^https?:\/\//.test(stream)) continue;
    if (!station.name?.trim()) continue;
    const entry = {
      name: station.name.trim(),
      stream,
      country: (station.country || "").trim() || "Other",
      bitrate: station.bitrate || 0,
    };
    const prior = seen.get(stream);
    if (!prior || entry.bitrate > prior.bitrate) seen.set(stream, entry);
  }
  return [...seen.values()];
}

const outline = (entry) =>
  `    <outline text="${escapeXml(entry.name)}" type="audio" url="${escapeXml(entry.stream)}" />`;

function toOpml(stations) {
  let body;
  if (GROUP === "none") {
    body = stations.map(outline).join("\n");
  } else {
    const groups = new Map();
    for (const station of stations) {
      const key = station.country;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(station);
    }
    body = [...groups.entries()]
      .map(([country, entries]) =>
        `  <outline text="${escapeXml(country)}">\n${entries.map(outline).join("\n")}\n  </outline>`)
      .join("\n");
  }
  return `<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head>
    <title>Talk radio stations</title>
    <dateCreated>${new Date().toUTCString()}</dateCreated>
  </head>
  <body>
${body}
  </body>
</opml>
`;
}

/** Add matches to an existing menu, skipping stream URLs it already carries. */
function appendToMenu(file, stations) {
  const existing = readFileSync(file, "utf8");
  const fresh = stations.filter((station) => !existing.includes(`url="${escapeXml(station.stream)}"`));
  if (!fresh.length) {
    console.error(`radio-stations-opml: all ${stations.length} already in ${file}`);
    return;
  }
  if (!existing.includes("</body>")) throw new Error(`${file} has no </body>`);
  const block = `  <outline text="Found">\n${fresh.map(outline).join("\n")}\n  </outline>\n`;
  writeFileSync(file, existing.replace("</body>", `${block}</body>`));
  console.error(`radio-stations-opml: ${fresh.length} stations → ${file}`);
}

const candidates = await discover();
// Probe in parallel: a dead station can take the full 6 s timeout, and a
// sequential pass over every candidate would stall a chat turn.
const checked = CHECK
  ? await Promise.all(
      candidates.map(async (station) => ((await isLive(station.stream)) ? station : null)),
    )
  : candidates;
const live = checked.filter(Boolean).slice(0, LIMIT);
if (live.length === 0) {
  console.error("radio-stations-opml: no live stations found; try --no-check or a wider search");
  process.exit(1);
}
if (APPEND) appendToMenu(APPEND, live);
if (JSON_OUT) {
  process.stdout.write(`${JSON.stringify(live, null, 2)}\n`);
} else if (OUT) {
  writeFileSync(OUT, toOpml(live));
  console.error(`radio-stations-opml: ${live.length} live stations → ${OUT}`);
} else {
  process.stdout.write(toOpml(live));
}
