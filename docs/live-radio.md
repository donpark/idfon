# live-radio: a talk-radio contact for call-quality soaks

Status: **as-built** (stream backend, `broadcast` mode, both apps, programming
and submissions). Companion to `docs/media-adaptation.md` (what the walk is
measuring) and `docs/live-voice.md` (the same live-call transport, other
backends).

## What it is

A voice agent that plays audio at you and never listens: call a talk-radio
topic contact at home, keep it running, walk around. Continuous speech is the
point — there are no natural silences to confuse a stall with, and it is the
one realistic audio source the project otherwise lacks (the replay corpus is
text-only by design, see `corpus/voice-interactions/`).

It is a soak rig, not a station browser. The number it produces is the
agent-side JSONL record plus the phone's playout timeline, not an impression.

Three things stay apart, deliberately:

- **the station** — `crates/idfon-radio`: the programme (schedule, clips,
  frames) and nothing else. It knows no transport: an idfon one-way call is one
  adapter, an HLS or HTTP stream would be another, all consuming the same port
  (`Programme::sync` against the clock, then `Programme::frame`).
- **programming** — what plays, when. Data (`schedule.json`), deterministic,
  no model, no network at call time.
- **the idfon adapter** — `backend: "stream"` in `crates/idfon-voice-agent`:
  pumps the programme into a one-way call's return leg, drains the caller's
  leg, and writes the JSONL record. It owns transport, not taste.
- **the jockey** — anything that *speaks between* items. Its non-speaking half
  is implemented: a segment generated from sourced facts fills an empty station
  (**Filler**, below). Live banter is not, and the call path never needs a
  model. In repeat mode the jockey simply has nothing to say, which is why that
  is the right place to start.

## Why one-way is on the contact, not the preamble

`voice_route.mode = broadcast` is part of the holder's ticket, because a radio
station is *permanently* one-way — same reason `native-duplex` and
`server-cascade` are there. The apps read it and dial a live call instead of
running the client cascade. A per-call `direction=` line in `IDFON-LIVE/1`
would be the right place only when the same contact can also listen (a
radio agent you can interrupt); it does not exist yet.

The topic rides the existing per-contact context (`context_b64`, already
"caller-pushed per-turn context"): the backend reads a `topic=<value>` line and
it wins over the config's `topic` default. That is one agent, many topic
contacts, no new wire field. The app does not send that line yet — until it
does, the config default applies.

## Menu contact: an OPML catalogue of shows

The broadcast station serves many callers at one shared position. The menu
contact serves one caller: it is configured with an OPML resource — a nested
outline of shows, parsed by `crates/idfon-radio/src/menu.rs` — and the caller
plays one show on demand. OPML is data; **the app renders the menu** (decided
2026-11-03: the screen carries the choices, speech is the complementary
side-channel), never audio-prompt navigation.

- `live.json` gains `opml: "shows.opml"` — a hand-edited key survives
  `radio-program.mjs config` regeneration (it re-runs on every
  `radio-serve.sh`), and a relative `opml` resolves beside `live.json` because
  the holder reads it against its own cwd. Entries label with `text`, play with
  `url` (or `xmlUrl`): a URL with a scheme is the **far end**, a bare path is a
  copy in the **local download cache**, and `cache` names the cached copy of a
  far-end source. A cached file that exists wins; otherwise the far end serves.
- The caller selects with a `show=<menu path>` line in the same per-contact
  context as `topic=` — `News/Morning Briefing`, or 1-based indices like `1/2`
  (segments are case-insensitive and mixable). It beats the station default:
  the call plays the chosen show and nothing else.
