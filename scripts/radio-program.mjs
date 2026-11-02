#!/usr/bin/env node
// Programme a talk-radio contact: submissions in, schedule out.
//
//   radio-program.mjs submit <clip>|--url <episode> --at HH:MM \
//       [--days mon,tue] [--topic T] [--title T] [--note PITCH] \
//       [--submitter NAME] [--intent play|influence] [--instance I]
//
//   radio-program.mjs fallback <clip>|--url <episode> [--instance I]
//   radio-program.mjs brief [--topic T] [--limit N] [--instance I]
//   radio-program.mjs segment --text FILE|--say WORDS [--at HH:MM] \
//       [--topic T] [--days mon,tue] [--instance I]
//   radio-program.mjs find [--topic T[,T]] [--limit N] [--instance I]
//   radio-program.mjs compile [--no-fetch] [--fill] [--instance I]
//   radio-program.mjs config <topic|instance|name>       # for scripts/radio-serve.sh
//   radio-program.mjs page [--name talk-radio] [--url BASE]
//
// The smallest station is one clip: `fallback clip.mp3` makes the audio that
// loops whenever no slot is active. Programming is additive on top of that.
//
// The jockey's non-speaking half lives here too: `brief` gathers sourced facts
// (Wikipedia), `segment` turns words into a programme clip (host TTS), and
// `compile --fill` does both when the station has nothing to play — a synthetic
// submission, labelled as such, through the same path a listener uses.
//
// A submission is a programme pitch, not just a file (docs/live-radio.md):
//   - `play`      the clip airs directly in its preferred slot.
//   - `influence` it has no clip of its own; its topic is the brief, and
//                 `compile` pairs it with a found episode on that topic.
// Either way the note rides the slot: the schedule does not act on it, a radio
// jockey would read it.
//
// `--instance` gives a station its own state (agents/radio/instances/<name>/),
// which is how one agent directory serves many topic stations (roster.json).
// Omitted: the shared agents/radio files, i.e. a single station.
//
// Deterministic by design: `find` is the only search, `compile` is a pure
// merge over the two JSONL files (plus audio fetches). Re-run `compile` as
// often as you like; it rewrites the schedule from the inputs.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFile, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { existsSync, unlinkSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import qrcode from "qrcode-generator";

const ROOT = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const RADIO = path.join(ROOT, "agents", "radio");
const BASE_CONFIG = path.join(RADIO, "live.json");
/// The station-owned half of the config (schedule, fallback, topic).
const BASE_PROGRAMME = path.join(RADIO, "programme.json");
const ROSTER = path.join(RADIO, "roster.json");

const RATE = 24_000; // the live-call profile; stream.rs refuses anything else

const SEED_SCHEDULE = {
  _comment:
    "Derived: `scripts/radio-program.mjs compile` rewrites this from submissions.jsonl + candidates.jsonl. `file` paths are relative to this file. Live edits made here are lost on the next compile.",
  brief: { topics: [], notes: [] },
  slots: [],
};

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    at: { type: "string" },
    days: { type: "string" },
    topic: { type: "string" },
    title: { type: "string" },
    note: { type: "string" },
    submitter: { type: "string", default: "operator" },
    intent: { type: "string" },
    url: { type: "string" },
    limit: { type: "string", default: "8" },
    text: { type: "string" },
    query: { type: "string" },
    say: { type: "string" },
    fill: { type: "boolean", default: false },
    name: { type: "string" },
    url: { type: "string" },
    instance: { type: "string", default: process.env.IDFON_RADIO_INSTANCE ?? "" },
    "no-fetch": { type: "boolean", default: false },
    help: { type: "boolean", short: "h" },
  },
});

const command = positionals[0];

if (values.help || !command) {
  console.log(
    [
      "usage: radio-program.mjs submit <clip>|--url <episode> --at HH:MM [options]",
      "       radio-program.mjs fallback <clip>|--url <episode>",
      "       radio-program.mjs brief [--topic T] [--limit N]",
      "       radio-program.mjs segment --text FILE|--say WORDS [--at HH:MM]",
      "       radio-program.mjs find [--topic T[,T]] [--limit N]",
      "       radio-program.mjs compile [--no-fetch] [--fill]",
      "       radio-program.mjs config <topic|instance|name>",
      "       radio-program.mjs page [--name talk-radio]",
      "",
      "submit options: --days mon,tue  --topic T  --title T  --note PITCH",
      "                --submitter NAME  --intent play|influence",
      "station state:  --instance NAME (or IDFON_RADIO_INSTANCE); omitted = agents/radio",
    ].join("\n")
  );
  process.exit(values.help ? 0 : 1);
}

