# Our own decision model: the Tyger decision-surface audit

Status: **design brief (2026-10-31).** MVP ships with Tyger; idfon ultimately
needs its own decision model(s) — latency is key and even local LMs are too
slow. This doc is the ground for that work: how Tyger is used in idfon today,
exactly what it decides, which advantages to keep, which disadvantages to shore
up — and the **size brief** (the immediate issue: what Tyger does should not
need a 50+ MB model once the Nemotron streaming ASR encoder is shared).

Companion docs: `voice-tyger.md` (why tyger-s2s's way of working was adopted),
`voice-tyger-ondevice.md` (the on-device port tiers and precision rulings),
`voice-tyger-option.md` (classic vs tyger selection, fail-open), `voice-decisions.md`
(the wider decision inventory and fine-tuning loop — this doc covers only the
turn-decision model that replaces Tyger's), `voice-tyger-streaming-plan.md`
(the shared-Nemotron ruling this size brief assumes).

## The premise the size brief rests on

The 2026-10-25 ruling: **Nemotron streaming ASR + Tyger-class turn management +
Phonon mouth**, core tier-neutral. The ASR half has **shipped** —
`NemotronStreamingAsr` (FluidAudio `StreamingNemotronAsrManager`) is the call
ASR in both apps. What has **not** shipped is the mid-layer **L15 tap**
(streaming-plan candidate A's one open detail): today the streaming encoder
throws its layer-15 hidden state away, so every Tyger delivery still bundles
its own L15-truncated encoder copy (`TygerEncoderDyn`, ~1.5 GB of the ~2.9 GB
an iOS 27 tier downloads) purely to featurize the turn heads. The tap makes the
encoder shared and the *marginal* cost of turn decisions the turn-taker alone —
not the 397M "decision path" of the standalone bundle. The size brief below is
written for that target state; the turn-taker cut (P0) is valid either way. That marginal
model is what must shrink.

## How Tyger is used today (integration surface)

| Where | Form | Role |
| --- | --- | --- |
| eve TS agent (remote engine) | in-process ONNX (`integrations/eve-idfon-voice/src/tyger/`, onnxruntime-node) | the `tyger` turn-taking option; 99.89% decision agreement vs the fp32 oracle over 72 min |
| iOS + mac apps | `TurnShadow` + `ports/tyger-swift` tiers (CoreAI fp32 default, MLX int8-g16, CoreML fp16/ANE) | shadow beside the authoritative `Segmenter` (swap-over convention); active-mode decision sink when the tyger option is on |
| Rules layer | byte-identical ports of tyger-s2s's `rules.py`: Rust `crates/idfon-voice/src/turns.rs`, TS `rules.ts`, Swift `TurnRulesCABI` | deterministic guards + event emission; fixture-verified against the Python oracle |
| Selection | `turn_taker: auto \| classic \| tyger`, per-contact override | `auto` = tyger when the bundle verifies; **fail-open to classic** always; `turn_taker` recorded in the loop trace |
| Data | `TYGER_DECISION_LOG` records (the `voice-decisions.md` training-record shape), trait-stamped | the training data for our own model — already flowing |

## What Tyger decides (the decision surface)

**Inputs, per 80 ms frame** (12.5 Hz; fed in 320 ms hops, 8 s re-encoded window
per stream): caller's Nemotron L15 features (1,024-dim), the **agent's own**
L15 features (the second ear — echo awareness by construction), the caller's
normalized frame energy, the **app-fed floor state** (LISTEN/SPEAK — never the
model's guess), and the carried GRU state (9 KiB per call).

**Outputs, per frame** — one 8-vector: 4 state logits (LISTEN / HOLD / SPEAK /
BACKCHANNEL) + `hazard` + `yield` + `bc` + `p_end` probabilities.

**The rules layer turns scores into events** (this half is already ours — pure
code, three ports):

| Event | Fires when (defaults) | App does |
| --- | --- | --- |
| ENDPOINT | `p_end` ≥ 0.9146 for 2 frames, after ≥ 350 ms voiced speech (−50 dB) | commits the turn, answers |
| BARGE | `yield` ≥ 0.5 for 2 frames while SPEAK; carries `played_s` | stops playback at once, trims history to what the caller heard |
| BACKCHANNEL | `bc` ≥ 0.5 for 2 frames, then 1.2 s refractory | speaks "mm-hm"; caller keeps the floor; never in history |

Guards in code, not the model: 6 warm-up frames, the voiced-speech minimum, the
debounce, the backchannel gap, and a 1.2 s silence fallback endpoint. The
4-way state machine (`stateDecision`) adds hysteresis via the previous state and
gates SPEAK on `hazard ≥ θ` (0.2).

What Tyger does **not** decide: content, whether a turn *deserves* an answer,
tools, channel. It is a timing instrument — endpoint / yield / backchannel —
plus a turn-state estimate.

## Advantages to take

1. **The two-stream design.** The second ear (agent playback as an input) is
   what makes barge-in and echo rejection possible at all. On-device our
   playback clock is exact — better than the hosted tier's send-side tags.
2. **App-owned floor state as an input.** The model conditions on who holds the
   floor; it never infers authority. Keeps the "propose, do not authorize" rule.
3. **Rules-in-code with byte-identical ports + fixtures.** Deterministic,
   testable, diffable across Python/Rust/TS/Swift. A replacement model drops
   behind the same 8-vector → rules seam and changes nothing above it.
4. **Per-frame calibrated scores.** They feed threshold knobs (traits),
   adaptive calibration, and the decision log with full attribution — the
   pattern we want for per-user training data.
5. **Shadow-first swap-over.** `TurnShadow` runs beside the authoritative
   segmenter and diffs decisions before anything is trusted. Keep this for our
   own model's rollout.
6. **Fail-open to classic.** A call never depends on a model. Classic is the
   contract our model improves (voice-tyger-option.md P3).

## Disadvantages to shore up (with evidence)

1. **Size** (the brief below) — and its root cause: the turn-taker was trained
   as a bolt-on to a 0.6B ASR bundle, so its capacity is sized for joint
   training convenience, not for the decision task.
2. **Calibration brittleness.** `p_end` swings 0.85 → 0.95 on pause acoustics
   alone; `ep_thr` is live-tuned (0.9146). Every lossy encoding config drifts
   the endpoint head (0.030–0.041, even fp16) — enough that fp16 never ends a
   margin turn (the 2026-10-27 loader ruling: fp32 enforced). **A decision head
   that cannot be quantized is a design flaw for on-device.**
3. **Barge is the weak axis.** Median 400 ms, only 25% caught within 640 ms;
   echo sensitivity (their I-26): same-voice TTS in the ear drops `yield` from
   0.947 to ~0.32. Our text-echo barge stays alongside regardless.
4. **Backchannel is imprecise** (AP 0.30; 135 fires/hour in their eval) — a
   threshold knob, not a reliable detector.
5. **Domain-bound.** Wideband conversation is its good regime (AUC 0.9); telephone
   band collapses (AUC 0.55). English only, one seed, no live voice-agent benchmark.
6. **Compute shape.** Re-encoding an 8 s window per stream per hop is their
   simplicity; incremental KV failed the parity budget (drift, spurious
   backchannels). A small model on a *shared streaming encoder's* tap sidesteps
   the whole problem — no window re-encode, no incremental-cache drift.
7. **No personalization.** Adaptation is threshold drift only. (The decision
   log exists precisely to fix this — `voice-decisions.md`.)

## The size brief (immediate issue)

Measured from the bundle's `model.safetensors` (the turn-taker = everything
`turn_taker.*`; the encoder is shared with ASR and excluded):

| part | params | share | fp32 | int8 |
| --- | ---: | ---: | ---: | ---: |
| GRU core, 3 layers × 768 | 10.63M | 76% | 42.5 MB | 10.6 MB |
| 3 MLP heads (yield/bc/ep: 768→768→1 each) | 1.77M | 13% | 7.1 MB | 1.8 MB |
| fuse projections (L15→768 ×2, energy, norms) | 1.58M | 11% | 6.3 MB | 1.6 MB |
| state emb + state/hazard linear heads | 0.03M | — | 0.1 MB | — |
| **turn-taker total** | **14.0M** | | **56 MB** | **~14 MB** |

That 56 MB fp32 is the "50+ MB" — for three thresholds at 12.5 Hz. Two moves:

**P0 — done (2026-10-31): quantize the recurrence, keep the calibrated heads fp32.**
The heads (+ state/fuse fronts) are the calibration-sensitive part the precision
rulings protect; the GRU bulk is not. Built: `ports/tyger-onnx/quantize_step.py`
(GRU + fuse weights int8 per-output-unit group-16 asymmetric, dequantized
in-graph — compute stays fp32) + `qstep-parity.mjs` (the gate). Measured on the
runtime fixture: per-head probs **≤ 2.0e-3** vs the fp32 reference (10× inside
the 0.02 envelope), rules decisions identical, 0/248 state flips — **56 MB →
23.2 MB** shipped (`pack-bundle.mjs` prefers the int8 step; the eve TS agent
loads it). Per-row grouping (19.5 MB) fails `p_end` at 2.0e-2 — group-16 is
required, as the S3 MLX study predicted. Next rung for the same trick: the
CoreML/CoreAI step tiers (`ports/tyger-coreml/quantize.py`) and the corpus
decision gate (`decision-parity.mjs`, 99% bar) when sessions are prepped.

**P1 — our own student: ~1–1.5M params, ≤ 6 MB fp32 / ~1.5 MB int8.**
**Built (2026-10-31): `ports/tyger-student/`** — a decision-head platform, not a
copycat: a registry of decision points (type, label source, loss, gate) over a
shared ~1.3M trunk, so the next decision point is a registry entry plus labels
(`hold` is seeded as the first one the teacher does not have; `outcome:`/`gold:`
label sources from the decision log are declared for the fine-tuning loop).
Its train.py doubles as the per-head gate report.
**Status 2026-11-01: shipped as three gated delivery tiers** — ONNX 5.28 MB fp32
(int8 group-8 2.16 MB kept as the shelf variant for constrained tiers), Core ML
5.3 MB fp32, Core AI 5.3 MB fp32 + AOT container. Inside the product bars on every
measured axis (endpoint latency/early/miss, barge catch/false, bc precision/recall
— `pnpm tyger bench`); the rules thresholds are a per-model fit
(`ports/tyger-student/student.traits.json`: **0.85/0.4/0.4** — `ep_thr` came from
the live-call pass below, not from the teacher's 0.9146; the L4 student that
ships with the #102 encoder cut carries its own **0.75/0.5/0.5** in
`student-l4.traits.json` — the pooled 13-session live fit below, republished to
the manifest). The barge gate is measured (below).

**Live-call traits pass (2026-11-01).** The app already records the model's own
input during calls (`TurnCapture`: stereo 16 kHz, ch0 mic / ch1 agent), so the
fit runs on real call acoustics instead of Mimi-codec corpus audio.
`featurize.py --wavs DIR` turns those captures into label-free shards (teacher
events are the reference; never training input), and `calibrate.py` fits the
knobs. On 8 distinct captures (18.2 min, 244 teacher events, one Mac):

| ep_thr | 0.75 | 0.80 | **0.85** | 0.88 | 0.90 | 0.9146 | 0.93 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| event agreement | 58.3% | 62.6% | **64.4%** | 59.0% | 56.5% | 55.7% | 49.2% |

0.85 wins under leave-one-session-out every time (63.1–66.5%); bc 0.4 is
confirmed (64.4% vs 60.6% at 0.5). **Barge is measured** on two audio paths:
7 live captures (20 energy-VAD onsets; student 2/20 = teacher 2/20 at barge_thr
0.5, but the student fires 2 false barges vs the teacher's 16; below 0.5 the
teacher catches more only because its yield head is inflated — at equal
false-fire budgets the catches match (student 5/20 at 32 false vs teacher 5/20
at 33), and at 0.5 the student dominates. The student's head is
amplitude-compressed: L4 fits 0.42×teacher, L15 0.60×) and Open Yap 1K
dual-channel conversation
(59 onsets, 30 min; L4 vs L15 students operationally indistinguishable on yield:
79.7% vs 76.3% at 0.05 and 6.8% vs 8.5% at 0.5). The layer-sweep barge-MSE edge
for L15 does not survive real interruptions — L4 carries the barge signal. The
same checkpoint on the corpus val split calibrates to the bundle defaults, i.e.
the two audio paths genuinely disagree on `ep_thr` — the item-2 concern was real.
Full detail: `bench-results/live-calibration.md` (regenerable).
The task is temporal integration of two 1,024-dim feature streams + energy over
a few seconds of history — a width-256 2-layer GRU (or a small dilated causal
TCN) with linear heads fits it; the 768-wide recurrence exists because it shared
training with ASR, not because the decisions need it. Contract stays identical:
same inputs, same 8-vector, same rules seam — everything above the seam is
untouched. Train it **quantization-aware** (the ANE fp16 defect family and the
ep-head quantization floor say precision drift is part of the problem, not a
packaging step), and judge it on **decisions + harness metrics** (endpoint
latency/early/miss, barge catch/false, bc precision/recall via
`scripts/tyger-eval.py`), not per-head score drift alone.

Training signal, already available: the fp32 oracle's per-frame 8-vectors
(`--dump-scores`, the parity corpus) plus the live `TYGER_DECISION_LOG` records
(outcome weak labels per `voice-decisions.md`). Distillation first (teacher =
fp32 Tyger); then the weak axes (barge/echo with a real playback clock,
backchannel precision) get trained on **our** calls — which is also where
per-user personalization enters.

**P2 — decouple from the feature space.** The heads read Nemotron L15; that
binds the decision model to one ASR's mid-layer. A student trained on our own
calls can move to a cheaper/native tap of the streaming encoder (or a distilled
feature), keeping the decision model independent of the ASR choice per contact.

**P3 — fold into classic's contract** (`voice-tyger-option.md` P3): classic
behavior stays; its endpointing/yield decisions get the model's quality, traits
stay as the knobs, fail-open stays.

## References

- `docs/voice-tyger-ondevice.md` — per-tier guard numbers, precision rulings, the
  incremental-KV failure record.
- `docs/voice-tyger-s2s-comparison.md` — their live thresholds and the I-17/I-26
  error classes.
- `docs/voice-decisions.md` — decision-log schema, fine-tuning loop, guardrails.
- `docs/voice-tyger-streaming-plan.md` — the shared-encoder ruling and the L15 tap.
- `ports/tyger-mlx/turn_taker.py` — the decision model's exact anatomy (fuse →
  3-layer GRU → five heads).
