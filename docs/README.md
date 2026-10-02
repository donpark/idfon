# Idfon docs index

**Read this first, then open only the files you need.** Do not bulk-read `docs/`
— most questions touch one or two entries below. `docs/archive/` is historical
design lineage; skip it unless you are reconstructing *why* something is the way
it is.

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
| `ai-voice-chat.md` | the voice agent built on the Eve channel; transport + front-end decision |
| `voice-side-channel.md` | shared voice service: requirements, STT/TTS candidates, plan (P0–P5 service core implemented) |

## Operations

| Doc | Covers |
| --- | --- |
| `troubleshooting.md` | known issues, diagnoses, fixes |
| `dylib-refactoring-plan.md` | shared-dylib build as-built + follow-up log |

## Archive (`docs/archive/`)

Historical research, pre-implementation plans, and designs that were
superseded. Read only to reconstruct lineage; not maintained against the code.

| Doc | Original purpose |
| --- | --- |
| `architecture-plan.md` | early whole-system implementation plan |
| `idfon-http-routing.md` | `idfon://` resource-routing research Q&A |
| `mcp-agent-report.md` | MCP/agent design findings |
| `mcp-implementation-plan.md` | MCP M1–M5 plan |
| `agent-conversation-plane.md` | generic agent bridge (superseded by Eve) |
| `idfon-eve-implementation-plan.md` | Eve endpoint-holder plan |
| `idfon-eve-celld.md` | idfon as a celld ingress adapter (design) |
| `multi-device-implementation-plan.md` | multi-device rollout plan |
| `native-shells-plan.md` | native shell rollout plan |
| `quic-proxy.md` | WebTransport-to-iroh local proxy research |
| `iorh-vs-ll-hls.md` | Iroh vs LL-HLS broadcast comparison |
| `iroh-rendezvous-url.md` | URL-as-rendezvous patterns |
| `call-machine.md` | planned CallMachine refactor (not started) |
| `major-crate-upgrade-handoff.md` | one-off dependency-upgrade handoff |