// A station's state: the shared radio dir, or its own instance dir.
const state = (() => {
  const dir = values.instance ? path.join(RADIO, "instances", values.instance) : RADIO;
  return {
    dir,
    schedule: path.join(dir, "schedule.json"),
    submissions: path.join(dir, "submissions.jsonl"),
    candidates: path.join(dir, "candidates.jsonl"),
    content: path.join(dir, "content"),
  };
})();

try {
  if (command === "submit") await submit();
  else if (command === "fallback") await fallback();
  else if (command === "brief") await brief();
  else if (command === "segment") await segment();
  else if (command === "find") await find();
  else if (command === "compile") await compile();
  else if (command === "config") await config();
  else if (command === "page") await page();
  else throw new Error(`unknown command ${command}`);
} catch (error) {
  console.error(`radio-program: ${error.message}`);
  process.exit(1);
}

// --- submit -----------------------------------------------------------------

async function submit() {
  const clip = positionals[1];
  const url = values.url;
  if (!values.at || !/^\d{1,2}:\d{2}$/.test(values.at))
    throw new Error("submit needs --at HH:MM (the preferred slot)");
  // A pitch with no audio of its own is an influence submission: `compile`
  // pairs it with a found episode on its topic.
  const intent = values.intent ?? (url || clip ? "play" : "influence");
  if (!["play", "influence"].includes(intent))
    throw new Error(`--intent must be play or influence, got ${intent}`);
  if (intent === "play" && !url && !clip) throw new Error("a `play` submission needs a clip path or --url");

  const submission = {
    submitter: values.submitter,
    topic: values.topic ?? null,
    title: values.title ?? null,
    note: values.note ?? null,
    at: values.at,
    days: parseDays(values.days),
    intent,
    clip: null,
    url: url ?? null,
    added_at: new Date().toISOString(),
  };

  if (intent === "play") {
    if (!url && !existsSync(clip)) throw new Error(`no such clip: ${clip}`);
    submission.clip = await ingest(url ?? clip, values.title ?? values.topic ?? "programme");
  }

  await append(state.submissions, submission);
  console.log(
    `submitted ${intent} ${submission.topic ?? "(no topic)"} at ${values.at}` +
      (submission.clip ? ` -> ${submission.clip}` : " (paired at compile time)")
  );
}

// --- fallback (one clip, looped) --------------------------------------------

/// The station's floor: what plays when no slot is active. One clip is a
/// complete station, so this is the first thing to run, before any scheduling.
async function fallback() {
  const clip = positionals[1];
  const url = values.url;
  if (!clip && !url) throw new Error("fallback needs a clip path or --url");
  if (!url && !existsSync(clip)) throw new Error(`no such clip: ${clip}`);
  const target = path.join(state.dir, "fallback.wav");
  await ingest(url ?? clip, "fallback", { target });
  console.log(`fallback -> ${path.relative(ROOT, target)} (loops whenever no slot is active)`);
}

// --- brief (sourced facts for the jockey) -----------------------------------

/// What the station is about: `--topic`, else the roster entry's topic, else
/// the base config's topic.
async function stationTopic() {
  if (values.topic) return values.topic;
  const station = values.instance && resolveStation(await readRoster(), values.instance);
  if (station?.topic) return station.topic;
  const programmePath = values.instance
    ? path.join(RADIO, "instances", values.instance, "programme.json")
    : BASE_PROGRAMME;
  if (!existsSync(programmePath)) return null;
  const base = JSON.parse(await readFile(programmePath, "utf8"));
  return base.topic ?? null;
}

