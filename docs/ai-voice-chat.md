# ai-voice-chat: a voice agent on the idfon channel

`agents/ai-voice-chat` is an Eve agent that answers idfon voice messages with
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

## Building

The agent consumes the workspace extension, so build the extension before the
agent. `pnpm eve build` does both (extension first, then every installed
agent); `pnpm agent` manages one agent at a time:

```sh
pnpm eve build                    # eve-idfon + all agents
pnpm eve clean                    # remove dist/.output everywhere

pnpm agent build ai-voice-chat    # eve build in agents/ai-voice-chat
pnpm agent clean ai-voice-chat
pnpm agent restart ai-voice-chat  # stop then start; needs AI_GATEWAY_API_KEY
```

`pnpm agent build all` / `clean all` cover every `agents/*` directory and skip
agents without an installed `eve`; `start`/`stop`/`restart` apply only to
agents with a `scripts/<name>-serve.sh`. The extension is also rebuilt by its
`prepare` script on `pnpm install`, and lazily by an agent's `eve build` when
`dist/extension/_manifest.json` is stale.

## Serving the agent

`scripts/ai-voice-chat-serve.sh` runs the whole stack against the real daemon
as a long-lived local service. The holder key persists at
`${EVE_VOICE_HOME:-$HOME/.idfon/ai-voice-chat}` so the agent keeps one
identity across restarts — pair once.

```sh
AI_GATEWAY_API_KEY=... scripts/ai-voice-chat-serve.sh   # foreground
```

The script stays in the foreground — run it in a terminal tab, tmux pane, or
background it yourself; it is not a launchd/daemon service and dies with the
shell that owns it. Re-running it is safe: it kills the previous instance's
processes (tracked via pid files in the home dir), rebuilds only when the
agent source changed, and restarts on the same identity.

Check it is alive:

```sh
ps -p "$(cat ~/.idfon/ai-voice-chat/holder.pid)" >/dev/null && echo up
# or end to end:
idfon --socket /tmp/idfon/idfond.sock send ai-voice-chat \
  --text "ping" --capability-ticket "$(cat ~/.idfon/ai-voice-chat/capability-ticket.json)"
```

It prints the two artifacts pairing needs (also written to
`~/.idfon/ai-voice-chat/`): the **contact** (endpoint-addr JSON) and the
**capability ticket** (holder-signed, subject-bound to the daemon).

## Pairing the Apple apps

```sh
# 1. contacts: adds the agent peer to the mac and iOS daemons
pnpm pair --eve-ticket "$(head -1 ~/.idfon/ai-voice-chat/holder.ticket)"

# 2. capability tickets (the holder gates ingress; each app needs the ticket
#    subject-bound to ITS OWN endpoint id — one file per peer in the home dir):
#    mac — launch with the automation arg:
open -a Idfon --args \
  -pair-ticket "$HOLDER_PID" "$(cat ~/.idfon/ai-voice-chat/capability-ticket.json)"
#    iOS (<IOS_PID> = the iPhone's endpoint id, e.g. from `idfon peer show iphone`):
xcrun devicectl device process launch --device <udid> --terminate-existing \
  app.idfon -- -pair-ticket "$HOLDER_PID" \
  "$(cat ~/.idfon/ai-voice-chat/capability-ticket-$IOS_PID.json)"
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

After pairing, chat with the `ai-voice-chat` peer from either app: text gets
a text reply, a voice memo gets transcript text plus an `IDFON-DATA/1`
envelope whose ticket fetches the playable WAV reply.

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

For the `ai-voice-chat` peer, the iOS call button uses the audio-only
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

The iOS embedded daemon's event cursor must keep increasing after its 1,000
event retention limit. Otherwise, the holder's return invite is persisted but
isn't delivered to `ChatStore` after the saved cursor.

Mid-call dead air on the phone (track ending early, silent re-subscribe
behavior, pacing) is covered in `docs/troubleshooting.md` → "iOS live call
goes silent after the first reply".

## Known gaps

- Daemon-side network fetch of holder-held blobs returns `PeerOffline`
  (provider gap shared with the blob lessons in `docs/cli-data.md`); the e2e
  verifies the reply from the holder's store directly.
- The first turn after a cold holder start can lose attachment staging
  (fetch races the holder connection); the e2e retries with a fresh
  recording, and the serve script's long-lived holder avoids it in practice.
- `IDFON-FILE/1` attachments are acknowledged but not interpreted.
- Delegation is wired but not yet exercised by a Live session that actually
  delegates; the commentary/thinking paths follow the published guide.
