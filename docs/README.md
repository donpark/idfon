# Idfon docs index

**Read this first, then open only the files you need.** Do not bulk-read `docs/`
— most questions touch one or two entries below.

Status legend: **current** = describes the code as it is; **as-built** = a plan
kept because it records decisions; **design** = not all implemented.

## Orientation

| Doc | Covers | Read when |
| --- | --- | --- |
| `communication-model.md` | identities, peers, messages, grants | anything about the core model |
| `daemon.md` | why there is a daemon at all; the daemon as packaging of the feature functions | questioning the process model |
| `protocol.md` | daemon JSON IPC methods/params | adding/changing an RPC or a client |
| `interaction-parameters.md` | CLI vs GUI responsibility split | where a policy/feature belongs |
| `build.md` | which subprojects to rebuild after a change; the Rust/FFI target dirs; `pnpm build`/`pnpm voice build` orchestration; build-time options (`IDFON_TTS_PHONON`) | touching a shared crate or the c-ffi crate, unsure what needs rebuilding, building/cleaning everything, or toggling a build-time option |

## Platforms and apps

| Doc | Covers |
| --- | --- |
| `ios-architecture.md` | iOS app structure, scene, embedded feature core | 
| `mac-architecture.md` | macOS app structure, daemon subprocess |
| `native-architecture.md` | Native-SDK (web-content) shell |
| `idfon-web-analysis.md` | viewing P2P pages in `WKWebView` (`idfon:` scheme vs local proxy), TLS/WebMCP/security notes (as-built analysis; resolved by the hybrid transport) |
| `idfon-edge.md` | public `idfon.net` gateway + on-device adapter + P2P backbone + VoIP push channel (as-built; P0–P7 landed; public edge on a DigitalOcean droplet + co-located relay; residual issues #27–#29) |
| `edge-deploy-checklist.md` | the CallKit test rig (local edge + app config), session teardown (`scripts/e2e-teardown.sh`), droplet deploy incl. the APNs push wiring (#54) |
| `callkit-integration.md` | CallKit + incoming-call presentation; as-built + plan (P0–P2 landed incl. mac ring sender, iOS 26.4 wake requirement; P3 macOS LiveCommunicationKit deferred) |
| `contact-exchange.md` | vCard contact cards: the NameDrop substitute, `idfon://add/` deep links, QR, import/export surfaces |
| `live-activity-bar-layout.md` | live-call bar UIKit layout |
| `ios-ui-design.md` | structural UX design for the iOS app (tabs, rows, chat timeline, sessions, identity) — design, for implementation |
| `ui-design-notes.md` | UX/visual system spec (live activity bar, session tray) |
| `custom-app-launch.md` | launching a custom idfon app |
| `app-icon.md` | the app icon: final neu-neutral design, iOS/macOS asset wiring, the mask + retint pipeline for recoloring the handset (as-built) |

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
| `cli-architecture.md` | CLI shape + npm packaging; contact vCards |
| `cli-data.md` | `put`/`get`/`send-data`, live streaming |
| `npm-distribution.md` | npm packages and the publish gate |
| `testflight-plan.md` | iOS TestFlight: **how to ship an update** (`pnpm ios ship`), upload blockers (app icon, privacy manifest), archive/upload plumbing, ASC-side setup, review-risk audit (2026-10-17 review) |

## Media

| Doc | Covers |
| --- | --- |
| `audio-media.md` | audio capture/playback status; the single in-app audio owner (`AudioIO`: one mic tap + one playback bus, one session), the capture-ownership rule; macOS echo reference (call audio on `AudioMeter`'s engine + voice processing, `IDFON_MACOS_AEC`) |
| `video-media.md` | video capture/encode status |
| `stereo-calls.md` | stereo (2-channel) calls: why phone infra can't retrofit them, the FFI/Swift plumbing and the panel's media row (Built-in/Earphone/Speaker/Mute radio + Stereo toggle) + stereo voice messages — as-built end to end; the device E2E pass remains |
| `media-adapter-seam.md` | `video-frame.jpg` polling, seams, bundled playback / shell playback callback |
| `media-adaptation.md` | live-call robustness: VoIP field knowledge (jitter buffers, Opus FEC/DTX/ABR, GCC/SCREAM, Wi-Fi↔cellular handover, burst/gap loss metrics), our MoQ/iroh stack reviewed against it (what `adaptive.rs`/`NetworkSignals`/moq knobs already cover vs gaps), dynamic demand-based media configuration (profile + policy layer), prioritized test/change list |

## Artifacts and agents

| Doc | Covers |
| --- | --- |
| `idfon-artifacts.md` | artifact model, references, remote view, voice/spoken projection, accessibility |
| `idfon-artifacts-testing.md` | manual artifact/reference test runbook |
| `idfon-eve.md` | idfon as an Eve ingress channel (implemented) |
| `live-voice.md` | the voice agent built on the Eve channel; transport + front-end decision |
| `voice-agent.md` | voice agents that speak/listen for other agents (wrapped / injected); the governing architecture: one process by default (the iPhone shape), seams over processes (voice pipe / cascade / wrap), bridge→library refactor (design) |
| `voice-agent-modes.md` | on-device vs passive-remote vs proxy, and where the latency goes |
| `voice-fast-track.md` | **fast-track** voice agents: the device runs ASR + TTS + tyger-class turn decisions (voice in → text + turn metadata, text out → voice), agents — on- or off-device — implement only interaction heuristics; turn reactions are always local, only content may be remote; remote/hybrid engines remain per-contact choices (design statement) |
| `tyger-models/` | the HuggingFace repo root for `donpark/tyger-models`: `README.md` (model card — what's in the repo, the `pathc/` TYGER-Step-Student contract/training/eval, delivery manifest), `LICENSE.md` (OpenMDW-1.1 + coverage table) and `NOTICE.md` (provenance; form follows `nineninesix/tyger`) |
| `voice-prompt-lab.md` | iterate voice-agent prompts headlessly (`scripts/voice-prompt-lab.sh`, scoring + variants) |
| `reply-blocks.md` | what a reply is: the named block set (`Text`/`Speak`/`Artifact`/`View`/`JsonRender`/`Reference`/`Unparsed`) over the `IDFON-*/1` envelopes, ids and replacement, fail-open parsing, render-spec limits, where each piece lives (as-built) |
| `voice-multimodal.md` | the voice turn contract: text + `IDFON-*/1` envelopes + attachment; references, camera input (per-contact capability), client-facing tools (`speak`/`point`/`show`) via the outbox, output split, full-duplex gap (design) |
| `voice-side-channel.md` | shared voice service: requirements, STT/TTS candidates, plan (P0–P7 implemented; A1 client cascade integrated on iOS/macOS — iOS Kokoro/Parakeet seams, call cues, greet-on-connect, `· spoken` chat turns); on-device TTS engines (Kokoro default, Pocket + Phonon options); the text-only `llm` agent and per-run model selection for agency contacts |
| `voice-agent-prompting.md` | source notes on voice-agent prompt engineering: prompt structure, output rules, guardrails, tools, voice realism, testing; idfon use-case implications; frontier-lab voice prompting (research for a future skill) |
| `voice-multichannel.md` | one result, many channels: modality vs channel, emotes (texturized non-verbal events), call-assist agents, hybrid fan-out, layered authorization, idfon primitives, open decisions (design) |
| `voice-decisions.md` | decision points in the voice setup, fine-tuned decision models (on-device + remote), per-user training data, authority and guardrails (design) |
| `voice-tyger.md` | adopting tyger-s2s's way of working wholesale in the eve voice agent: what idfon keeps (carrier, tools/outbox, record), the `nineninesix/tyger` turn-taker + rules, EARS/MOUTH wire, two adoption shapes (scaffolding history — the model now runs in-process in the eve TS agent), P0 gate, measurement (as-built) |
| `voice-tyger-ondevice.md` | on-device port: the **tier state** (path-C student 56 MB shipping first on all platforms — 2026-10-22; fallbacks: OS 27+ = CoreAI fp16, pre-27 mac = MLX int8-g16, pre-27 iOS = CoreML fp16/ANE — guard numbers per tier), the decision-path anatomy (397M of 652M), the incremental KV-cache lever, per-head precision acceptance, the dated rulings (as-built) |
| `voice-tyger-streaming-plan.md` | the transition to full-streaming ASR + TTS for Tyger's model requirements: three streaming legs (Nemotron streaming ASR + L15 tap, chunked agent-text→TTS, Phonon streaming mouth), phases 1–4 with gates (ANE 1×RT, drift parity ≥99%, ≤1.5s turn-to-first-audio), the 2026-10-22 A/B evidence, the parked decisions, and the 2026-10-25 fully-duplex voice-agent ruling (Nemotron ASR + Tyger turn management + Phonon mouth; off-device agent next, core stays tier-neutral) (plan) |
| `voice-tyger-s2s-comparison.md` | one-shot audit of the tyger-s2s implementation vs ours: rules verified-equal, threshold drift (their live tuning: ep 0.915 / barge 0.4 / bc 0.4), the 2nd-ear arrival-order error class (their I-17 fix), barge `played_s` history trim, the chunker spec, contextual backchannels, and the EARS↔MOUTH wire vocabulary to reuse for the off-device agent (reference) |
| `../corpus/voice-interactions/` | replayable voice-interaction corpus (Dessa demos + tyger demo): clean timed speaker-attributed transcripts + `-tygerdemo` replay scripts, no audio (recreated from timings — copyright-safe); the regression hedge for voice-agent changes, HF dataset planned |
| `voice-tyger-option.md` | the tyger option: `classic` (today's turn-taking, the fallback) vs `tyger` (the model as turn-taker), selection + fail-open semantics, rollout P0–P3 incl. "our own model improves classic" (design) |
| `voice-agent-harness.md` | research notes on the agent loop/harness: requirements (on-device + remote, subagents, decision models as tools), pi-agent-core shape, open-source candidates (yoagent, io-harness, fx, AFM harnesses); decision (adopt yoagent) + open items |
| `voice-agent-loop-contract.md` | the portable loop contract: prompt sections, tool schemas (canonical JSON), and the trace record shared by the on-device and remote tiers (design) |
| `agent-agency.md` | the `agency` go-between that introduces registered agents (A2A card relay, `IDFON-INVITE/1`; cards are target-signed, only the reply credential is agency-signed) |
| `session-context.md` | session as the medium for a shared virtual context edited by user, voice agent, and target agents; no chat-as-context, no recall (design) |

## Operations

| Doc | Covers |
| --- | --- |
| `troubleshooting.md` | known issues, diagnoses, fixes |
| `observability.md` | unified telemetry: shared subscriber, structured fields, `trace` correlation, opt-in OTLP, the external-agent seam (as-built; open items in §10) |
| `diag.md` | `IDFON-DIAG/1` app diagnostics over iroh: protocol, app reporter, the `monitor` filing agent, query examples (issue #63) |
| `benchmarks.md` | repeatable latency measurement as a pure-TS vertical: the bench Eve agent (`agents/bench`) + `scripts/relay-bench.sh` (relay A/B over the daemon stack, JSONL history) + `scripts/voice-latency-report.sh` (voice-turn stages) |
| `disk-hygiene.md` | the ANE/CoreAI compile leftovers (scratch workdirs, coreai-cache registrations, daemon caches): the mechanism, `pnpm ane list`/`pnpm ane clean` usage, the output contract for scripts and agents, the flush experiment |
| `dylib-refactoring-plan.md` | shared-dylib build as-built + follow-up log |