/// Gather the facts a segment will read off. Facts come from a script, never
/// from the model: it may word them, it may not invent them.
async function brief() {
  const topic = await stationTopic();
  if (!topic) throw new Error("brief needs --topic (no station topic configured)");
  // `--query` searches better words than the station name ("tech talk" is a
  // phrase; "technology" is a subject). The record keeps the station topic.
  const items = await facts(values.query ?? topic, Number(values.limit) || 3);
  if (!items.length) throw new Error(`no facts found for "${topic}"`);
  const record = {
    topic,
    generated_at: new Date().toISOString(),
    source: "en.wikipedia.org",
    items,
  };
  const file = path.join(state.dir, "briefs", `${slugify(topic)}-${dateStamp()}.json`);
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, JSON.stringify(record, null, 2) + "\n");
  console.error(`brief -> ${path.relative(ROOT, file)}`);
  console.log(JSON.stringify(record, null, 2));
}

/// Wikipedia search then intro extracts: keyless, topic-agnostic, and every
/// fact keeps the article it came from. One source on purpose (see the doc).
async function facts(topic, limit) {
  const search = new URL("https://en.wikipedia.org/w/api.php");
  search.search = new URLSearchParams({
    action: "query",
    list: "search",
    srsearch: topic,
    srlimit: String(limit),
    format: "json",
  });
  const found = await getJson(search);
  const titles = (found.query?.search ?? []).map((hit) => hit.title);
  if (!titles.length) return [];

  const extracts = new URL("https://en.wikipedia.org/w/api.php");
  extracts.search = new URLSearchParams({
    action: "query",
    prop: "extracts",
    exintro: "1",
    explaintext: "1",
    exchars: "600",
    titles: titles.join("|"),
    format: "json",
  });
  const body = await getJson(extracts);
  const pages = Object.values(body.query?.pages ?? {});
  // Search order, not dictionary order: the first hit is the relevant one.
  return titles
    .map((title) => {
      const page = pages.find((candidate) => candidate.title === title);
      const fact = page?.extract && sentences(page.extract);
      return fact
        ? {
            title,
            fact,
            source: `https://en.wikipedia.org/wiki/${encodeURIComponent(title.replace(/ /g, "_"))}`,
          }
        : null;
    })
    .filter(Boolean);
}

async function getJson(url) {
  const response = await fetch(url, {
    signal: AbortSignal.timeout(20_000),
    headers: { "user-agent": "idfon-radio/1.0 (call-quality soak)" },
  });
  if (!response.ok) throw new Error(`${url.host} answered HTTP ${response.status}`);
  return response.json();
}

/// Two sentences, so a spoken item stays a sentence and not a paragraph.
function sentences(text) {
  const clean = String(text).replace(/\s+/g, " ").trim();
  const cut = clean.match(/^.{0,320}?[.!?](?=\s|$)/g);
  return (cut ? cut.slice(0, 2).join(" ") : clean.slice(0, 320)).trim();
}

// --- segment (words -> a programme clip) ------------------------------------

async function segment() {
  const text = values.text ? await readFile(values.text, "utf8") : values.say;
  if (!text || !text.trim()) throw new Error("segment needs --text FILE or --say WORDS");
  const topic = await stationTopic();
  const at = values.at && /^\d{1,2}:\d{2}$/.test(values.at) ? values.at : "00:00";
  const submission = await syntheticSubmission(text.trim(), topic, at);
  console.log(`segment -> ${submission.clip} (airs at ${at})`);
}

/// A segment enters as a submission, exactly like a listener's: same path, one
/// label different. `synthetic` and the id keep the record honest and make a
/// re-run replace the previous one instead of stacking a second copy.
async function syntheticSubmission(text, topic, at) {
  const clip = await sayToClip(text, `${slugify(topic ?? "station")}-${at.replace(":", "")}`);
  const submission = {
    id: `synthetic:${slugify(topic ?? "station")}:${dateStamp()}:${at}`,
    submitter: "station",
    synthetic: true,
    topic,
    title: `Station brief: ${topic ?? "programme"}`,
    note: text,
    at,
    days: parseDays(values.days),
    // The record says synthetic in the slot itself, not just in this file.
    origin: `synthetic:${slugify(topic ?? "station")}`,
    intent: "play",
    clip,
    url: null,
    added_at: new Date().toISOString(),
  };
  await append(state.submissions, submission);
  return submission;
}

