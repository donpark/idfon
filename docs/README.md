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

## Platforms and apps

| Doc | Covers |
| --- | --- |
| `ios-architecture.md` | iOS app structure, scene, daemon-in-process |
| `mac-architecture.md` | macOS app structure, daemon subprocess |
| `native-architecture.md` | Native-SDK (web-content) shell |
| `callkit-integration.md` | CallKit + incoming-call presentation (iOS) |
| `live-activity-bar-layout.md` | live-call bar UIKit layout |
| `ui-design-notes.md` | UX/visual system spec |
| `custom-app-launch.md` | launching a custom idfon app |

## Networking, addressing, transport

| Doc | Covers |
| --- | --- |
| `idfon-gateway.md` | `idfon://` addressing, loopback gateway, HTTP/3 provider |
| `multi-device.md` | one account across devices (design) |
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
| `audio-media.md` | audio capture/playback status |
| `video-media.md` | video capture/encode status |
| `media-adapter-seam.md` | `video-frame.jpg` polling, seams, bundled playback |

## Artifacts and agents

| Doc | Covers |
| --- | --- |
| `idfon-artifacts.md` | artifact model, references, remote view |
| `idfon-artifacts-testing.md` | manual artifact/reference test runbook |
| `idfon-eve.md` | idfon as an Eve ingress channel (implemented) |
| `live-voice.md` | the voice agent built on the Eve channel; transport + front-end decision |
| `voice-agent.md` | voice agents that speak/listen for other agents (wrapped / injected) |
| `voice-side-channel.md` | shared voice service: requirements, STT/TTS candidates, plan (P0–P7 implemented; A1 client cascade integrated on iOS/macOS — iOS Kokoro/Parakeet seams, call cues, greet-on-connect, `· spoken` chat turns); the text-only `llm` agent and per-run model selection for agency contacts |
| `agent-agency.md` | the `agency` go-between that introduces registered agents (A2A card relay, `IDFON-INVITE/1`; cards are target-signed, only the reply credential is agency-signed) |

## Operations

| Doc | Covers |
| --- | --- |
| `troubleshooting.md` | known issues, diagnoses, fixes |
| `observability.md` | unified telemetry: shared subscriber, structured fields, `trace` correlation, opt-in OTLP, the external-agent seam (as-built; open items in §10) |
| `dylib-refactoring-plan.md` | shared-dylib build as-built + follow-up log |