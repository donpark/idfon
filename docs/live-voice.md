# live-voice: a voice agent on the idfon channel

`agents/live-voice` is an Eve agent that answers idfon voice messages with
a spoken reply. Text turns go to a gateway text model; a voice memo is
decoded to 24 kHz PCM and answered by OpenAI's `gpt-live-1` full-duplex voice
model over its AI Gateway Live WebSocket, with deep work delegated to
`openai/gpt-6-luna`. It is a normal idfon peer — the Apple apps chat with it
exactly as with a human.

Companion to `docs/idfon-eve.md` (the channel design) and
`docs/audio-media.md` (recording formats).

## Architecture

```
idfon peer ──IDFON-RECORDING/1──▶ daemon ──▶ holder ──bridge──▶ Eve app
                                                                │
                                              ┌─────────────────┤
                                              ▼                 ▼
                                    gpt-6-luna (text,     GPT-Live WS session
                                    delegation, orch.)    (PCM 24k in/out)
                                              │                 │
                                              └────────┬────────┘
                                                       ▼
                                        reply WAV blob ──IDFON-DATA/1──▶ peer
```

- **Inbound voice**: the holder's envelope parser accepts both
  `IDFON-DATA/1` and `IDFON-RECORDING/1` (both carry `ticket=`), so a voice
  memo becomes an Eve file part. Eve stages it in the sandbox at
  `/workspace/attachments/<sha>/file-<sha>` (extensionless — the channel
  stamps `application/octet-stream`).
- **`voice_reply` tool** (`agent/tools/voice-reply.ts`): reads the staged
  Ogg Opus (48 kHz), decodes via WASM (`ogg-opus-decoder`), decimates 2:1 to
  s16le mono 24 kHz, opens one GPT-Live session
  (`wss://ai-gateway.vercel.sh/v1/live/sessions`), pumps input at the 20 ms
  pace the protocol expects, collects `session.output_audio.delta` +
  transcripts, closes on reply quiet (energy-keyed — Live streams silence
  deltas continuously, so quiet detection must key on |s16| > 300, not delta
  recency), WAV-wraps the reply and stores it through the bridge `/blob/put`.
  Returns the spoken transcript plus an `IDFON-DATA/1` envelope the model
  includes in its reply text.
- **Delegation**: on `session.delegation.created` the tool runs
  `openai/gpt-6-luna` (`generateText`, conversation-so-far as context, ≤300
  tokens) and returns the result on `session.commentary.append` so GPT-Live
  speaks it; failures go to `session.thinking.append`. Delegated calls bill
  separately from the $0.05/min voice session.
- **Orchestration**: the Eve agent's model (`EVE_IDFON_MODEL`, default
  `openai/gpt-6-luna`) handles text turns and decides to call `voice_reply`.
  claude-haiku-4.5 announced "I'll transcribe" and ended the turn without
  calling the tool; gpt-6-luna calls it reliably.
- **GPT-Live is not the Realtime API**: separate endpoint, `session.start` /
  `session.input_audio.append` / `session.close` event names, no
  `session.update`/`response.create`, WebSocket only, PCM 24 kHz only (no
  Opus input — the one decode on the way in is mandatory; the reply is stored
  as WAV, so no encode).

**Platform/agent separation (#16).** The live-call relay is an agent-side
handler (`crates/idfon-live-gpt`), registered against the holder's
capability-keyed live-call seam (`crates/eve-idfon/src/live.rs`:
`LiveCallHandler` + `LiveCallRegistry`). The generic holder names no model
vendor; a build that wants live calls composes `eve_idfon::run()` with the
handler (`eve-idfon-gpt`). Provider values — endpoint, model, credential env
name, persona/instructions, broadcast id, delegation tag, turn cap — come from
the channel's `live` metadata (`agents/live-voice/live.json`, forwarded by
`serve --live-config`; the same block rides in the Eve extension config).