/// Host TTS, then the call profile. `say` on macOS, `espeak-ng` elsewhere;
/// swap for the repo's TTS engines when this must run headless.
async function sayToClip(text, name) {
  const dir = path.join(state.dir, "segments");
  await mkdir(dir, { recursive: true });
  const target = path.join(
    dir,
    `${name}-${createHash("sha256").update(text).digest("hex").slice(0, 8)}.wav`
  );
  if (existsSync(target)) return path.relative(state.dir, target);
  const bin = ["say", "espeak-ng", "espeak"].find(
    (candidate) => spawnSync("which", [candidate]).status === 0
  );
  if (!bin) throw new Error("no TTS on this host: need `say` (macOS) or `espeak-ng`");
  const raw = path.join(os.tmpdir(), `idfon-segment-${process.pid}.${bin === "say" ? "aiff" : "wav"}`);
  try {
    const spoken = spawnSync(bin, bin === "say" ? ["-o", raw, text] : ["-w", raw, text], {
      encoding: "utf8",
    });
    if (spoken.status !== 0) throw new Error(`${bin} failed: ${(spoken.stderr ?? "").trim()}`);
    ffmpeg(raw, target);
  } finally {
    if (existsSync(raw)) unlinkSync(raw);
  }
  return path.relative(state.dir, target);
}

/// A brief, read straight — the mechanical version of a news segment. An agent
/// can write better words; this is what "nothing to play" costs with no model.
function briefText(record) {
  const parts = [`Here is what is happening with ${record.topic} today.`];
  for (const item of record.items.slice(0, 3)) {
    parts.push(`According to Wikipedia's article on ${item.title}, ${item.fact}`);
  }
  return parts.join(" ");
}

async function newestBrief(topic) {
  const dir = path.join(state.dir, "briefs");
  if (!existsSync(dir)) return null;
  const files = (await readdir(dir)).filter(
    (name) => name.startsWith(`${slugify(topic)}-`) && name.endsWith(".json")
  );
  if (!files.length) return null;
  files.sort();
  const file = path.join(dir, files[files.length - 1]);
  return { file, ...JSON.parse(await readFile(file, "utf8")) };
}

// --- find -------------------------------------------------------------------

async function find() {
  const brief = (values.topic ?? "").split(",").map((t) => t.trim()).filter(Boolean);
  const topics = brief.length ? brief : (await influenceTopics());
  if (!topics.length) throw new Error("no topics: pass --topic, or submit an influence pitch first");

  const seen = new Set((await readJsonl(state.candidates)).map((candidate) => candidate.url));
  let added = 0;
  for (const topic of topics) {
    const episodes = await searchEpisodes(topic, Number(values.limit) || 8);
    for (const episode of episodes) {
      if (seen.has(episode.url)) continue;
      seen.add(episode.url);
      await append(state.candidates, { topic, ...episode, added_at: new Date().toISOString() });
      added += 1;
    }
    console.log(`${topic}: ${episodes.length} episode(s)`);
  }
  console.log(`${added} new candidate(s) in ${path.relative(ROOT, state.candidates)}`);
}

/// Apple's podcast directory is the keyless, stable episode search. Shows the
/// result's `episodeUrl`, which is what compile fetches.
async function searchEpisodes(topic, limit) {
  const url =
    "https://itunes.apple.com/search?" +
    new URLSearchParams({
      term: topic,
      media: "podcast",
      entity: "podcastEpisode",
      limit: String(limit),
    });
  const response = await fetch(url, { signal: AbortSignal.timeout(20_000) });
  if (!response.ok) throw new Error(`episode search failed: HTTP ${response.status}`);
  const body = await response.json();
  return (body.results ?? [])
    .filter((result) => typeof result.episodeUrl === "string" && result.episodeUrl.startsWith("http"))
    .map((result) => ({
      title: result.trackName ?? "(untitled)",
      show: result.collectionName ?? null,
      url: result.episodeUrl,
      duration_ms: result.trackTimeMillis ?? null,
      released: result.releaseDate ?? null,
    }));
}

async function influenceTopics() {
  const topics = new Set();
  for (const submission of await readJsonl(state.submissions)) {
    if (submission.intent === "influence" && submission.topic) topics.add(submission.topic);
  }
  return [...topics];
}

// --- compile ----------------------------------------------------------------

