# TYGER as the voice layer

Status: **P0a implemented (2026-10-18); P0b (the gate) waits on a GPU box.** Premise: adopt
[tyger-s2s](https://github.com/nineninesix-ai/tyger-s2s)'s way of working **as a whole**
for the eve-format voice agent — its turn-taker, its turn pipeline, its behaviors — keeping
only what is idfon-specific. Gate on evidence: if P0 replay shows it does **not** work as
advertised on our calls, we keep our thresholds and only steal the behaviors.

Companion to `docs/voice-decisions.md` (the decision inventory this replaces at runtime),
`docs/voice-agent.md` (the eve voice agent's backends and routing),
`docs/voice-agent-loop-contract.md` (the shared trace), `docs/voice-agent-modes.md`.

## Verdict: what is worth keeping

tyger-s2s is a complete voice agent for a browser. Three idfon layers have no counterpart
in it and are the product surface — keep them, and replace everything else:

| Keep | Why |
| --- | --- |
| **The idfon carrier** — peer identity, capability tickets, `IDFON-LIVE/1` over the live media transport (24 kHz PCM caller audio + return leg), `IDFON-DATA/1`/`IDFON-RECORDING/1`, push wake | it is how humans and agents reach the agent at all; tyger-s2s speaks only its own `/ws` to a browser |
| **The tool/outbox layer** — `agents/voice` tools (`voice_forward` to wrapped agents, `speak`/`point`/`show` envelopes), A2A wrapped agents, the agency | this is what an idfon voice agent *is*. tyger-s2s's tools are placeholders (`set_reminder`, `send_message` stubs) plus an "ask the expert" escalation |
| **The durable record** — `IDFON-CALL/1` transcripts, the record buffer, `docs/voice-agent-loop-contract.md` trace | nothing equivalent there; our observability and later fine-tuning data depend on it |

Everything else in our voice loop is replaceable by theirs, and theirs is better thought
through: the endpointer/barge-in/backchannel machinery (`Endpointer`, `BargeInController`,
`caller_decision`, text-level `EchoSuppressor`) goes away in favor of the TYGER decision
model + its rules; the `cascade.rs` run-loop state machine becomes their turn pipeline
(MOUTH: clause/sentence chunker, announcement turns before tools, backchannel channel
"never remembered", barged rounds trimmed to what the caller heard, history turns marked).
`StreamingSpeaker`'s clause batching is the one behavior we already share.

## What tyger-s2s is

Two processes on one GPU:

- **EARS** — streaming ASR plus the turn-taker. It transcribes the caller and decides
  *when to answer, when to yield to an interruption, and when to say "mm-hm"*. It also
  hears the agent's own voice so the agent's echo in the mic is not mistaken for the caller.
- **MOUTH** — the reply: an LLM writes it, TTS speaks it one clause/sentence at a time,
  with a short spoken line before tool use ("Checking the time in Tokyo"). A barge-in stops
  the reply at once and **keeps only what the caller heard**. Backchannels are spoken but
  never enter history.

Its wire is worth copying as the internal contract (`app/wire.py`): user turn `T`,
backchannel request `C`, barge `B` carrying `played_s`, reply audio `A` vs backchannel
audio `K` kept apart, done `D` with `barged`/`bc`/`proactive` flavors.

## The model (`nineninesix/tyger`)

| | |
| --- | --- |
| Speech recognition | NVIDIA Nemotron 3.5 ASR Streaming 0.6B, **frozen, bundled** |
| Turn-taker | causal GRU, 3 layers × 768, 14M params (652M total, FP32, 2.61 GB) |
| Input | two aligned mono 16 kHz streams: the caller's mic and the agent's playback |
| Features | Nemotron layer 15 (1,024 dims), 1 frame / 80 ms, no lookahead |
| Streaming | 320 ms hops; Nemotron re-encodes an 8 s window per stream each hop |
| Output, per frame | turn state (listen/hold/speak/backchannel) + hazard, barge-in, backchannel, endpoint scores |
| State per call | 9 KiB GRU state; the state input is the app's LISTEN/SPEAK, never the model's guess |
| Language | English. Speed: GRU 0.805 ms/frame (RTX 4090); whole model ~4 GB VRAM per 4 conversations |

Events and the shipped rules (`tyger-s2s/app/plugins/ears/tyger/rules.py`):

| Event | Score default | Fires when | App does |
| --- | ---: | --- | --- |
| Endpoint | `ep_thr` 0.91 | `p_end` ≥ thr for `ep_deb` frames, once ≥ 350 ms voiced speech (above −50 dB) | answers |
| Barge-in | `barge_thr` 0.50 | yield ≥ thr for `barge_deb` frames while speaking; carries `onset_s` (what the caller had heard) | stops the reply, trims history |
| Backchannel | `bc_thr` 0.40 | bc head fires for `bc_deb` frames, then 1.2 s without another | speaks a "mm-hm"; caller keeps the floor |

Guards live in code, not the model: 6 warm-up frames after reset; the 350 ms voiced-speech
minimum; a 1.2 s backchannel gap; and a silence fallback endpoint after 1.2 s (tyger-s2s
leaves the bundle's own fallback off and keeps the rule in `rules.py`). Thresholds are
deliberately loose and tuned live with sliders.

Model quality to set expectations (its own evaluation, Open Yap 1K test): endpoint median
252.5 ms / mean 465 ms after turn end, 29.9% early cut-ins, 7.4% of turns missed within
1.2 s; barge-in median delay 400 ms, only 25% caught within 640 ms, 0 false barge-ins in
4.72 h; backchannel AP 0.30 (imprecise), 135 fired per hour of listening. One training
seed, English only, **no live voice-agent benchmark** — "works as advertised" is exactly
what P0 must establish on our own audio.

## Adoption: two shapes

The `/ws` protocol (their `README.md` → "The protocol") is small binary framing and is
the Shape 1 contract:

- mic → tyger: `[i32 reply id][i32 reply sample or -1][i16 mic @16 kHz]`, 20 ms blocks.
  The tag **is** the second ear: the reply sample (24 kHz) the caller was hearing when the
  block started, or −1 when nothing played.
- tyger → speaker: `[i32 reply id][i16 @24 kHz]`; id 0 is a "mm-hm" — play it, never tag it.
- text: `played:<id>:<samples>` when a reply has finished playing (ends the agent's turn),
  plus `reset`, `voice:<name>`, `set:<threshold>:<value>` (runtime threshold tuning).
- JSON out: `ready`, `state`, `partial`, `endpoint` (with `transcript`), `reply`, `backchannel`,
  `backchannel_done`, `barge`, `turn_done`, `task_done`, `session_end`. On `barge` the client
  must stop playing the reply at once.

**Shape 1 — run tyger-s2s as-is, bridge the idfon call to it.** The eve voice agent
becomes a thin adapter: caller audio (resampled 24 k→their wire) into `/ws`, their reply
audio back to the return leg, tokens per their API-mode JWT scheme. Fastest way to *hear*
the whole thing (turn-taking, mm-hm, preambles, barge trimming) with zero porting. What
we give up in this shape: the reply is Gemma 4 E4B with their stub tools — no idfon tools,
no wrapped agents, no record/trace beyond what the adapter can scrape from the WS events.
Fine for a demo; not the end state.

**Shape 2 — adopt their organization, keep the idfon carrier.** Port the EARS/MOUTH split
onto the seams we keep:

- **EARS** = the TYGER bundle behind a tiny sidecar WS (PyTorch, FP32/TF32-off, CUDA; the
  runtime to wrap is `tyger-s2s/app/plugins/ears/tyger/`: `bundle.py`, `asr.py`/`rnnt.py`,
  `controller.py`, `gru_batch.py`, `rules.py`). The holder feeds it the two aligned 16 kHz
  streams — caller audio from `subscribe_caller`, and the TTS PCM on the return leg as the
  second ear (their `AgentPlayback` is the same idea from the browser's playback clock).
  Decisions come back per frame; `rules.py`'s guards are re-implemented in Rust next to the
  client so a dead sidecar never blocks a call (fail open to the energy endpointer —
  `docs/voice-decisions.md` guardrails: propose, do not authorize).
- **MOUTH** = their turn pipeline around the existing agent loop: the clause/sentence
  chunker feeding TTS, announcement turns before tool rounds, a backchannel channel that
  never enters history (`IDFON-SPEAK/1` gains a `backchannel`/`proactive` flavor), barged
  rounds trimmed to `played_s`/`heard_until`, history turns marked. The Eve agent keeps
  its model and tools — that is the one substitution tyger-s2s would not give us.
- **Their wire as the internal contract** between the two halves, so a Shape 1 stack and a
  Shape 2 stack are interchangeable.

Recommendation: **P0 is Shape 1** (it is also the "works as advertised" gate); **the end
state is Shape 2**. Do not port MOUTH behaviors before the gate — if the turn-taker is
worse than our thresholds on our audio, the behaviors can be copied without the model.

## Where the model runs

Everything is self-hosted: `nineninesix/tyger` is open weights (OpenMDW 1.1) on Hugging
Face — no nineninesix service, no API. "The tyger-s2s stack" throughout this doc means
their two processes (EARS + MOUTH, Apache-2.0) running on infrastructure we control.
The constraint is their runtime (PyTorch/CUDA), not the model's size: the 652M bundle
(~1 GB int8) is small enough to ship in the app and even on iPhone — porting Nemotron +
the GRU to Core ML / MLX is the cost. Options:

| Option | Verdict |
| --- | --- |
| GPU sidecar (RunPod/Docker, the pattern tyger-s2s itself documents) | **take this** for both shapes |
| In-process Rust | no runtime exists; porting Nemotron is a project of its own |
| MLX/CoreML port | later, only if the experiment wins *and* we want it in the on-device tier |

## Measuring it

A/B harness (2026-10-18, runs on the Mac against the real bundle via `ReferenceEars`):
`scripts/tyger-replay.py` (one recording → decisions + transcripts), `scripts/tyger-ab.py`
(synthesized corpus with known turn boundaries + the energy baseline ported from
`live-relay.mjs`, `--ep-thr` sweeps the endpoint threshold). First results on **synthetic**
material (`say` phrases, room-tone pauses; 4 turns — indicative only):

| | clean-turn latency | intra-turn pauses |
| --- | --- | --- |
| energy baseline | +0.60 s (its 0.8 s quiet tail) | cuts in at every pause > 0.8 s (2/2) |
| TYGER @ 0.91 (shipped) | **+0.36 s** | 3/4 turns missed: p_end saturates ~0.85–0.88 on noisy pauses and never crosses |
| TYGER @ 0.85 | +0.36 / +1.19 s | catches all, cuts in at both pauses (2/2) |

What this says so far: TYGER's clean-endpoint speed is real (the model card's ~250 ms
median reproduced on synthetic audio); its pause behavior could not be judged on this
corpus — p_end's sensitivity to pause acoustics (digital silence vs room tone moved it from
0.95 to 0.85) means **the gate must run on real call recordings** with real hesitations,
more turns, and a threshold sweep. Synthetic `say` prosody is not conversational speech.

Metrics, on the model card's definitions, so numbers compare:

- endpoint latency median/mean after turn end; early cut-ins; turns missed within 1.2 s;
- barge-in catch rate and delay, false barge-ins per hour of clean speech — **the first
  number to watch**, since tyger trades echo robustness for their heads (their ISSUES I-26)
  and our second ear is *sent* audio, not what the speaker played;
- backchannels per hour, and whether callers talk over them;
- turn-level: does the reply start earlier without cutting callers off more?

## Milestones

- **P0a — done (2026-10-18).** `integrations/eve-idfon-voice/tyger-relay.mjs` (+
  `scripts/tyger-live-relay.sh`, `agents/voice/tyger.json`), smoke-tested against the fake
  stack (`--smoke in.wav --out out.wav`): tagged mic blocks, `played:` accounting (a
  barged turn correctly never reports played), `barge`/`endpoint` handling, audio both
  ways. Not yet exercised: the bridge mode (needs a served agent and a live call) and
  real playhead tags (`TYGER_TAG_LAG_MS` is the fixed-lag stand-in).
- **P0b — the gate, split (2026-10-18: the decision half needs no GPU).**
  - **P0b-i (done on the Mac, CPU):** `scripts/tyger-replay.py` drives the real bundle
    through tyger-s2s's own `ReferenceEars` (their `scripts/validate/reference.py`; same
    `rules.py` as the live engine) — real Nemotron transcripts, head-fired endpoints with
    the guards behaving (p_end high in silence but no endpoint without voiced speech).
    The bundle is public and downloads without a token (`snapshot_download` → local dir →
    `TYGER_BUNDLE`); their `HF_TOKEN` gate applies only to their own `fetch()`. What
    remains: replay real idfon call recordings and A/B the events against our endpointer
    (`scripts/tyger-ab.py` is the harness; first synthetic-corpus results under
    "Measuring it" — the gate needs real recordings).
  - **P0b-ii (needs the GPU box):** the live full-duplex *experience* — MOUTH's models
    (Gemma 4 E4B in vLLM, VoxCPM2 in vLLM-Omni) do not install on macOS at all. That is
    the only part the GPU is for.
- **P0 → on-device parity prep (cheap now, expensive later):** log every decider event in
  the `docs/voice-decisions.md` training-record schema from day one, and keep the P1
  rules/decider module tier-neutral in `idfon-voice` — that log is the training data an
  on-device port will need, and the loop contract stays identical across tiers.
- **P1/P2 — built (2026-10-18): Shape 2 in one pass.**
  - `integrations/eve-idfon-voice/tyger-ears.py` — EARS sidecar: the real bundle through
    their `ReferenceEars` + `rules.py` (CPU), stdio JSON lines: feed a 320 ms hop of mic +
    second ear + the app's floor state, get `ENDPOINT`/`BARGE`/`BACKCHANNEL`/`PARTIAL`.
  - `tyger-relay.mjs` shape 2 (TYGER_EARS_CMD set) is MOUTH: replies from our agent (the
    bridge's wrapped agent or echo) spoken by our TTS (TYGER_TTS_CMD or engine.tts), with
    the MOUTH behaviors — a spoken line before a slow agent hop, paced playback a barge
    stops at once (only what the caller heard is kept; the unheard tail is dropped before
    it is ever posted), backchannels that never enter history or the second ear. The
    second ear is built from our own playback timeline (their `AgentPlayback` analog).
  - Demonstrated end to end on the smoke harness: endpoint → exact transcript → spoken
    reply → truncation machinery. **Open:** bridge mode against a served agent + live
    call; BARGE/BACKCHANNEL *triggering* on synthetic material (below).
  - Caveat: `ReferenceEars` on CPU runs ~1–2 s per 320 ms hop — correct for replay and
    demos, not real time. Live calls need the GPU box or their engine path (`EarsEngine`).
- **P0b-i measurements — real conversations (2026-10-18):** the gate instrument is
  `scripts/tyger-eval.py` over `anyreach-ai/dualturn-otospeech-turn-taking` (DualTurn /
  OtoSpeech: 287 h of real dual-channel conversations, per-frame `eot`/`hold`/`bot`/`bc`
  labels at 12.5 Hz — the model's own grid; audio is Mimi codes, decoded via
  `kyutai/mimi`; dataset license is `other` — internal evaluation only until checked).
  First two val sessions (2 min slices, ~4 turns total): **endpoint latency 0.16–0.24 s
  vs the energy baseline's 0.80–0.92 s** at `ep_thr` 0.85–0.91 (the synthetic speed win
  reproduces on real audio); endpoint AUC 0.90/0.92; baseline 0 early/0 miss but always
  late; TYGER 1 early cut-in per slice. Sample is still small — scaling needs their
  `EarsEngine` or a GPU box (`ReferenceEars` ≈ 2 s per 320 ms hop on CPU).
- **Switchboard follow-up (2026-10-18, `dualturn-switchboard-turn-taking`):** telephone-
  band conversations are a *hard* domain for TYGER — endpoint AUC 0.55 (vs 0.88–0.90 on
  wideband OtoSpeech), latency/early/miss ≈ the energy baseline. The advantage is
  domain-dependent: wideband conversational audio (like our calls) is its good regime;
  phone-line audio is not. Also fixed a real eval bug: the floor state must come from
  `bot`/`eot` (who holds the floor), not VAD activity — the other side's backchannels
  must not flip the model's LISTEN/SPEAK input (their docs: "never the model's guess").
  True floor-grabbing interruptions are sparse in Switchboard labels (0 in 24 min of
  scanned slices; its overlaps are backchannels) — for barge numbers use
  `MUGEN-Benchmark/Interruption_Detection` (raw audio) or longer GPU slices. First
  barge read (VAD-based, 2 onsets): catch within 640 ms = 0.5 at `barge_thr` 0.2 with
  92 false fires, 0 at 0.3+ — barge-in stays the weak axis, matching their own eval.
- **Calibration on synthetic material (2026-10-18):** the heads' scores are
  sensitive to synthetic material in both directions. `p_end` saturates 0.85–0.88 (never
  crossing 0.91) on room-tone pauses but hit 0.95 on digital silence; `yield_prob` reached
  **0.947 with a silent second ear but only ~0.32 with any agent speech in the ear**
  (same-voice TTS overlap reads as echo — their ISSUES I-26, materialized). On synthetic
  audio, working thresholds were `ep_thr≈0.85`, `barge_thr≈0.2–0.3` — but **the gate must
  tune thresholds on real call recordings**, not on `say` output.
- **P3 — report**, then decide about the on-device tier (Apple port) and about letting
  Nemotron's transcript replace the per-contact STT pickers.

## Risks and open questions

1. **"Works as advertised" is unproven live** — the model card says so itself. P0 is the
   gate; nothing else is committed before it.
2. **Echo sensitivity** (their ISSUES I-26): self-barge-ins show up first as false
   barge-ins per hour. The second ear is what we *sent*, tagged at send time, not what the
   caller's device played — the client's paced playback buffer (~50–100 ms) is pure offset
   error in the tag. Acceptable at P0 (their debounce absorbs some); measure it.
3. **Barge-in is slower than our text-echo path** (median 400 ms). Keep the instant
   text-echo barge alongside TYGER even in Shape 2.
4. **English only**; thresholds untuned for anything but their bench.
5. **Concurrency:** ~4 conversations per 4 GB VRAM; a session cap and a drop-decisions-
   first queue policy on the sidecar.
6. **Licenses:** model OpenMDW 1.1, code Apache-2.0 — fine to run and modify; keep the
   attribution, treat fine-tuned weights as derived data.
7. **Open:** do we copy their choice of silencing the bundle's silence fallback (rule in
   code instead)? Recommend yes — it is the guards-in-code rule.

## References

- `docs/voice-decisions.md` — the decision inventory these heads replace, guardrails.
- `docs/voice-agent.md` — `backend` shapes (`cascade`/`relay`), `voice_route` modes.
- `docs/voice-side-channel.md` — F3 endpointer authority, barge-in controller.
- `docs/voice-agent-loop-contract.md` — the trace record both tiers share.
- tyger-s2s: `README.md`, `DEVELOPING.md` (EARS/MOUTH, `app/wire.py`, `rules.py`);
  model card and `evaluation/metrics.json` at `huggingface.co/nineninesix/tyger`.
