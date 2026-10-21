# The tyger option: `classic` vs `tyger` turn-taking

**Status: design (the plan).** Adds `tyger` as an opt-in turn-taking behavior
for the voice agent, and sets today's on-device voice-agent behavior aside as a
named mode, **`classic`**. Classic is not deprecated: it is the mode used
whenever tyger is not available, it is the only mode with no model dependency,
and it is where **our own model** improves things when it is ready.

Companion docs: `voice-tyger.md` (why tyger's way of working was adopted),
`voice-tyger-ondevice.md` (the model port tiers — the "our own model" path),
`voice-agent-modes.md` (on-device vs passive-remote vs proxy — a different
axis; this doc is about *how turns are decided*, not where the loop runs).

## The two options

| Option | Turn decisions | Where it runs today | Posture |
| --- | --- | --- | --- |
| **classic** | the current behavior: energy endpointing (`\|s16\| > 300`, 800 ms quiet tail) in the remote engines; the Segmenter's 1.2 s no-change commit on-device; greet-on-connect, call cues | remote `live-relay.mjs`; the iOS and mac apps | **the guaranteed fallback** and the improvement target for our own model |
| **tyger** | the `nineninesix/tyger` decision model as the turn-taker: per-frame ENDPOINT / BARGE / BACKCHANNEL scores + the tyger rules (warmup, MIN_SPEECH, debounce, backchannel refractory) | remote `live-relay.mjs` (the TS chain in-process: `integrations/eve-idfon-voice/src/tyger/`, bundle verified at `~/.idfon/models/tyger`) | opt-in; wired and gated (below) |

"Classic" names the behavior we already ship. It keeps its UX (greetings, call
cues, chat turns); what improves over time is its *decisions*.

## Selection semantics

- **One knob**: `turn_taker: auto | classic | tyger` (env `IDFON_TURN_TAKER`),
  default **`auto`**, with a per-contact override in the contact detail screen
  ("Voice turns", next to the existing Mode row).
- **`auto` resolves per call**: tyger when its model is available and verified
  (bundle present, checksums pass, runtime loads) — classic otherwise. Classic
  is always available; it has no model dependency.
- **Fail-open, always**: any tyger runtime failure (missing/corrupt bundle,
  inference error) drops that call to classic and logs it. A call is never
  blocked by the model. This is already implemented in `live-relay.mjs`
  (`IDFON_ENDPOINTER=energy` is the explicit classic opt-out; it maps onto
  `IDFON_TURN_TAKER=classic` in this plan's naming).
- **Recorded**: the active option is written into the loop-contract trace per
  turn (`turn_taker: classic|tyger`) so decision-log diffs and
  `IDFON-CALL/1` transcripts are unambiguous about which layer decided.

## As-built (2026-10-19/20), for the tyger side

- **TS decision chain** (`integrations/eve-idfon-voice/src/tyger/`): mel
  front-end, feed loop (`TygerEngine`), rules (`TurnSession`), bundle loader,
  endpointer, language knob, shadow collector. In-process in Node via
  onnxruntime-node — no Python in the loop.
- **Gates**: rules byte-identical to the Python oracle (turns fixtures);
  composed chain max|Δ| 1.4e-5 vs the torch oracle; **99.89% decision
  agreement** (916/917, ±2 frames) over 72 min of the `dualturn-otospeech`
  corpus vs the fp32 oracle (one backchannel flip at a 0.50 threshold
  boundary); tests 10/10.
- **Bundle**: `ports/tyger-onnx/pack-bundle.mjs` → `~/.idfon/models/tyger/`
  (manifest with sha256 per file; `url_base` is the seam for a download host).
- **Reference harness**: tyger-s2s adapted (`config/idfon.yaml`) — the oracle
  and behavior yardstick, not the product runtime.
- **Language**: `IDFON_VOICE_LANG` (BCP-47) → STT language hint today; ASR
  prompt ids ready for the bundle's RNN-T when it joins the chain.

## The plan

**P0 — name and expose the options.** `IDFON_TURN_TAKER` / per-contact
override / trace field. Map the existing `IDFON_ENDPOINTER` env onto it. Small
config plumbing; no behavior change (default `auto` resolves to tyger only on
engines that have the bundle).

**P1 — classic stays clean.** Regression-check the classic path on every
engine and both apps with no bundle present (it must be byte-for-byte today's
behavior). Classic keeps greet-on-connect and call cues unchanged.

**P2 — tyger earns the default on the remote engine.** Gate: live E2E through
`live-relay.mjs` (in progress) plus real-call decision-log diffs from the
shadow collector against classic's turns. Then `auto` resolves to tyger on the
remote engine. MOUTH behaviors (clause/sentence chunking into TTS, tool
lead-ins, barged rounds trimmed to what the caller heard, backchannels never in
history) land incrementally in the agent's turn pipeline — tyger option first,
classic folds in the ones that are pure wins.

**P3 — our own model improves classic.** The on-device port (Swift
`TurnEngine` + the CoreML/CoreAI/MLX tiers in `ports/tyger-swift`) — or a model
we train ourselves — becomes the decision layer *behind classic* on-device:
classic's behavior contract stays (greetings, cues, chat turns), its endpointing
and barge decisions get the model's quality. Acceptance is the decision guard
(≥99% agreement, parity7-style) plus the per-tier envelopes recorded in
`voice-tyger-ondevice.md`. On-device `auto` then resolves to the model-backed
classic; the tyger option remains for callers/hosts that want the tyger
bundle's exact behavior.

## Open decisions

- UI naming: one "Turn model: Classic / Tyger" row vs a "Tyger turn-taking"
  toggle.
- Bundle hosting (the manifest `url_base`): resolved for the Swift tiers
  (2026-10-21) — download-on-first-use from the **`donpark/tyger-models`
  HuggingFace repo** (`scripts/pack-tyger-models.mjs` packs/pins;
  `TygerModelStore` fetches per-device tier; the `tyger-models-v1` GitHub
  release is a mirror). The ONNX bundle host is still open.
- Whether MOUTH behaviors land per option or are folded into classic as they
  prove out (the plan assumes: tyger first, fold in pure wins).
- Backchannel *speak* behavior (the model can request "mm-hm") needs the TTS
  seam and playback control; until then BARGE/BACKCHANNEL are decided and
  logged but only ENDPOINT commits turns.