async function compile() {
  await fillIfEmpty();
  // Last submission per id wins, so re-running `segment` or a repeat `submit`
  // replaces rather than stacks.
  const unique = new Map();
  for (const submission of await readJsonl(state.submissions)) {
    unique.set(submission.id ?? `added:${submission.added_at}`, submission);
  }
  const submissions = [...unique.values()].sort(
    (a, b) => Number(a.added_at > b.added_at) - Number(a.added_at < b.added_at)
  );
  const candidates = await readJsonl(state.candidates);
  const used = new Set();
  const slots = [];
  const unfilled = [];

  for (const submission of submissions) {
    const days = submission.days ?? null;
    const note = submission.note ?? null;
    if (submission.intent === "play" && submission.clip) {
      slots.push({
        at: submission.at,
        ...(days ? { days } : {}),
        file: submission.clip,
        topic: submission.topic,
        title: submission.title,
        origin: submission.origin ?? "submitted",
        note,
        ...(submission.synthetic ? { synthetic: true } : {}),
      });
      continue;
    }
    // Newest first: a pitch should pair with this week's episode, not the
    // oldest match the search happened to return first.
    const candidate = [...candidates]
      .sort((a, b) => String(b.released ?? "").localeCompare(String(a.released ?? "")))
      .find((candidate) => !used.has(candidate.url) && sameTopic(submission.topic, candidate.topic));
    if (!candidate) {
      unfilled.push(submission.topic ?? `(pitch at ${submission.at})`);
      continue;
    }
    used.add(candidate.url);
    const file = await ingest(candidate.url, candidate.title, {
      noFetch: values["no-fetch"],
    });
    if (!file) {
      unfilled.push(`${submission.topic}: ${candidate.title} (not fetched)`);
      continue;
    }
    slots.push({
      at: submission.at,
      ...(days ? { days } : {}),
      file,
      topic: submission.topic,
      title: candidate.show ? `${candidate.title} — ${candidate.show}` : candidate.title,
      origin: candidate.url,
      note,
    });
  }

  slots.sort((a, b) => a.at.localeCompare(b.at));
  const brief = {
    topics: [
      ...new Set(
        submissions
          .filter((submission) => submission.intent === "influence" && submission.topic)
          .map((submission) => submission.topic)
      ),
    ],
    notes: submissions.map(({ submitter, topic, note }) => ({ submitter, topic, note })).filter((entry) => entry.note),
  };
  await mkdir(state.dir, { recursive: true });
  await writeFile(
    state.schedule,
    JSON.stringify(
      {
        _comment:
          "Derived: `scripts/radio-program.mjs compile` rewrites this from submissions.jsonl + candidates.jsonl. `file` paths are relative to this file. Live edits made here are lost on the next compile.",
        brief,
        slots,
      },
      null,
      2
    ) + "\n"
  );

  console.log(`${slots.length} slot(s) in ${path.relative(ROOT, state.schedule)}`);
  for (const slot of slots) console.log(`  ${slot.at}  ${slot.file}  (${slot.origin})`);
  if (unfilled.length) console.log(`unfilled (run find, then compile):\n  ${unfilled.join("\n  ")}`);
}

/// The pairing rule: an influence pitch matches a candidate when either topic
/// contains the other, case-insensitively (`tech` pairs with `technology news`).
function sameTopic(wanted, candidate) {
  if (!wanted || !candidate) return false;
  const a = wanted.toLowerCase();
  const b = candidate.toLowerCase();
  return a.includes(b) || b.includes(a);
}

// --- config (for scripts/radio-serve.sh) ------------------------------------