- Far-end sources play too: ffmpeg decodes the stream (HLS, ICY/MP3, AAC) to
  the station's 24 kHz at call time (`stream.rs` `run_stream`). shortcut: a
  dropped source ends the call (`eof`); retry-with-backoff is shared ingest
  recovery (#119).
- `scripts/radio-stations-opml.mjs` curates a starter menu from real online
  talk stations (Radio Browser discovery + a liveness probe that reads real
  audio bytes) — its output is the `shows.opml` above; the end-to-end run is
  the #135 acceptance gate.
- The holder exposes the OPML as a resource — `idfon://<holder>/menu.opml`,
  advertised as `menu.opml` in the `idfon.json` manifest (an agent-supplied
  `menu` block wins) — fetched by the apps like the voice catalog. A manifest
  `opml` that is an http(s) URL (a station's public OPML) is fetched directly.
- The outline is the contact's **detail surface**: the apps show it as soon as
  the contact opens and again before a call would start (iOS: one push per
  level; mac: an outline sheet). Picking a show dials with `show=` and the call
  plays it; picking another show while one plays **switches** — the current
  call ends and the new show dials (transitions are still unpolished).

Navigation only: no feed fetching, update badges, or cache management — the
epic's standing exclusion. See #133 for the slice ledger.

## Repeat mode (start here)

One clip, looped forever. That is a complete station, and it is the jockey in
repeat mode: it plays, it does not speak.

```sh
node scripts/radio-program.mjs fallback my-clip.mp3 --instance radio-tech
scripts/radio-serve.sh "tech talk"
```

`fallback` converts with ffmpeg to the 24 kHz mono profile and replaces any
previous clip; the backend loops it whenever no slot is active (with no
schedule, always). A repeat-mode call still logs everything a soak needs — the
one `fallback` slot, a heartbeat a second, and any agent-side stall.

It is also the **most comparable** soak: every run plays identical audio, so a
walk before a change and a walk after it differ only in the thing you changed.
Programming buys realism and spends that comparability — use repeat mode to
measure, programming to listen.

## Config: station vs adapter

Two files, so the boundary is visible:

- `programme.json` — **station-owned**: `schedule`, `file` (the clip that loops
  when nothing is scheduled), `topic`, `loop`. Paths are relative to the file.
- `live.json` — **idfon-owned**: `backend`, `programme` (points at the file
  above), `log`, `broadcast`, `voice_route`, and `public` for admission.

`scripts/radio-program.mjs config` writes both into the instance directory with
absolute paths (the holder resolves no relatives). A `live.json` with the old
inline `schedule`/`file` keys still works — that is what the shipped
`agents/radio/live.json` uses for the single-station case.

## Programming (optional)

Additive on top of repeat mode: slots override the loop while they are active.

```
submit  (a clip, or just a pitch) ──▶ submissions.jsonl ─┐
find    (episodes on the brief)   ──▶ candidates.jsonl  ─┴─▶ compile ─▶ schedule.json ─▶ call
```

`scripts/radio-program.mjs` owns all three steps. Only `find` searches and only
`compile` fetches audio; the hold-up between them is deliberate, so scheduling
is reproducible and reviewable.

```sh
cd <repo root>     # config and schedule paths are cwd-relative

# Direct submission: a clip airs in its preferred slot.
node scripts/radio-program.mjs submit my-segment.wav \
  --at 07:00 --days mon,wed --topic "tech talk" --note "school-run pitch"

# Indirect submission: no clip, a topic. compile pairs it with an episode.
node scripts/radio-program.mjs submit --at 19:30 --topic wildlife \
  --note "evening: pair with an episode" --submitter alice

# Search the brief (or --topic "a,b") for episodes; nothing is scheduled yet.
node scripts/radio-program.mjs find --limit 8

# Merge into the schedule, converting whatever was paired (ffmpeg).
node scripts/radio-program.mjs compile        # --no-fetch to plan only
```

Then serve the contact — one station per topic (`-e` below), or the single
shared one:

```sh
scripts/radio-serve.sh "tech talk"     # roster station, own state + identity
scripts/radio-serve.sh radio-wildlife  # ... by instance

# single station, shared agents/radio paths (no roster):
EVE_AGENT=llm EVE_INSTANCE=radio EVE_LIVE_CONFIG=agents/radio/live.json \
  scripts/live-voice-serve.sh
```

Pair the printed ticket as an agent contact, then call it and walk (iOS:
see **Pairing the iPhone** below).

### Pairing the iPhone

> **Testing?** Skip this dance: `node scripts/test-contacts-page.mjs --serve`,
> open the page on the phone, tap the contact, approve in the modal (an
> admission code replaces the console work for protected stations). See
> `docs/contact-exchange.md` "The test-contacts page".

Two credentials, because they answer different questions: the **contact**
(`peer.add`) says who to talk to, and a **capability ticket** — issued by the
station, bound to the sender — is what its ingress gate checks on every
message, including the call invite. The app has no free-form paste for the
second one (the test page's admission-code modal is the testing delivery
path; production delivery stays link-only), so a phone is paired with
`devicectl`, in two launches.

1. Start the station and add the contact once; the app logs its own id:

   ```sh
   scripts/radio-serve.sh "tech talk"
   # keep the printed `contact:` JSON, then:
   xcrun devicectl device process launch --console <udid> com.idfon.ios -- \
     -pair '<contact JSON>' "Tech Talk" -pair-exit
   ```

   The app prints `idfon self ticket: {… "endpoint_id": "<ios-id>" …}`.

2. Admit that id. This mints the ticket, appends the id to the holder's allow
   file (reloaded every 500 ms, so **no restart**), and prints the one launch
   that installs both credentials:

   ```sh
   scripts/radio-admit.sh "tech talk" <ios-id>
   ```

3. Run the printed command, then open the app and call. The stored ticket
   carries `voice.mode = broadcast`, so the contact renders as a one-way listen
   call rather than a chat turn.

A fresh station with a known phone can be registered before its first start:
`scripts/radio-serve.sh "tech talk" <ios-id>`.

**Gap:** there is no in-app paste for an agent's capability ticket — only
`-pair-ticket` at launch, or the chat invite path (`IDFON-INVITE/1`, which
`ChatStore` accepts) that the agency uses. Stations do not send invites yet, so
pairing a phone currently needs `devicectl`. The fix is to let the contact card
(or a station-sent invite) carry the ticket; that is an app change, not a
protocol gap.

## Repeat mode (start here)

One clip, looped forever. That is a complete station, and it is the jockey in
repeat mode: it plays, it does not speak.

```sh
node scripts/radio-program.mjs fallback my-clip.mp3 --instance radio-tech
scripts/radio-serve.sh "tech talk"
```

`fallback` converts with ffmpeg to the 24 kHz mono profile and replaces any
previous clip; the backend loops it whenever no slot is active (with no
schedule, always). A repeat-mode call still logs everything a soak needs — the
one `fallback` slot, a heartbeat a second, and any agent-side stall.

It is also the **most comparable** soak: every run plays identical audio, so a
walk before a change and a walk after it differ only in the thing you changed.
Programming buys realism and spends that comparability — use repeat mode to
measure, programming to listen.

## Programming (optional)

Additive on top of repeat mode: slots override the loop while they are active.

```
submit  (a clip, or just a pitch) ──▶ submissions.jsonl ─┐
find    (episodes on the brief)   ──▶ candidates.jsonl  ─┴─▶ compile ─▶ schedule.json ─▶ call
```

`scripts/radio-program.mjs` owns all three steps. Only `find` searches and only
`compile` fetches audio; the hold-up between them is deliberate, so scheduling
is reproducible and reviewable.

```sh
cd <repo root>     # config and schedule paths are cwd-relative

# Direct submission: a clip airs in its preferred slot.
node scripts/radio-program.mjs submit my-segment.wav \
  --at 07:00 --days mon,wed --topic "tech talk" --note "school-run pitch"

# Indirect submission: no clip, a topic. compile pairs it with an episode.
node scripts/radio-program.mjs submit --at 19:30 --topic wildlife \
  --note "evening: pair with an episode" --submitter alice

# Search the brief (or --topic "a,b") for episodes; nothing is scheduled yet.
node scripts/radio-program.mjs find --limit 8

# Merge into the schedule, converting whatever was paired (ffmpeg).
node scripts/radio-program.mjs compile        # --no-fetch to plan only
```

Then serve the contact — one station per topic (`-e` below), or the single
shared one:

```sh
scripts/radio-serve.sh "tech talk"     # roster station, own state + identity
scripts/radio-serve.sh radio-wildlife  # ... by instance

# single station, shared agents/radio paths (no roster):
EVE_AGENT=llm EVE_INSTANCE=radio EVE_LIVE_CONFIG=agents/radio/live.json \
  scripts/live-voice-serve.sh
```

Pair the printed ticket as an agent contact, then call it and walk (iOS:
see **Pairing the iPhone** below).

### Pairing the iPhone

The holder admits senders by **endpoint id** (`--allow`, from the Mac daemon's
peer list plus `capability-ticket-<endpoint>.json`). An iPhone has its own
identity, so it is not in that list until it is registered — and the app needs a
capability ticket subject-bound to *its* id, not the Mac's.

1. Start the station and keep the printed `contact:` JSON (the `pairing:` block
   shows the same commands for the local apps).
2. Add the contact, which also logs the phone's own id:

   ```sh
   xcrun devicectl device process launch --console <udid> com.idfon.ios -- \
     -pair '<contact JSON>' "Tech Talk" -pair-exit
   ```

   The app prints `idfon self ticket: {… "endpoint_id": "<ios-id>" …}`.
3. Restart the station admitting that id — it mints the ticket and prints the
   `capability-ticket-<ios-id>.json` line:

   ```sh
   scripts/radio-serve.sh "tech talk" <ios-id>
   ```

4. Install the ticket (the serve output has the exact JSON):

   ```sh
   xcrun devicectl device process launch --console <udid> com.idfon.ios -- \
     -pair-ticket <holder endpoint id> '<ticket JSON>' -pair-exit
   ```

5. Launch normally and call it: a `broadcast` contact renders as a one-way
   listen call, not a chat turn.

**Gap:** there is no in-app paste for an agent's capability ticket — only
`-pair-ticket` at launch, or the chat invite path (`IDFON-INVITE/1`, which
`ChatStore` accepts) that the agency uses. Stations do not send invites yet, so
pairing a phone currently needs `devicectl`.

## Submissions: direct and indirect

A submission is shaped like a **radio programme submission** — a tape and a
pitch — not just a file in a slot:

| `intent` | has audio | what it does |
| --- | --- | --- |
| `play` | yes (`clip` or `--url`) | airs directly in its preferred slot |
| `influence` | no | its topic enters the brief; `compile` pairs it with a found episode |

Both carry `note`, which no code acts on: it rides the slot into the log and
into the schedule's `brief`, so a jockey (later) has the pitch that got the
programme scheduled. That is the whole of "influence content directly or
indirectly" today — direct = the clip is the programme, indirect = the pitch
steers what gets programmed. Anything cleverer (reading the note on air,
adapting the clip) belongs to the jockey, not here.

Inputs are append-only files, so nothing is lost and `compile` can be re-run
freely:

- `agents/radio/submissions.jsonl` — one submission per line (`submit` appends).
- `agents/radio/candidates.jsonl` — episodes from `find`, deduped by URL.
- `agents/radio/content/` — converted 24 kHz WAVs (**gitignored**: station
  audio is not ours to publish).
- `agents/radio/schedule.json` — derived; `compile` rewrites it whole.

## The public page

`page` writes one static index for the whole roster: a card per station with its
contact QR (inline SVG — no external images, so the page is one file) and the
deep link in text.

```sh
node scripts/radio-program.mjs page --name talk-radio
idfon publish agents/radio/page/talk-radio/index.html \
  --name talk-radio/index.html --permanent
```

That serves at `https://files.idfon.net/talk-radio/`: the CDN rewrites its root
onto the edge's `/files/` store, and a directory URL resolves to `index.html`
there (`page_path` in `crates/idfon-edge/src/files.rs`). So the branded URL has
no `/files/` in it while the origin keeps the prefix — that mount is where a
path-scoped token would turn a name into an *enforceable* claim.

**The name is a handle**, Twitter-like: lowercase, 1–32 of `a-z 0-9 - _`,
starting with a letter or digit. Enforced in both the page command and the edge
(`valid_name`); `sha256` is reserved for the content route. Hyphens are allowed
because the station names have them (`talk-radio`, `phonon-31m`).

**A public station's QR is self-service.** The roster entry says `"public": true`,
`config` carries that into the live config, and `page` asks the station to sign
a **subject-less, receive-only** ticket (`ticket --public`). The link becomes an
envelope:

```
idfon://add/<b64url({ "contact": <card>, "capability": <station ticket> })>
```

The apps decode the envelope, add the contact, and store the capability ticket
under that peer — so one scan both adds the topic and makes it callable. A
legacy contact-only link still works (the payload is then the card).

**A private station omits `public`**: its card carries no ticket, the QR only
adds the contact, and admission stays `scripts/radio-admit.sh` + one
`-pair-ticket` launch. There is no in-app paste for a ticket; the add link is
the only delivery path.

**What `public` gives away.** The ticket is a shared bearer credential: anyone
who scans can message that station, so its chat (listener submissions
included) is world-writable and the holder honours it only because its live
config opted in (`ticket --public` refuses without it). Revoking it means
rotating the station's identity — which invalidates every printed QR, so the
page must be republished with fresh ones. Rate-limit before opening one to the
world.

## The schedule

```json
{
  "brief": { "topics": ["wildlife"], "notes": [{ "submitter": "alice", "topic": "wildlife", "note": "…" }] },
  "slots": [
    { "at": "07:00", "days": ["mon", "wed"], "file": "content/tech-talk-b19e9084.wav",
      "topic": "tech talk", "title": null, "origin": "submitted", "note": "school-run pitch" },
    { "at": "19:30", "file": "content/wildlife-58754771.wav",
      "topic": "wildlife", "title": "A Life Among Wildlife", "origin": "https://…/episode.mp3" }
  ]
}
```

- `at` is local `HH:MM`; `days` (`mon`…`sun`, or omitted/`"*"` = every day)
  gates the **start**, so a Monday 23:00 slot is still the programme at Tuesday
  00:30. A slot holds the air until the next start.
- `file` is relative to the schedule file; `origin` is `submitted` or the
  episode URL it was fetched from; `note` is the submitter's pitch.
- With no slot active the call falls back to the config's `file` and loops it.
  No slots and no fallback = silence (the call stays up), which is a legitimate
  "no programming" state.
- An edited schedule is picked up mid-call within a second — no restart, no
  re-pairing. A broken schedule edit is ignored (last good one keeps playing)
  and logged as an `error`.

## Filler: when there is nothing to play

A slot holds the air until the next start, so any slot at all covers the clock;
"nothing to play" means an **empty programme**, not a gap between slots. That
case has two mechanical answers and an optional model turn:

```sh
node scripts/radio-program.mjs brief --instance radio-tech --query technology
node scripts/radio-program.mjs segment --say "…" --at 09:00 --instance radio-tech
node scripts/radio-program.mjs compile --fill --instance radio-tech
```

- **`brief`** gathers 3 facts with their article URLs from Wikipedia
  (keyless, topic-agnostic). `--query` searches better words than the station
  name; the record keeps the station topic.
- **`segment`** speaks the words with the host's TTS (`say` on macOS,
  `espeak-ng` elsewhere), converts to the 24 kHz mono profile, and registers it
  as a **synthetic play submission** — the same path a listener's clip takes.
- **`compile --fill`** does both when the station has no playable submission:
  it reads the newest brief's facts verbatim, attributed ("According to
  Wikipedia's article on …"), and schedules the result at `00:00`.

An agent can write better words than the mechanical read: run `brief`, write a
script from the JSON, then `segment --text FILE`. The model only ever words
facts a script gathered — it does not choose them, which is what keeps a
fabricated claim out of the station.

**Synthetic is labelled, not disguised.** The submission carries
`synthetic: true` and `origin: "synthetic:<topic>"`, and that origin rides the
slot into the soak log. Using the listener path is the point (it dogfoods real
submissions); pretending a human sent it is not.

**The jockey's other half is chat.** A listener message, clip, or URL reaches
the agent as an ordinary turn: it replies in chat and calls `submit`. Chat is
where the jockey talks; the call only plays files. No model, no network, no
surprise in the middle of a soak.

## Stations per topic (the roster)

One agent directory serves many topic stations; each station keeps its own
state and identity, so a topic's schedule, brief, submissions and content never
mix with another's.

```json
// agents/radio/roster.json
{ "stations": [
  { "name": "Tech Talk",     "topic": "tech talk", "instance": "radio-tech" },
  { "name": "Wildlife Hour", "topic": "wildlife",  "instance": "radio-wildlife" }
] }
```

`scripts/radio-serve.sh <topic|instance|name>` resolves the entry, creates
`agents/radio/instances/<instance>/`, writes a `live.json` with absolute paths
(the holder expands neither `~` nor cwd), and runs the normal serve script with
`EVE_INSTANCE`/`EVE_CONTACT_NAME`, so the station gets its own holder home
(`~/.idfon/<instance>`), pinned port and pairing identity.

Programme an instance by naming it (or exporting `IDFON_RADIO_INSTANCE`):

```sh
node scripts/radio-program.mjs submit seg.wav --at 08:00 --topic "tech talk" --instance radio-tech
node scripts/radio-program.mjs find --instance radio-tech
node scripts/radio-program.mjs compile --instance radio-tech
```

State per instance (all gitignored under `instances/`): `schedule.json`,
`submissions.jsonl`, `candidates.jsonl`, `content/`, `soak.jsonl`, `live.json`
(generated), optional `fallback.wav` (overrides the shared fallback).

**Why many stations rather than one manager arbitrating a shared timeline:**
the timeline *is* the station. Two topics that must both own 19:30 are two
stations, not one schedule with an owner field. That keeps the schedule format
topic-free and makes the state boundary the identity boundary — which is also
the authority boundary: a curator who owns a topic owns its station.

A switchboard over these is a roster lookup, not a spawner: the agents already
run, and the caller is introduced to one (`agents/agency` shape). The manager
therefore needs no call path of its own. Pointing the agency at this roster is
**not built** — its `request-invite` tool resolves by `model`, not topic.

## The log

One JSON object per line, `t_ms` from call start:

| event | fields | meaning |
| --- | --- | --- |
| `start` | `slots`, `fallback`, `loop`, `rate` | what this call was programmed with |
| `slot` | `at`, `file`, `title`, `topic`, `origin`, `note` | programme change (incl. `fallback` / `none`) |
| `schedule` | `slots` | an edit was reloaded mid-call |
| `error` | `message` | a slot clip or schedule edit could not be used |
| `heartbeat` | `sent_s`, `queued_ms` | 1 Hz: the agent is still feeding the encoder |
| `gap` | `late_ms` | the **agent host** missed a 20 ms tick (not the network) |
| `eof` / `stop` | `sent_s` (eof) | a non-looping fallback ended, or the caller hung up |

`gap` is the only agent-side quality signal here. Everything else about the
call (handover, jitter, playout lag) lives on the phone's side
(`moq-media/src/stats.rs` timeline); correlate the two by wall clock. A `gap`
in isolation means the agent host stalled; a stall on the phone with no `gap`
is the network — that separation is why it is logged at all.

## Soak modes

The app keeps the microphone publishing (the ordinary duplex call), which is
the useful default: the uplink stays real, so congestion control, ABR and the
5-tuple are exercised the way a real call exercises them, while the agent
simply drops whatever it hears.

- **silent uplink (default, today)** — mic on, agent ignores it. Honest
  two-way network, one-way audio. The holder still *subscribes* to the
  caller's track (`stt_side` defaults to `server` for a broadcast route) and
  the backend drains it, so the uplink is real media, not just a keepalive.
- **receive-only** — mic closed. Not implemented: it needs a per-call flag and
  an app-side mic policy. Worth adding for battery on long walks and for
  isolating pure-downlink behaviour, but it *removes* the uplink-saturation
  failure mode (`docs/media-adaptation.md` A4/A5), so it is a bisect tool, not
  the default soak.

## Limits

- **Live stations are not supported.** MP3/AAC over ICY or HLS needs a decoder
  (and HLS a demuxer); `stream.rs` carries the `shortcut:` note and the upgrade
  condition. Search results are therefore *episodes*, not live streams: a live
  station has no time slots to schedule. Fetch first, then replay — which is
  also reproducible.
- **Disk and memory are real.** 24 kHz mono s16 is ~173 MB per hour; a slot
  clip is loaded whole when the slot starts. Fine for a home soak, not for a
  week of programming.
- **The filler has one source and a host TTS.** Facts are Wikipedia-only, and
  `say`/`espeak-ng` must exist on the agent host (swap to the repo's TTS
  engines for headless). A filled slot loops like any other, so a 27 s segment
  repeats for a day — fine for a soak, cap it or rotate variants for a demo.
- **Do not archive what you play.** `agents/radio/content/`,
  `agents/radio/*.wav`, `briefs/`, `segments/` and `instances/` are gitignored,
  and station audio must stay out of the corpus and out of any published
  bundle. Generated segments are ours, but they are regenerable — the brief is
  the record worth keeping.
- **Station state is machine-local.** Instances do not travel with the repo:
  a lost `~/.idfon/<instance>` means re-pairing that station, and its schedule
  and content live only on the machine that programmed it.
- **No per-contact topic UI yet** — see above.