## Building

The agent consumes the workspace extension, so build the extension before the
agent. `pnpm eve build` does both (extension first, then every installed
agent); `pnpm agent` manages one agent at a time:

```sh
pnpm eve build                    # eve-idfon + all agents
pnpm eve clean                    # remove dist/.output everywhere

pnpm agent build live-voice    # eve build in agents/live-voice
pnpm agent clean live-voice
pnpm agent restart live-voice  # stop then start; needs AI_GATEWAY_API_KEY
```

`pnpm agent build all` / `clean all` cover every `agents/*` directory and skip
agents without an installed `eve`; `start`/`stop`/`restart` apply only to
agents with a `scripts/<name>-serve.sh`. The extension is also rebuilt by its
`prepare` script on `pnpm install`, and lazily by an agent's `eve build` when
`dist/extension/_manifest.json` is stale.

## Serving the agent

`scripts/live-voice-serve.sh` runs the whole stack against the real daemon
as a long-lived local service. The holder key persists at
`${EVE_VOICE_HOME:-$HOME/.idfon/live-voice}` so the agent keeps one
identity across restarts — pair once.

```sh
AI_GATEWAY_API_KEY=... scripts/live-voice-serve.sh   # foreground
```

The script stays in the foreground — run it in a terminal tab, tmux pane, or
background it yourself; it is not a launchd/daemon service and dies with the
shell that owns it. Re-running it is safe: it kills the previous instance's
processes (tracked via pid files in the home dir), rebuilds only when the
agent source changed, and restarts on the same identity.

Check it is alive:

```sh
ps -p "$(cat ~/.idfon/live-voice/holder.pid)" >/dev/null && echo up
# or end to end:
idfon --socket /tmp/idfon/idfond.sock send live-voice \
  --text "ping" --capability-ticket "$(cat ~/.idfon/live-voice/capability-ticket.json)"
```

It prints the two artifacts pairing needs (also written to
`~/.idfon/live-voice/`): the **contact** (endpoint-addr JSON) and the
**capability ticket** (holder-signed, subject-bound to the daemon).

## Pairing the Apple apps

```sh
# 1. contacts: adds the agent peer to the mac and iOS daemons
pnpm pair --eve-ticket "$(head -1 ~/.idfon/live-voice/holder.ticket)"

# 2. capability tickets (the holder gates ingress; each app needs the ticket
#    subject-bound to ITS OWN endpoint id — one file per peer in the home dir):
#    mac — launch with the automation arg:
open -a Idfon --args \
  -pair-ticket "$HOLDER_PID" "$(cat ~/.idfon/live-voice/capability-ticket.json)"
#    iOS (<IOS_PID> = the iPhone's endpoint id, e.g. from `idfon peer show iphone`):
xcrun devicectl device process launch --device <udid> --terminate-existing \
  app.idfon -- -pair-ticket "$HOLDER_PID" \
  "$(cat ~/.idfon/live-voice/capability-ticket-$IOS_PID.json)"
```

`$HOLDER_PID` is the holder's endpoint id (printed by the serve script; the
first field of the contact JSON). Two rules the pairing flow learned the hard
way:

- **The peer id must be the holder's endpoint id.** Channel peers need
  `id == endpoint id` (`doctor` reports MISMATCH otherwise), and grant
  subjects are matched against `peer.id` — a peer added under a display name
  breaks the reply path with misleading handshake-timeout errors.
- **Grant subjects are endpoint ids, not names.** The serve script grants
  `message.send`/`message.receive` for the holder's endpoint id on the
  daemon side; the apps grant their own side via the pair flow.

After pairing, chat with the `live-voice` peer from either app: text gets
a text reply, a voice memo gets transcript text plus an `IDFON-DATA/1`
envelope whose ticket fetches the playable WAV reply.