/// Materialize one station instance: its state dir, a seeded schedule, and a
/// live config with absolute paths (the holder does not expand `~` or cwd).
/// Prints `instance`, `name`, `config path` — one per line, in that order.
async function config() {
  const key = positionals[1];
  if (!key) throw new Error("config needs a roster topic, instance, or name");
  const stations = await readRoster();
  const station = resolveStation(stations, key);
  if (!station) {
    throw new Error(
      `unknown station "${key}"; add it to ${path.relative(ROOT, ROSTER)}` +
        (stations.length ? ` (have: ${stations.map((s) => s.topic ?? s.instance).join(", ")})` : "")
    );
  }

  const dir = path.join(RADIO, "instances", station.instance);
  const schedule = path.join(dir, "schedule.json");
  await mkdir(path.join(dir, "content"), { recursive: true });
  if (!existsSync(schedule)) {
    await writeFile(schedule, JSON.stringify(SEED_SCHEDULE, null, 2) + "\n");
  }

  const base = JSON.parse(await readFile(BASE_CONFIG, "utf8"));
  const baseProgramme = JSON.parse(await readFile(BASE_PROGRAMME, "utf8"));
  // A station's own fallback wins; otherwise the shared one if it is really there.
  const fallback = [
    path.join(dir, "fallback.wav"),
    baseProgramme.file && path.resolve(ROOT, baseProgramme.file),
  ].find((candidate) => candidate && existsSync(candidate));
  if (!fallback) {
    console.error(
      "no fallback clip: a call with no active slot will be silent — add one with " +
        `\`radio-program.mjs fallback <clip> --instance ${station.instance}\``
    );
  }
  // Station-owned: the programme. Paths are absolute because the holder does
  // not resolve relatives for us.
  const programme = {
    _comment: `Station programme for "${station.name}" — generated by scripts/radio-program.mjs config; edit ${path.relative(ROOT, BASE_PROGRAMME)} and re-run instead.`,
    schedule,
    ...(fallback ? { file: fallback } : {}),
    ...(station.topic ? { topic: station.topic } : {}),
    loop: baseProgramme.loop ?? true,
  };
  const programmePath = path.join(dir, "programme.json");
  await writeFile(programmePath, JSON.stringify(programme, null, 2) + "\n");
  // Adapter-owned: transport and admission, pointing at the programme.
  const live = {
    _comment: `Generated for station "${station.name}" by scripts/radio-program.mjs config — edit ${path.relative(ROOT, BASE_CONFIG)} and re-run instead.`,
    backend: base.backend ?? "stream",
    programme: programmePath,
    // Public stations admit any sender presenting the page's ticket (subject-
    // less, receive-only). Private stations only take `radio-admit.sh` tickets.
    ...(station.public ? { public: true } : {}),
    log: path.join(dir, "soak.jsonl"),
    broadcast: base.broadcast ?? "idfon-radio",
    voice_route: base.voice_route ?? { mode: "broadcast", audio: "pcm24k" },
  };
  const livePath = path.join(dir, "live.json");
  await writeFile(livePath, JSON.stringify(live, null, 2) + "\n");
  // Machine-readable for radio-serve.sh; the note goes to stderr.
  console.error(`${path.relative(ROOT, livePath)} (${fallback ? "with" : "no"} fallback)`);
  console.log(station.instance);
  console.log(station.name ?? station.instance);
  console.log(livePath);
}

async function readRoster() {
  if (!existsSync(ROSTER)) return [];
  const roster = JSON.parse(await readFile(ROSTER, "utf8"));
  return (roster.stations ?? []).filter((station) => station.instance);
}

/// Topic, instance, or display name — in that order, case-insensitive.
function resolveStation(stations, key) {
  const needle = key.toLowerCase();
  return (
    stations.find((station) => station.topic?.toLowerCase() === needle) ??
    stations.find((station) => station.instance.toLowerCase() === needle) ??
    stations.find((station) => station.name?.toLowerCase() === needle)
  );
}

// --- page (the public station index) ----------------------------------------

