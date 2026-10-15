# Idfon docs index

**Read this first, then open only the files you need.** Do not bulk-read `docs/`
— most questions touch one or two entries below.

Status legend: **current** = describes the code as it is; **as-built** = a plan
kept because it records decisions; **design** = not all implemented.

## Orientation

| Doc | Covers | Read when |
| --- | --- | --- |
| `communication-model.md` | identities, peers, messages, grants | anything about the core model |
| `daemon.md` | why there is a daemon at all | questioning the process model |
| `protocol.md` | daemon JSON IPC methods/params | adding/changing an RPC or a client |
| `interaction-parameters.md` | CLI vs GUI responsibility split | where a policy/feature belongs |
| `build.md` | which subprojects to rebuild after a change; the Rust/FFI target dirs | touching a shared crate or the vendored c-ffi, or unsure what needs rebuilding |

## Platforms and apps

| Doc | Covers |
| --- | --- |
| `ios-architecture.md` | iOS app structure, scene, daemon-in-process |
| `mac-architecture.md` | macOS app structure, daemon subprocess |
| `native-architecture.md` | Native-SDK (web-content) shell |
| `idfon-web-analysis.md` | viewing P2P pages in `WKWebView` (`idfon:` scheme vs local proxy), TLS/WebMCP/security notes (as-built analysis; resolved by the hybrid transport) |
| `idfon-edge.md` | public `idfon.net` gateway + on-device adapter + P2P backbone (as-built; P0–P6 landed; public edge on a DigitalOcean droplet + co-located relay; residual issues #27–#29) |
| `callkit-integration.md` | CallKit + incoming-call presentation (iOS) |
| `live-activity-bar-layout.md` | live-call bar UIKit layout |
| `ios-ui-design.md` | structural UX design for the iOS app (tabs, rows, chat timeline, sessions, identity) — design, for implementation |
| `ui-design-notes.md` | UX/visual system spec (live activity bar, session tray) |
| `custom-app-launch.md` | launching a custom idfon app |

## Networking, addressing, transport

| Doc | Covers |
| --- | --- |
| `idfon-gateway.md` | `idfon://` addressing, loopback gateway, HTTP/3 provider |
| `multi-device.md` | one account across devices (design) |
| `relay-auth.md` | relay access: identity→relay claiming, caller-bound grants, relay-issued owner/non-owner tokens, revocation (as-built for the auth service + grant contract + daemon owner-side auto-enrollment) |
| `relay-test-plan.md` | hand-off test plan for relay auth: L0–L3 cases, pass criteria, known gaps, rollback |
| `chatrooms.md` | rooms, direct fan-out, gossip |
| `mcp-transport.md` | idfon as an MCP transport binding (implemented) |

## CLI and distribution

| Doc | Covers |
| --- | --- |
| `cli-architecture.md` | CLI shape + npm packaging |
| `cli-data.md` | `put`/`get`/`send-data`, live streaming |
| `npm-distribution.md` | npm packages and the publish gate |

## Media

| Doc | Covers |
| --- | --- |
| `audio-media.md` | audio capture/playback status; the single in-app audio owner (`AudioIO`: one mic tap + one playback bus, one session), the capture-ownership rule |
| `video-media.md` | video capture/encode status |
| `media-adapter-seam.md` | `video-frame.jpg` polling, seams, bundled playback |

## Artifacts and agents

| Doc | Covers |
| --- | --- |
| `idfon-artifacts.md` | artifact model, references, remote view, voice/spoken projection, accessibility |
| `idfon-artifacts-testing.md` | manual artifact/reference test runbook |
| `idfon-eve.md` | idfon as an Eve ingress channel (implemented) |
| `live-voice.md` | the voice agent built on the Eve channel; transport + front-end decision |
| `voice-agent.md` | voice agents that speak/listen for other agents (wrapped / injected) |
| `voice-agent-modes.md` | on-device vs passive-remote vs proxy, and where the latency goes |
| `voice-prompt-lab.md` | iterate voice-agent prompts headlessly (`scripts/voice-prompt-lab.sh`, scoring + variants) |
| `reply-blocks.md` | what a reply is: the named block set (`Text`/`Speak`/`Artifact`/`View`/`JsonRender`/`Reference`/`Unparsed`) over the `IDFON-*/1` envelopes, ids and replacement, fail-open parsing, render-spec limits, where each piece lives (as-built) |
| `voice-multimodal.md` | the voice turn contract: text + `IDFON-*/1` envelopes + attachment; references, camera input (per-contact capability), client-facing tools (`speak`/`point`/`show`) via the outbox, output split, full-duplex gap (design) |
| `voice-side-channel.md` | shared voice service: requirements, STT/TTS candidates, plan (P0–P7 implemented; A1 client cascade integrated on iOS/macOS — iOS Kokoro/Parakeet seams, call cues, greet-on-connect, `· spoken` chat turns); the text-only `llm` agent and per-run model selection for agency contacts |
| `voice-agent-prompting.md` | source notes on voice-agent prompt engineering: prompt structure, output rules, guardrails, tools, voice realism, testing; idfon use-case implications; frontier-lab voice prompting (research for a future skill) |
| `voice-multichannel.md` | one result, many channels: modality vs channel, emotes (texturized non-verbal events), call-assist agents, hybrid fan-out, layered authorization, idfon primitives, open decisions (design) |
| `voice-decisions.md` | decision points in the voice setup, fine-tuned decision models (on-device + remote), per-user training data, authority and guardrails (design) |
| `voice-agent-harness.md` | research notes on the agent loop/harness: requirements (on-device + remote, subagents, decision models as tools), pi-agent-core shape, open-source candidates (yoagent, io-harness, fx, AFM harnesses); decision (adopt yoagent) + open items |
| `voice-agent-loop-contract.md` | the portable loop contract: prompt sections, tool schemas (canonical JSON), and the trace record shared by the on-device and remote tiers (design) |
| `agent-agency.md` | the `agency` go-between that introduces registered agents (A2A card relay, `IDFON-INVITE/1`; cards are target-signed, only the reply credential is agency-signed) |
| `session-context.md` | session as the medium for a shared virtual context edited by user, voice agent, and target agents; no chat-as-context, no recall (design) |

## Operations

| Doc | Covers |
| --- | --- |
| `troubleshooting.md` | known issues, diagnoses, fixes |
| `observability.md` | unified telemetry: shared subscriber, structured fields, `trace` correlation, opt-in OTLP, the external-agent seam (as-built; open items in §10) |
| `benchmarks.md` | repeatable latency measurement as a pure-TS vertical: the bench Eve agent (`agents/bench`) + `scripts/relay-bench.sh` (relay A/B over the daemon stack, JSONL history) + `scripts/voice-latency-report.sh` (voice-turn stages) |
| `dylib-refactoring-plan.md` | shared-dylib build as-built + follow-up log |