The agent also has an `add_artifact` tool (`agent/tools/add-artifact.ts`):
when a turn produces something worth viewing (a report, table, JSON, chart),
it stores the bytes through the bridge's `/blob/put` and returns an
`IDFON-ARTIFACT/1` envelope the model appends to its reply. The apps split the
reply text from the envelope and show the artifact as an openable card in the
thread (see `docs/idfon-artifacts.md`). When the user points at part of an
artifact, the turn is an `IDFON-REF/1` envelope and the agent calls
`read_reference` (`agent/tools/read-reference.ts`) to fetch the referenced
content before answering.

## Testing

```sh
scripts/eve-voice-e2e.sh            # full loop; needs AI_GATEWAY_API_KEY, say, ffmpeg
scripts/voice-audio-check.mjs       # no-network pipeline check (decode/decimate/WAV)
```

The e2e synthesizes a question with `say`, sends it as an
`IDFON-RECORDING/1` message through a temp daemon, and asserts the reply
carries a transcript and an envelope whose blob is a valid 24 kHz mono WAV.
`KEEP=1` keeps the workdir for debugging.

## Live calls

For the `live-voice` peer, the iOS call button uses the audio-only
`LiveCall` path (other peers retain video-capable calls). Its start invite
carries `return_addr` (base64 serialized daemon `EndpointAddr`) so the holder
can dial the phone's advertised addresses, and the holder marks its return leg
with `return=1`. The app ignores replayed return legs when no outgoing call is
active; startup recovery sends a versioned stop invite to the holder.

The holder starts GPT-Live only after the return invite is acknowledged. It
opens a MoQ router for the outgoing audio broadcast, streams caller PCM16 mono
24 kHz, and sends `session.close` on hangup, waiting up to 15 seconds for
`session.closed` before dropping a stuck socket. GPT-Live handles listen/speak
turns over continuous input; the client does not run VAD or send a separate
commit event. Keep forwarding microphone audio continuously.

### Live transcripts and delegated artifacts

During a call the holder forwards GPT-Live's input and output transcripts to
the caller as `IDFON-CALL/1` message envelopes, so the chat view shows the
spoken turns as bubbles. Envelopes carry coalesced **snapshots** (the full text
so far for a `turn_id`), throttled to ~2.5/second; a turn starts on a speaker
switch or a >1.2 s pause, and `final: true` closes the bubble. Both apps upsert
by `turn_id` (append on first snapshot, replace the bubble thereafter) and
persist the raw envelope, so reload restores the same coalesced bubbles.

GPT-Live's Live API has no tools, so the holder starts the session with
`delegation: {type: "client"}`. On `session.delegation.created` the holder runs
the delegated request as a normal Eve turn through the bridge (the same
`turn.in` → `/reply` path a chat message uses), with the caller's identity as
the session address. The agent's reply — text plus any `IDFON-ARTIFACT/1`
envelope from `add_artifact` — is routed to the caller's thread mid-call, and
the envelope-stripped text is appended back to the session as
`session.commentary.append` (`delegation_id` pinned) so GPT-Live speaks the
result. The live instructions tell the model to keep spoken turns short and
delegate anything the caller should look at.

The iOS embedded daemon's event cursor must keep increasing after its 1,000
event retention limit. Otherwise, the holder's return invite is persisted but
isn't delivered to `ChatStore` after the saved cursor.

Mid-call dead air on the phone (track ending early, silent re-subscribe
behavior, pacing) is covered in `docs/troubleshooting.md` → "iOS live call
goes silent after the first reply". Low GPT-Live playback volume on iOS is
covered there too ("iOS live-call audio too quiet"): `.voiceChat` routes
through VoiceProcessingIO, whose output gain has no public API, so the phone
compensates with a soft-clipped makeup gain (`IDFON_PLAYBACK_GAIN_DB`, iOS
only).

### Sessions and context (design note)

Text and voice are two separate LM sessions with separate contexts, by
necessity of the Live API — not a missing feature:

- **Text** runs on the orchestrator model (`EVE_IDFON_MODEL`, default
  `openai/gpt-6-luna`) in a persistent Eve session keyed by peer id.
- **Voice** runs on `openai/gpt-live-1` in an ephemeral session per memo/call.
  Its input channel is audio only (`session.input_audio.append`); text exists
  only as output/derived data (`*_transcript.delta`) and one-way steering
  (`commentary/thinking/instructions.append`). There is no text-turn input, so
  a typed message cannot be a turn in a Live session.

The two meet only at the delegation boundary: `session.delegation.created`
fires a synthetic one-shot turn into the orchestrator (so tools like
`add_artifact` run), and the result is spoken back via `commentary.append`.
`IDFON-CALL/1` transcript bubbles in the chat are display only — they are not
added to the orchestrator's prompt. So after a text exchange and a call, the
voice model does not know what was texted, and the text model sees the call
only through that one delegation.

There is no single established standard for unifying this; the choice is
**which context owner wins**, with four common shapes:

1. **One owner, voice as I/O adapter.** The orchestrator owns context; every
   voice turn's transcript is appended to it and replies are spoken back. Most
   common with realtime APIs, and the smallest step from today's plumbing.
2. **Shared memory both write.** Two live sessions reading/writing one store
   (summaries/rolling transcript), synced at turn boundaries. Native for each
   model; risks staleness and double-writing.
3. **Mode handoff.** Hand the text context in as the Live session's initial
   instructions; summarize the call back into the text context at hangup.
   Session-bounded, no continuous sync.
4. **Text into the realtime session.** The cleanest, but unavailable here:
   APIs like OpenAI Realtime accept `conversation.item.create` text, making
   typed and spoken turns the same session. GPT-Live has no such channel,
   which is what forces the split.

Recommended direction if this is ever picked up: (1)/(3) — let the Eve
orchestrator own context and drive speech through commentary. The pieces
exist (`IDFON-CALL/1` transcripts, `delegation`, `commentary.append`); the
missing link is piping call transcripts into the orchestrator session rather
than only into the chat UI.

## Decision: fix the coupling before swapping transport or front-end (2026-10-01)

Status: **decision, #1 implemented** (2026-10-01). Reached while reviewing whether to move
the GPT-Live connection off WebSocket to WebRTC.

**The fault line is context ownership, not transport.** GPT-Live currently owns
a voice context while the Eve orchestrator owns the text context, and the two
are never reconciled. Delegation is *not* the defect — it is the intended
pattern: `idfon-harness.md` states a passthrough proxy suffices only for pure
conversation or <1 s read-only tools, and the agent loop exists precisely
because audio needs <500 ms while multi-step, durable, and HITL work does not
fit inside it. The missing link is the transcript→orchestrator hop named
above (design option 1/3), not the split itself.

**WebRTC verdict is contingent, not a clear no.** `omini-duplex-omni.md`
records OpenAI's guidance: WebRTC for browsers/mobile clients, WebSocket for
server-to-server. The holder is middle-tier server, so the current
`wss://ai-gateway.vercel.sh/v1/live/sessions` connection (`crates/idfon-live-gpt/src/lib.rs`,
`agents/live-voice/agent/tools/voice-reply.ts`) is the recommended transport
for this topology. WebRTC only becomes worthwhile if the client is routed
directly to the voice session (proxy-minted ephemeral token, the thin-proxy
pattern in `idfon-harness.md`) — which removes the holder from the media path
and with it the delegation/artifact/identity layer. Confirm whether the
gateway exposes any SDP/WebRTC endpoint before treating this as an option.