async function page() {
  // The namespace rule, enforced again by the edge (`valid_name` in files.rs):
  // lowercase handle, 1–32 of `a-z 0-9 - _`, starting with a letter or digit.
  const handle = /^[a-z0-9][a-z0-9_-]{0,31}$/;
  const name = (values.name ?? "talk-radio").toLowerCase();
  if (!handle.test(name) || name === "sha256") {
    throw new Error(
      `station name must be a handle: 1-32 of a-z 0-9 - _, starting with a letter or digit (got ${JSON.stringify(name)})`
    );
  }
  const base = (values.url ?? "https://files.idfon.net").replace(/\/+$/, "");
  const stations = await readRoster();
  if (!stations.length) throw new Error("roster.json lists no stations to publish");

  const cards = [];
  for (const station of stations) {
    const home = path.join(os.homedir(), ".idfon", station.instance);
    const ticketFile = path.join(home, "holder.ticket");
    if (!existsSync(ticketFile)) {
      console.error(`skip ${station.instance}: no contact yet — run \`radio-serve.sh\` once`);
      continue;
    }
    // The same deep link the app's contact card carries (vcf.rs `link_for_json`).
    const contact = (await readFile(ticketFile, "utf8")).trim().split("\n")[0];
    let payload = contact;
    if (station.public) {
      // One scan adds the contact AND the receive-only credential any sender
      // may present. Refused unless this station's live config opted in.
      const capability = await publicTicket(station);
      // `label` is not part of an EndpointAddr but serde ignores it; the app
      // reads it to name the contact ("Add Tech Talk?") instead of "Contact".
      payload = JSON.stringify({
        contact: { ...JSON.parse(contact), label: station.name ?? station.instance },
        capability: JSON.parse(capability),
      });
    }
    const link = `idfon://add/${Buffer.from(payload, "utf8").toString("base64url")}`;
    // Long payloads need a lower error-correction tier or the code gets too
    // dense to read off a screen; the page is scanned, not printed and creased.
    const qr = qrcode(0, station.public ? "L" : "M");
    qr.addData(link);
    qr.make();
    cards.push({
      name: station.name ?? station.instance,
      topic: station.topic ?? "",
      public: Boolean(station.public),
      link,
      qr: qr.createSvgTag({ cellSize: 3, margin: 4, scalable: true }),
    });
  }
  if (!cards.length) throw new Error("no station has a contact yet; serve one first");

  const dir = path.join(RADIO, "page", name);
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, "index.html"), renderIndex(name, cards, base));

  const rel = path.relative(ROOT, path.join(dir, "index.html"));
  console.error(`page -> ${rel} (${cards.length} topic(s))`);
  console.log(`${base}/${name}/`);
  console.log();
  console.log("publish:");
  console.log(`  idfon publish ${rel} --name ${name}/index.html --permanent`);
}

/// A subject-less, receive-only ticket the station signs for itself. The holder
/// only honours it when its live config says `"public": true`; `config` copies
/// that from the roster entry.
async function publicTicket(station) {
  const home = path.join(os.homedir(), ".idfon", station.instance);
  const live = path.join(RADIO, "instances", station.instance, "live.json");
  const bin = path.join(ROOT, "target", "release", "eve-idfon-voice");
  if (!existsSync(live)) {
    throw new Error(`${station.instance} has no live config yet — run \`radio-serve.sh\` once`);
  }
  if (!existsSync(bin)) throw new Error(`missing ${path.relative(ROOT, bin)} — run \`pnpm voice build\``);
  const minted = spawnSync(
    bin,
    ["--key-file", path.join(home, "holder.key"), "--live-config", live, "ticket", "--public"],
    { encoding: "utf8" }
  );
  if (minted.status !== 0) throw new Error(`ticket mint failed for ${station.instance}: ${(minted.stderr ?? "").trim()}`);
  return minted.stdout.trim();
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[c]);
}

function renderIndex(name, cards, base) {
  const items = cards
    .map(
      (card) => `<li class="card">
  <div class="qr">${card.qr}</div>
  <div class="body">
    <h2>${escapeHtml(card.topic || card.name)}</h2>
    <p class="station">${escapeHtml(card.name)}</p>
    <p class="hint">Scan with the Idfon app to add ${escapeHtml(card.topic || card.name)} as a contact${card.public ? " — listen straight away" : ""}.</p>
    <p class="link"><a href="${escapeHtml(card.link)}">${escapeHtml(card.link)}</a></p>
  </div>
</li>`
    )
    .join("\n");
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(name)} — talk radio</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0 auto; max-width: 52rem; padding: 2.5rem 1.25rem 4rem;
         font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
  h1 { font-size: 1.6rem; margin: 0 0 .25rem; letter-spacing: -.01em; }
  .sub { margin: 0 0 2rem; opacity: .65; }
  ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 1rem; }
  @media (min-width: 40rem) { ul { grid-template-columns: 1fr 1fr; } }
  .card { display: flex; gap: 1rem; padding: 1rem; border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
          border-radius: 14px; align-items: flex-start; }
  .qr { flex: none; width: 200px; line-height: 0; padding: 8px; background: #fff; border-radius: 8px; }
  .qr svg { width: 184px; height: 184px; display: block; }
  h2 { font-size: 1rem; margin: 0 0 .15rem; }
  .station, .hint { margin: 0 0 .5rem; font-size: .85rem; opacity: .7; }
  .link { margin: 0; font-size: .7rem; overflow-wrap: anywhere; opacity: .5; }
  .link a { color: inherit; }
  footer { margin-top: 2.5rem; font-size: .8rem; opacity: .55; }
</style>
</head>
<body>
<h1>${escapeHtml(name.replace(/-/g, " "))}</h1>
<p class="sub">One-way talk-radio stations. Audio only, no microphone.</p>
<ul>
${items}
</ul>
<footer>Served from <code>${escapeHtml(base)}/${escapeHtml(name)}/</code>. Add the contact, then call it to listen.</footer>
</body>
</html>
`;
}

// --- audio ------------------------------------------------------------------

/// Convert whatever ffmpeg can read (a file, an episode URL) into the 24 kHz
/// mono PCM WAV the stream backend plays. Returns the path relative to the
/// station's state dir, which is how the schedule refers to content.
async function ingest(source, label, { noFetch = false, target: exact } = {}) {
  if (noFetch) return null;
  await mkdir(state.content, { recursive: true });
  const stem = String(label ?? "programme")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40);
  const digest = createHash("sha256").update(source).digest("hex").slice(0, 8);
  const name = `${stem || "programme"}-${digest}.wav`;
  // A named target (the station fallback) is replaced on every run, so
  // re-pointing it at a new clip is a file swap rather than a new hash.
  const target = exact ?? path.join(state.content, name);
  if (!exact && existsSync(target)) return path.relative(state.dir, target);

  console.log(
    `converting ${source.startsWith("http") ? "episode" : source} -> ${path.basename(target)}`
  );
  ffmpeg(source, target);
  return path.relative(state.dir, target);
}

/// Anything ffmpeg can read -> the call profile (24 kHz mono s16 PCM).
function ffmpeg(source, target) {
  const result = spawnSync(
    "ffmpeg",
    [
      "-nostdin", "-loglevel", "error", "-y",
      "-i", source,
      "-ar", String(RATE), "-ac", "1", "-c:a", "pcm_s16le",
      target,
    ],
    { stdio: ["ignore", "inherit", "pipe"], encoding: "utf8" }
  );
  if (result.status !== 0) {
    throw new Error(`ffmpeg failed for ${source}: ${(result.stderr ?? "").trim().split("\n").pop()}`);
  }
}

/// "nothing to play": a station with no playable programme gets one segment
/// made from the newest brief, through the same submission path a listener
/// uses. No brief, no topic, or `--no-fetch`: say so and leave it empty.
async function fillIfEmpty() {
  if (!values.fill) return;
  if (values["no-fetch"]) {
    console.error("--fill fetches and speaks; skipped under --no-fetch");
    return;
  }
  if ((await readJsonl(state.submissions)).some((s) => s.intent === "play" && s.clip)) return;
  const topic = await stationTopic();
  if (!topic) {
    console.error("--fill: no station topic to base a segment on");
    return;
  }
  const brief = await newestBrief(topic);
  if (!brief) {
    console.error(`--fill: no brief for "${topic}"; run \`brief\` first`);
    return;
  }
  await syntheticSubmission(briefText(brief), topic, "00:00");
  console.error(`--fill: synthesized a segment from ${path.relative(ROOT, brief.file)}`);
}

// --- files ------------------------------------------------------------------

function slugify(text) {
  return String(text ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
}

function dateStamp() {
  return new Date().toISOString().slice(0, 10);
}

function parseDays(days) {
  if (!days) return null;
  const parsed = days.split(",").map((day) => day.trim().toLowerCase()).filter(Boolean);
  if (!parsed.length || parsed.includes("*")) return null;
  return parsed;
}

async function readJsonl(file) {
  if (!existsSync(file)) return [];
  const text = await readFile(file, "utf8");
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch {
        throw new Error(`${path.relative(ROOT, file)} line ${index + 1} is not JSON`);
      }
    });
}

async function append(file, entry) {
  await mkdir(path.dirname(file), { recursive: true });
  await appendFile(file, JSON.stringify(entry) + "\n");
}