**Full-duplex is a category; GPT-Live-1 is one implementation.** The native
omni path is not dead — `omini-duplex-omni.md` documents a self-hosted Moshi +
local controller LM pattern (inner-monologue text stream as the bridge) that
directly implements "full-duplex voice front-end + local LM doing agentic
chores". Its costs are recorded there too: resource contention, latency
calibration (a slow controller needs barge-in/context-cancel), codec fidelity
(Mimi ~1.1 kbps, the "waterlogged" sound), and the same semantic-continuity
problem. Cascade trades those for rebuilding turn-taking (VAD, partial STT,
soft-abort, backchannel filter, semantic abort, AEC, spoken-vs-heard sync).

Decision:

1. **Couple first.** Pipe `IDFON-CALL/1` transcripts into the orchestrator
   session (design option 1/3). Every voice front-end is degraded until this
   exists, and it is required by both the cascade and native branches.
   **Implemented as P0** (#18): the holder buffers call transcripts + a hangup
   summary, and the `eve-idfon` extension drains them into the session as a
   user-role dynamic instruction at the next turn boundary — recording never
   triggers a turn. See `voice-side-channel.md` §P0 implementation.
2. **Voice is a channel capability, not an agent feature.** `voice_reply` is a
   per-agent tool today (`agents/live-voice/agent/tools/voice-reply.ts`);
   the holder already owns the duplex transport, transcripts, and delegation.
   Expose `speak(text)` / `present(artifact)` from the channel so agents stay
   audio-agnostic.
3. **Front-end resolved to cascade STT + TTS.** With the coupling fixed, the
   voice side-channel is a shared service that renders agent text and returns
   user transcripts; its engine is STT + TTS behind the text boundary. This is
   chosen over a full-duplex model because the side-channel exists to serve
   *other agents'* content: cascade gives verbatim rendering, multi-voice
   selection, streaming partial transcripts, deterministic text logging, and a
   single context owner. Full-duplex models add native barge-in/backchannel,
   which is conversational polish, not a structural need — and the
   `speak(text, voice)` signature itself requires a multi-voice backend a
   single-voice realtime model cannot provide. GPT-Live-1 was adopted as a
   familiar/new model, not because duplex is load-bearing; full-duplex is
   demoted to an optional experiment judged only against the text boundary.
   A viral-trend voice belongs in **voice selection** (a TTS voice library),
   not in the transport/architecture.

The answer changes if: the product needs realtime conversational UX (a phone
call rather than spoken notifications/answers), or the gateway offers WebRTC
and client-direct realtime becomes viable. Because the boundary is text, that
swap happens inside the voice service with no change to any agent's contract —
which is the point of fixing the coupling first. Call latency should be
measured before blaming the WS hop rather than the phone→holder MoQ leg.

Follow-on: [`voice-side-channel.md`](voice-side-channel.md) turns this decision
into a service plan — requirements, STT/TTS candidate evaluation, and phasing.

## Known gaps

- Daemon-side network fetch of holder-held blobs returned `PeerOffline` when
  the fetch relied on pkarr alone. It now seeds the ticket's own addresses
  through `MemoryLookup` before downloading
  (`crates/idfon-daemon/src/blob.rs`); still needs a live holder+daemon e2e to
  confirm, since the existing e2e reads the holder's store directly.
- The first turn after a cold holder start can lose attachment staging
  (fetch races the holder connection); the e2e retries with a fresh
  recording, and the serve script's long-lived holder avoids it in practice.
- Blob tickets embed the holder's blob-provider endpoint, which is bound
  fresh on each holder start (`idfon_daemon::blob::put`), so a ticket issued
  before a holder restart can no longer be fetched (`PeerOffline`). Fine while
  the holder keeps running; a persisted provider identity would fix restarts.
- `IDFON-FILE/1` attachments are acknowledged but not interpreted.
- Live-call transcript turn boundaries are heuristic (speaker switch or a
  1.2 s gap); a long mid-turn pause splits one spoken turn into two bubbles.
- The voice-memo `voice_reply` path also uses client delegation but answers via
  `generateText` directly, so it does not produce artifacts; only the live-call
  path routes delegation through the Eve agent.
