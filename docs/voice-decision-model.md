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
ASR in both apps. What has **not** shipped is the mid-layer **ASR tap**
(streaming-plan candidate A's one open detail): the streaming encoder throws its
hidden states away, so the turn heads still need their own encoder pass. The
shipped tier uses a private **L4 cut** of the same Nemotron encoder
(`TygerEncoderL4`, 106M / 389 MB fp32) and the L4 student; the L15 copy
(`TygerEncoderDyn`, ~1.5 GB) is the fallback. The tap makes the encoder shared
and the *marginal* cost of turn decisions the turn-taker alone — not the 397M
"decision path" of the standalone bundle. The size brief below is written for
that target state; the turn-taker cut (P0) is valid either way. That marginal
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
per stream): the caller's Nemotron features (1,024-dim) and the **agent's own**
features at the same layer (the second ear — echo awareness by construction;
L15 for the teacher/L15 student, L4 for the shipped L4 student), the caller's
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
debounce, and the backchannel refractory (1.2 s). The rules layer has **no**
silence fallback — only the head's ENDPOINT ends a turn. The native apps add a
separate 0.8 s segmenter fallback (`VoicePromptSegmenter.gap`) for recognizers
that never emit a final. The
4-way state machine (`stateDecision`) adds hysteresis via the previous state and
gates SPEAK on `hazard ≥ θ` (0.2).

What Tyger does **not** decide: content, whether a turn *deserves* an answer,
tools, channel. It is a timing instrument — endpoint / yield / backchannel —
plus a turn-state estimate.

## Where the GRU sits: the frame data flow

What feeds the temporal core and where its output lands, per 80 ms frame
(`ports/tyger-student/model.py` for the student, `integrations/eve-idfon-voice/
src/tyger/engine.ts` + `rules.ts` at runtime; the teacher has the same shape
with bigger numbers):

```
user mic audio ──► encoder/tap ──► hu (1,024) ─► proj_user ──┐
agent playback ─► encoder/tap ──► ha (1,024) ─► proj_agent ──┤
frame energy ───────────────────► act_db ─────► proj_energy ─┼─ sum ─► in_norm ─► GRU
previous floor state ───────────► prev_state ─► state_emb ───┘      (256-d, 2 layers)

GRU z ─► one linear head per axis ─► 8-vector = [4 floor-state logits
         (listen/hold/speak/backchannel), hazard, yield, bc, p_end]
       ─► rules.on_frame(mode, out8) ─► events: ENDPOINT / BARGE / BACKCHANNEL
```

- `hu`/`ha` are one feature vector per ear. The two-eared input is what lets
  the model separate a user cut-in from the agent's own voice.
- `prev_state` closes the loop: the floor state the rules chose on the previous
  frame is an input to the next. GRU state resets at mode/rules reset points.
- `engine.hop()` threads the GRU hidden state across frames (carried in the
  ONNX step's `state` I/O: teacher 3×768, student 2×256).
- The GRU is a temporal memory seam, stateless per frame otherwise: the
  **rules** layer — thresholds, debounce, refractory, the 4-way state machine —
  turns per-frame scores into events. The network never emits events itself.
- The published HF annotation records capture exactly this seam:
  `teacher_scores` is the per-frame 8-vector, `teacher_proposal` is what the
  rules did with it (`donpark/open-yap-1k-turn-annotations`).
- Epic #132's shared-latent variant changes only the left side: per-tap
  adapters project whichever feature tap the streaming ASR offers (e.g.
  `l4-streaming`) into the shared width, then one shared GRU → one decoder;
  the GRU→heads→8-vector→rules seam is unchanged and is the portability
  contract between tiers.

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

**P2 — decouple from the feature space.** The teacher and the L15 student read
Nemotron L15; the shipped L4 student reads L4. Either binds the decision model
to one ASR's mid-layer. A student trained on our own calls can move to a
cheaper/native tap of the streaming encoder (or a distilled feature), keeping
the decision model independent of the ASR choice per contact.

**Tap probe survey (2026-11-03, epic #132 P0).** Per-tap ridge probes (R² /
cosine, `ports/tyger-student/probe.py`, held-out sessions; tap features alone —
no energy/prev_state) of the teacher's 8-vector per axis. Full regenerable
table: `bench-results/tap-probes.md`. Headline rows (R² per axis):

| tap | data | state | hazard | yield | bc | p_end |
| --- | --- | --- | --- | --- | --- | --- |
| L15 windowed (teacher inputs) | dualturn 60+8 | 0.80 | 0.67 | 0.44 | 0.46 | 0.79 |
| L4 windowed (shipped cut) | dualturn 60+8 | 0.75 | 0.55 | 0.39 | 0.43 | 0.75 |
| **L4 streaming (the ASR's tap)** | dualturn 60+8 | 0.73 | 0.53 | 0.39 | 0.41 | 0.75 |
| L15 windowed | live 8 captures | 0.82 | 0.53 | −0.02 | 0.31 | 0.55 |
| L4 windowed | live 8 captures | 0.81 | 0.44 | **0.09** | **0.56** | 0.44 |
| L15 windowed | Open Yap 16×5 min | 0.82 | 0.65 | 0.49 | 0.75 | 0.51 |
| L24 streaming (ASR final layer) | Open Yap 16×5 min | 0.55 | 0.09 | 0.32 | 0.33 | 0.16 |

1. **The streaming tap is at parity with the private pass** — L4 streaming
   tracks L4 windowed within 0.01–0.02 R² on every axis. The hidden states the
   ASR computes and throws away carry the decision signal; #132's footprint
   premise holds at the linear-probe level.
2. **No single best tap; ranking is per axis and per audio path** — on live
   captures L4 decodes yield and bc better (0.09 vs −0.02; 0.56 vs 0.31) while
   L15 decodes p_end better (0.55 vs 0.44); on corpus bc favors L15 (0.46 vs
   0.43, Open Yap 0.75 vs 0.65). This is the evidence behind per-axis teacher
   weighting in the shared-latent student (never averaged).
3. **L24 is poor overall** (hazard 0.09, p_end 0.16 vs L15's 0.65/0.51) — the
   feature-adapter R² ≈ .30 finding generalized per axis; the ASR's final layer
   is not a drop-in tap.
4. **Yield is the least linearly decodable axis everywhere** (−0.25…0.49) —
   the axis that most needs temporal integration, and the one the consistency
   loss must not starve.

**Shared-latent spec (P1, #136).** The contract now lives where the epic says:
`ports/tyger-student/registry.py` (`ADAPTERS` per (layer, pass) tap +
`LATENT_WIDTH`) and `model.py`'s `SharedLatentStudent` — per-tap adapters → one
shared causal `z` (width-256 GRU) → one decoder, unchanged 8-vector seam; the
shipped `Student` is untouched (checkpoint layout pinned by `test_model.py`).

**Weighted multi-teacher baseline (2026-11-03, epic #132 P2).**
`ports/tyger-student/train_shared.py` trains one `SharedLatentStudent` over the
three frame-aligned dualturn tap shard sets (`l15-windowed`, `l4-windowed`,
`l4-streaming` = deploy target) with **per-axis teacher weights from the P0
probe table** — `raw = max(val R² of the tap's ridge probe on the head's
8-vector columns, 0)`, `w = raw / mean(raw over the five teacher heads)` (mean
exactly 1.0 per tap; the corpus `hold` head fixed at 1.0), so the weighted loss
`Σ w·L / n_heads` keeps train.py's plain-mean scale while each tap's batches
emphasize the axes it measurably carries. Never averaged teachers. Weights land
state/endpoint ≈ 1.23–1.29, hazard ≈ 0.91–1.01, bc ≈ 0.85, barge ≈ 0.67–0.68
(probe R² per tap in `bench-results/*/weights.json`, one `probe.py` rerun away).
Fixed baseline for P3: 60 epochs (40 @ lr 1e-3 + 20 @ 3e-4, seed 0). Measured
(`bench-results/` scratch, all regenerable via `train_shared.py` + `gate.py` /
`calibrate.py` / `harness.py` — full tables in issue #137):

- **Score gates reproduce per path.** l15-windowed endpoint **.0129** (the
  single-tap reference .0140), every head ≤ .02; the L4 paths land .0253–.0262
  endpoint — better than the shipped L4 student's .0273 but over the ≤ .02
  registry gate, which the shipped L4 student also misses (the gate is an
  L15-path bar; L4 endpoint is the tap ceiling — probe R² .78 vs .81).
- **Event agreement** (rules replay): live L4 pooled 13 captures **59.7%
  calibrated** (bar 56.6%; current L4 student 56.8%) and corpus-val L4-family
  58.4–60.5% (current 58.5%) reproduce; the **L15 family carries the residual**
  — live 8 captures 62.5% (bar 64.4%), corpus val 66.3% default (current 69.1%).
  (loss-ab's 71.3% predates the 2026-11-03 replay-semantics change: `gate.py`
  now replays mode-less shards as listen, was response.)
- **Attribution** (uniform-weights A/B, same seed/epochs): corpus l15 agreement
  49.0% uniform vs 60.9% weighted — **+11.9 pts from the per-axis weighting**
  alone; multi-tap training without it does not reproduce the single-tap student.
- **Product metrics** (harness, 13 held-out sessions, 139 eots, 20 interrupting
  onsets): latency / miss / barge / bc bars hold everywhere (miss −7 to −19 vs
  teacher at the default triple); the early-cut bar (≤ teacher + 1 pt of eots =
  1.4 events) rides inside threshold noise — early +4/miss −7 at the default
  triple, early ±0/miss +2 at ep 0.93; the shipped L4 student is +5 early on the
  same set. Early/miss is a traits-knob trade, not a model deficit.
- **Negative results:** agreement climbs with epochs (l15 corpus 57.4 → 60.9 →
  66.3% at 20/40/60) but the early/miss trade shifts toward early and l15
  worst-session latency grows (+0.32 → +0.48 s); 80 epochs regresses (live
  61.5%). hold AUC decays with epochs (.97 → .93). bc under-firing persists
  (shared l15 fires 92 vs the single-tap student's 122 candidate backchannels
  against 112 reference events) — the known product gap, amplified by the bc
  down-weight its own probe quality dictates.

**Product-bar revision (2026-11-03, after the P2 measurement).** The proposed
"early and miss each ≤ teacher + 1 pt of eots" bars are too tight to judge
anything: on the 13-session/139-eot set the tolerance is 1.4 events while the
ep knob moves the early/miss split by more than that (ep 0.93: early ±0/miss
+2; ep 0.9146: early +4/miss −7 — no triple satisfies both within noise), and
the shipped L4 student is +5 early on the same set. Revised bar (what P3/P7
judge against): **endpoint misses + early cuts combined ≤ teacher's combined
+ 2 pts of eots, and latency ≤ +160 ms mean-of-medians / +320 ms worst
session** — the combined error is knob-independent (every measured model is
within +2 events of the teacher's combined count), the early/miss *split* is
report-only as a traits-knob trade.

**Where the +160 / +320 ms figures come from (2026-11-05).** They were set with
this bar recut and no derivation was recorded; 320 ms is exactly one hop
(4 x 80 ms), so read them as "at most one decision cycle of added delay". Do not
cite them as a perceptual threshold — the perceptual question has never been
measured here.

**Two state vocabularies, and they are not interchangeable (2026-11-05).** The
turn path carries two different states and the docs used both loosely, which
cost real evidence — replay harnesses passed the *stream* name `"response"` as
`mode` for weeks, which silently disables the barge branch (`rules.py` falls
through to listen for any string other than `"speaking"`).

- **`mode` — who holds the floor.** Binary, app-fed, never guessed by the
  model: `"listen"` or `"speaking"`. `"speaking"` means **the agent's mouth is
  running**, not the user. The reference implementation is explicit
  (`app/ears/conversation.py:181-187`): when the agent is speaking, `mode =
  "speaking"` and the agent's own audio goes on the second ear; otherwise the
  second ear is zeros and `mode = "listen"` (`app/plugins/base.py:169`).
  Inside `"speaking"` mode the rules watch the **caller's** energy
  (`act_db`, the user ear) and run the yield head, so BARGE = the caller taking
  the floor from the agent.
- **`prev_state` — the model's four-state machine.** `0 LISTEN, 1 HOLD,
  2 SPEAK, 3 BACKCHANNEL`, carried across frames and reset at
  BARGE/ENDPOINT/mode change.

Capture convention: `TurnCapture` writes **stereo 16 kHz, `ch0` = caller mic,
`ch1` = agent**. So `mode` is derivable per frame from `ch1` activity, and a
capture whose `ch1` is silent carries no barge evidence at all — the sidecar
records `agentNonSilent`/`agentPeak` precisely so that is visible rather than
assumed. Every replay now takes its track from `ports/tyger-student/mode_track.py`
(a recorded track when present, else `ch1` energy at -50 dB with a 6-hop release);
the resulting live barge measurement is in `voice-tyger-ondevice.md` § "Barge on
the live captures".

**`left` means the hop's remaining frames, and it is only a timestamp fix
(2026-11-05).** `rules.py` uses it in one place: `onset_s = min((talk_frames +
left) * FRAME_S, ONSET_MAX_S)` — a barge's onset is extrapolated to the hop's
end because the hop's newest audio is what the rules hold when they read the
event. It is not a debounce input (that is `barge_deb`/`yield_run`). So a
per-frame decision lattice — one student step per 80 ms frame, no hop
buffering — is expressed correctly by `left = 0`, and any non-zero value there
would overstate barge onset by up to the hop length.

**Cross-tap consistency ablation (2026-11-03, epic #132 P3, issue #143).**
`train_shared.py --consistency LAM` adds `LAM · symmetric-KL(seam decisions via
tap A ‖ tap B)` on the same frames (paired windows, seeded partner tap per
step; λ=0 verified bit-identical to the baseline recipe). A/B vs the fixed P2
baseline at λ = 0.1 / 0.3: **λ=0.3 earns partial credit — kept.** At the
product (calibrated) triples it improves 4/5 agreement measurements
(+0.4…+0.6, both live fits included), closes ~25–30% of the l15 residual
(live-cal 62.50 → 63.11 vs the 64.4 bar), improves both L4 endpoint gates
(.0253/.0262 → .0230/.0256), and cuts missed turn-ends by 9 per 139 eots on
every path with the highest barge catch. Negative results: λ=0.1 is mixed to
negative; the term costs default-triple agreement (calibration shift, absorbed
by the per-model fit — P4 territory); hold AUC decays further; and the l15
residual is mostly *not* a tap-agreement problem (KL recovered only a quarter
of it — the rest is per-tap head quality: bc under-fire + endpoint timing,
pointing at P4 calibration and data). P5 should budget adapter + calibration
cost, not plug-and-play.

**Per-adapter calibration + quantization parity (2026-11-04, epic #132 P4,
issue #145).** One temperature scalar per adapter (pre-seam logits/T,
`calibrate.py --temp-grid`: NLL-to-teacher + agreement fit, both reported) — and
the P3 residual turns out to be largely calibration: **live-L15 clears its bar
(63.11 → 65.16% vs the 64.4% bar)** and default-triple behavior recovers +6.6
pts at T-only. The fit is per adapter AND per domain (l15 wants sharpening
T≈0.7–0.8; the l4-windowed live path wants T=1.0 and loses 2.9 pts at any
other fit — one global T is a net negative). The corpus l15 residual (−1.9 vs
anchor) survives calibration — per-tap head quality, per P3. At the fitted
configs bc recall recovers to teacher level and misses drop to 7–8 per 139
eots (latency below teacher; the sharpened split leans early — the combined
bar holds with margin). Quantization: fp32 export passes clean (8e-7, 0
flips, 0.08–0.15 ms/step, 5.28 MB = student-sized artifact); **int8 group-16
AND group-8 fail the 2e-3 probs envelope on the shared tier** (3.1–6.1e-3)
while the single-tap student passes at group-8 (1.63e-3) — so per the repo
ruling **QAT is needed** (fragility is mostly the shared architecture, 2.33e-3
for the P2 baseline; consistency adds ~0.7e-3). int8 buys bytes (1.75 MB) not
CPU latency; rules decisions stayed identical in every quantized run.
**QAT verdict (2026-11-04): done — fine-tune recipe.** `train_shared.py --qat N`
projects the export's int8 group-N grid (GRU W/R + adapter projections) onto the
weights after every step (`qat.py`, bit-identical to `quantize_step.py`); QAT
fine-tuning (20 ep @ 1e-4 from the converged fp32 λ=0.3 model) makes the int8
artifact **numerically indistinguishable from the torch model (6e-7…7e-6 vs the
2e-3 envelope, 0 flips, all adapters)** at zero quality cost (gates unchanged,
live-L15 exactly at its 64.4% bar) — deployable: 5.28 → 1.75 MB. Negative
results: training on the grid *from scratch* costs the l15 path 5–7 pts (the
epic's "from the start" is not free for this architecture — converge first,
then adapt); a shape-convention bug (`nn.Linear` (out, in) vs the export's
(in, out)) once shipped GRU-only QAT and was caught by the parity gate; group-8
artifacts need `--qat 8` (grid mismatch); QAT shifts calibration again —
per-model fits stay mandatory.

**P3 — fold into classic's contract** (`voice-tyger-option.md` P3): classic
behavior stays; its endpointing/yield decisions get the model's quality, traits
stay as the knobs, fail-open stays.

## P6 — the slow tier's structured decision record (2026-11-05, issue #160)

Scope call: **a phase of #132**, not its own epic. It shares the latent, the tap
adapters, the registry and the teacher hand-off with the fast tier; nothing in
the measured phase needed a separate corpus or export track. Split it out only
if a dense event corpus or a separate serving tier appears.

The slow tier answers `docs/voice-decisions.md`'s record shape — `turn_state`
(choice), `end_of_turn` / `barge_in` / `assistant_backchannel` (`noul`),
`decision_confidence` (`score`) — **once per clause/turn event**, off the 80 ms
frame path. Built as three repo scripts, reproducible from a clean checkout:
`slow_state.py` (serializer), `slow_model.py` (decoders), `slow_train.py`
(train/report). Each has `--selfcheck`.

**The serialized state.** The fast tier's shared latent `z` (256-d, post
`out_norm`) plus its own 8-vector, raw frame energy, the rules' `prev_state`, and
playback/listen mode over a trailing **2 s (25-frame) window**. One `.npz` per
session holds the stacked windows; `events.jsonl` is the provenance index. A
record is a pure function of that state — the decoder carries no hidden state and
never touches the frame loop. Events are deterministic and runtime-detectable:
energy VAD transitions (`pause`/`onset`) plus **candidate** crossings of the fast
seam (p_end 0.5, yield/bc 0.2, 2-frame hold), deduped by frame. The candidate
thresholds are below the rules' decision thresholds; the teacher's frame answer
is the reference, never the trigger.

**Two decoder shapes, measured.** 

| shape | what it reads | params | fp32 / int8 | CPU p50/p95 per event |
| --- | --- | ---: | ---: | ---: |
| fast-floor | the fast seam's own answer at the event | — | — | — |
| **A: `z-gru`** | trailing `z` + event kind, 1-layer GRU(128) → heads | 150,668 | 0.60 / 0.15 MB | 0.235 / 0.247 ms |
| B: `state-transformer` | per-frame tokens of `z`+fast8+energy+floor+mode+activity, 2×128 transformer | 310,540 | 1.24 / 0.31 MB | 0.209 / 0.221 ms |
| B-large | same, 4×256 | 2,199,564 | 8.80 / 2.20 MB | 0.475 / 0.499 ms |

Corpus val (dualturn, 8 sessions / 1644 events; thresholds fitted on the 60-session
train split, judged on val):

| model | ep AUC | ep agr | barge AUC | bc AUC | **commit AUC** | **pause commit AUC** | state agr |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| fast-floor | .940 | .904 | .950 | .938 | .743 | .600 | .950 |
| z-gru | .934 | .890 | .953 | .938 | **.825** | **.714** | .947 |
| state-transformer | .934 | .895 | .944 | .936 | .792 | .682 | .943 |
| state-transformer-large | .939 | .901 | .943 | .938 | .826 | .712 | .951 |

**`commit`** is the slow tier's judgment question: did the teacher emit ENDPOINT
within 400 ms of this event? It is the pause-vs-completion call, and it is where
the slow tier earns its place — **+8.2 pts AUC over the fast seam overall,
+11.4 pts at pause events**. Seed stability (seeds 0/1/2, `z-gru`): commit AUC
.825/.808/.819 (pause .714/.713/.735); small transformer .792/.802/.772 (pause
.682/.685/.658). The cheap recurrence wins consistently.

Live domain (8 captures / 1131 events, fast adapter `l4-windowed`; per-domain
leave-one-session-out threshold fit, #145):

| model | ep | barge | bc | commit |
| --- | ---: | ---: | ---: | ---: |
| fast-floor | .930 | .984 | .852 | .839 |
| z-gru | .928 | .987 | .875 | **.856** |
| state-transformer | .936 | .981 | .867 | .854 |
| state-transformer-large | .937 | .981 | .862 | .843 |

**Verdict: build shape A (decode from `z`).** It is the smallest artifact, costs
the same per event as the small transformer (~0.21–0.24 ms), and matches or beats
the largest shape on the judgment axis. The serialized-state model is *not* worth
its extra bytes: the small transformer is worse than `z-gru` on commit AUC at
every seed, and the 2.2M rung only ties it at 0.60 → 8.80 MB and ~2× CPU. Nothing
in this measurement argues for the Kev-0.8B/4B or d1-omni-600M class; those
checkpoints were not runnable in this environment and would enter as a much
larger version of the losing shape.

**Negative results / limits (per #131).**

- The slow tier is **not a replacement for the fast seam**: frame agreement on
  endpoint/barge/bc is 0.890–0.901 vs the fast floor's 0.904/0.987/0.897 at
  corpus val (barge/bc effectively tied, endpoint −1.4 pts). It adds a judgment
  field; the fast seam keeps the frame decisions.
- The corpus `eot_ch0`/`hold_ch0` labels are **sparse point events** (~0.5% of
  VAD offsets), not a dense pause-vs-completion target; at pause onsets the
  teacher's `p_end` even anti-correlates with `eot` within 1.2 s (AUC .34). The
  measured `commit` label therefore comes from the teacher's own ENDPOINT events
  within 400 ms, not from those corpus keys.
- Event triggers are energy-VAD + fast candidates; the corpus VAD is not a
  runtime signal, so trigger alignment is approximate by construction.
- Latency was measured on CPU (torch, 1 thread) while the machine was under a
  load average of ~8 from another agent's MPS job; CPU-time p50/p95 track wall
  time within 0.01 ms and repeated runs agree, but this is not a quiet-machine
  figure. No ANE/CoreML/CoreAI export was attempted — that is P7.

## Barge event spec (2026-11-06): audibility gate, refractory, the turn-grab split

Status: **decision, harness-verified; ports pending.** The measurement is on Open
Yap 1K's 16-conversation public sample (8.9 h, 48 kHz dual-channel, CC-BY-4.0),
first 300 s of each call: 16 independent sessions, 80 min, `featurize.py` with the
current mode track, then `scripts/openyap-barge-sweep.py --selfcheck`.

**What the rules do today.** BARGE needs `mode == "speaking"` and
`yield ≥ barge_thr` for `barge_deb` frames. `mode` is *bridged*: it holds for
1.92 s past the agent's last loud hop (`mode_track.RELEASE_HOPS`), and the rules
never see the agent's own energy — `act_db` is the caller's.

**Measured, same 80 min, one row per threshold:**

| yield thr | events | false/min | precision | recall | per-episode | ep. precision | ep. false/min |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.30 | 2232 | 24.4 | 13% | 37% | 195 | 14% | 2.1 |
| 0.40 | 1646 | 18.0 | 12% | 29% | 194 | 13% | 2.1 |
| 0.50 (shipped) | 1257 | 13.7 | 13% | 23% | 179 | 14% | 1.9 |

Three readings, all reproduced by the tool:

1. **The threshold is not the knob.** Recall moves 23% → 37% over a 1.7×
   threshold range while precision stays at 12–13%.
2. **The rule re-fires ~19× per speaking episode** (1,257 events → 179 episodes).
   One event per episode alone takes 13.7 → 1.9 false fires/min at unchanged
   recall. Backchannels have `bc_refractory`; barge has nothing.
3. **The release tail is a different event, not noise.** Under a strict overlap
   reference (agent voiced on the frame before the caller's onset) 14% of
   per-episode decisions are real; the human audit of the same head
   (`bench-results/human-audit-openyap.md`, question: *did the user cut in over
the agent and take or contest the floor near the mark*) confirms 63%. The gap is
   the definition, and both are true: with the agent silent there is nothing to
   stop, but the caller is taking the floor.

**Decision.**

- `BARGE` — agent audible (its own channel loud within 320 ms) **and** one event
  per speaking episode. Action: stop playback. Acceptance: ≥50% of strict-overlap
  interruptions, ≤1 false stop/min.
- `TURN_GRAB` — caller takes the floor within ~1.2 s of our last agent audio.
  Action: yield/queue the next utterance; **never** stop playback.
  Acceptance: set by the semantic audit, not by this sweep.
- Neither may fire while the agent channel is silent for the other's action.
  `mode` stays bridged for the floor state, ENDPOINT and BACKCHANNEL — the
  audibility condition belongs to the barge branch only.

**Human audit of the bar (step 1, 2026-11-06).** 32 handoff clips and 30 fire
clips from the same 80 min were judged blind on one question — *is the caller
claiming the floor at the mark?* — with "already talking" not counting as No;
clips where the caller was already speaking and kept going were scored Yes.
The 32 handoffs are ≈random over the 637 handoffs: the 11:03 build sampled
positions systematically, which spreads evenly over the run-length quartiles.

- **Handoffs: 17/32 yes = 53%** base rate (95% CI ≈37–69%). By population
  run-length quartile: ≤320 ms 1/9 (11%), 320–640 ms 3/6 (50%), 640–1440 ms
  6/10 (60%), >1440 ms 7/7 (100%). The short-run misses are partly *correct*
  behaviour: only 11% of ≤320 ms handoffs are floor claims. A detector firing
  on every handoff scores 53%; the head's 45% precision on live captures is at
  or below that base rate and needs the same denominator to mean anything.
- **Fires: 28/30 yes = 93%** precision (95% CI ≈79–98%). Both "no" are at
  threshold 0.40 (2/10 false there, 0/10 at 0.30 and 0.50). The manifest's
  `mark_s` is the clip lead, computed from the fire's distance to the agent's
  last voiced frame, so the set splits by silence without regenerating it.
  Under the decision's strict-overlap definition (agent voiced on the frame
  before the mark) there are **10 strict-overlap fires, 10/10 real, 0 false**:
  the landed firing-frame check keeps every one and meets the BARGE acceptance
  (≥50% strict-overlap, ≤1 false stop/min). The spec's 320 ms window is worse —
  it also admits the two false fires at 240 ms silence (12/14, 86%). The 16
  silent-tail fires are real floor claims but not barges: they belong to
  TURN_GRAB (yield), so the gate only loses them if the tail has no TURN_GRAB
  path. That split, not the gate, is the open item.

### Endpoint audit clips (step 1's second verdict, 2026-11-06)

The handoff and fire clips answered the barge question. The endpoint question —
*has the caller finished, may the agent safely take the floor?* — needs its own
set, split by the corpus's own `eot` label so the two classes are comparable.

`scripts/endpoint-clips.py` streams the dualturn-switchboard dataset (the replay
shards store features, not audio), decodes each chosen session's Mimi codes, and
cuts 6 s stereo clips with the mark 3 s in. Selection prefers sessions that
supply both classes so the comparison is within-conversation.

| set | n | definition |
| --- | --- | --- |
| fires-on-eot | 10 | ENDPOINT fire within 10 frames (0.8 s) of an `eot` label |
| fires-off | 10 | ENDPOINT fire at least 10 frames from any `eot` label |

The clips and manifest are in `bench-results/endpoint-audit-2026-11-06/`; open
`index.html` there. The page reads the manifest's columns and uses the endpoint
rubric when a `class_` column is present. `mark_s` is clip-relative (3.0 s) and
`ts_s` is the absolute time in the conversation.

**The verdict (20 clips, 10 per class).** The two classes do land differently:

| set | yes | rate | 95% CI |
| --- | ---: | ---: | --- |
| fires-on-eot | 10/10 | 100% | 72–100% |
| fires-off | 5/10 | 50% | 24–76% |

The on-eot class is the stronger result: every fire that landed within 0.8 s of
an `eot` label sounded like the caller had finished. The off-eot class is the
finding that matters for training — only half of fires far from an `eot` label
sounded finished, so **the absence of an `eot` label is not evidence that the
caller had not finished**. The label under-covers the actual turn end: fires
just outside its window (1.52 s away) and fires 40–58 s away both drew "yes".
One of the ten off-eot verdicts is a hangup (caller already gone at the mark),
not an endpoint judgment; excluding it leaves 4/9 = 44% (19–73%).

So the label is a valid positive but a noisy negative. A detector trained on
`eot`-present vs `eot`-absent learns label coverage, not turn-taking — the
negative class needs its own audit, not the label's silence.

Caveat: n=10 per class over 10 Switchboard sessions, so the CIs are wide; the
100% and 50% are directionally solid but the exact rates are not. A second,
disjoint 20-clip set (10 other sessions, `bench-results/endpoint-audit2-2026-11-06/`,
`--exclude` on the drawer) is staged for a second listening pass to double n and
tighten the CIs; the verdict above is the first set alone.

### Event catalog for training clips (step 3, 2026-11-06)

The four events are one detector's output split by `gap_ms` (caller onset minus
the agent run's end), so no second detector is needed:

| event | `gap_ms` | anchor | condition for a clean clip |
| --- | --- | --- | --- |
| `handoff` | 0–320 | caller onset | agent voiced ≥50% and caller ≤10% of the lead |
| `overlap` | 0 (caller starts inside an agent run) | caller onset | the event itself; report caller/agent lead fractions |
| `silent_tail` | 321–1200 | caller onset | caller silent in the lead (≤10%); the agent's last words sit at its start |
| `long_pause` | >1200 | — | not an event (a new turn, not a floor claim) |

On the 16 local Open Yap conversations (80 min, 637 handoff records):

| kind | n | clean lead | caller silent | ≤320 ms | 321–640 | 641–1440 | >1440 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `handoff` | 126 | 48% | 48% | 27 | 30 | 34 | 35 |
| `overlap` | 270 | 48% | 51% | 105 | 61 | 67 | 37 |
| `silent_tail` | 213 | 21% | 35% | 43 | 43 | 57 | 70 |
| `long_pause` | 28 | 4% | 21% | 1 | 9 | 5 | 13 |

Under each event's own condition: **60 `handoff`** candidates (9% of all
records), **245 `overlap`**, **75 `silent_tail`**. The `handoff` yield is the
binding constraint — ~3.75 clean clips per conversation — so a 1,000-clip set
needs ~270 conversations, not 16. Two things this table makes explicit: the
clean-lead gate conflates "caller silent" with "short gap" (a 50% agent-lead
fraction caps the gap at ≈0.6 s), and 42% of the detector's "handoff" records
are overlaps, so an audit that pools them is measuring two populations.

**Oracle review of this design (one-shot, 2026-11-06).** The four gap bins are
*sampling strata*, not four ground-truth events: gap is a noisy timing measure,
not intent or production state. A caller can backchannel inside an overlap,
claim the floor after a long pause, or just make a noise in a 0–320 ms gap — the
blind audit's 17/32 already shows the label drift. Labels should be defined by
caller action and agent state **at the decision instant**, not by the gap that
produced the clip. Two measurements back that up: **22% of the 637 records are
acknowledgement-length caller runs (<300 ms)** — 31% of overlaps, 16% of
handoffs and silent tails — and **48% of handoffs sit within one 80 ms frame of
the agent's last voiced frame** (65% within two), where frame quantization plus
the 0.2 s bridge can flip a handoff into an overlap or a silent tail. Keep the
dirty and boundary cases as *evaluation strata* rather than discarding them,
and build contrasts (floor claim vs acknowledgement at the same gap,
interruption vs start just after playback stops) instead of only clean audio.

One target-alignment trap the table carries: `caller_run_ms` is the caller's
*eventual* run length, so a label keyed to the onset and stratified by that run
length uses information the live GRU did not have at onset. Either label at the
later decision time or accept early uncertainty; label negatives at the same
decision opportunities as positives, or the training set learns precision among
candidates and nothing about misses.

**Rollout.** Harness A/B (`openyap-barge-sweep.py`) → rules ports → traits bump.
The gate changes events, not labels: the head is distilled from the teacher's
`yield` score, so no retraining is implied.

*Landed 2026-11-06.* Three thresholds, all defaulting to **off** so the parity
fixtures keep asserting tyger-s2s's behaviour, and enabled per deployment:
| threshold | effect | measured on the same 80 min | status |
| --- | --- | --- | --- |
| `barge_edge` | fire per threshold crossing, re-arm when yield drops | 1,257 → **441** fires, recall **23% → 23%** | **enabled** in `tuned()` and the TS engine |
| `barge_refractory` | one per speaking episode | 1,257 → 179 fires, recall 23% → **9%** | off; the audit decides |
| `barge_gate_db` | agent channel audible on the firing frame | 10/10 strict-overlap fires kept, 0 false; the spec's 320 ms window also keeps both false fires | off; the split decides |

Edge-triggering is the free win: a third of the events at identical recall.
The refractory buys another 2.4× fewer false fires but halves recall, so it is a
product trade, not a bug fix. `tests/turns_barge_gate.rs` and
`test/rules-barge-gate.test.ts` cover all three (silent tail blocked, audible
overlap allowed, sub-threshold blocked, one-per-episode, one-per-crossing with
re-arm after a dip, and both defaults off); `turns_fixtures.rs` and the TS
fixture replay still pass byte-for-byte.

**It needs its own head.** Measured on 637 floor handoffs from Open Yap 1K
(80 min, 16 calls; `scripts/openyap-handoffs.py`, an audio-side reference that does
not use the model's own fires), the teacher's 8-vector shows why `yield` cannot do
this job: for the 212 handoffs we miss at ≤600 ms, `yield` peaks at **p50 0.05**
(183 of 212 below 0.30), because it is trained to fire *while the agent talks* and
at a handoff the agent has stopped. The state head does see the caller — SPEAK at
174/212 of those misses — but as a rule it fires 20×/min at 18% precision.

So `turn_grab` is a registry head on the corpus's Beginning-of-Turn label
(`corpus:bot_ch0`, 3.4 positives per 3-minute session, `pos_weight=25`), outside
the 8-vector seam. In-domain val AUC **0.993**.

**Thresholds must be per-domain percentiles, not absolute values.** The head's
ranking transfers and its scale does not:

| domain | threshold | events/min | handoffs caught (±400 ms) | precision |
| --- | --- | ---: | ---: | ---: |
| Open Yap, 80 min | p99 = 0.082 | 4.4 | 38% | 74% |
| live captures, 33 min | **0.082, fitted on Open Yap** | 3.4 | 49% | 45% |
| live captures, 33 min | its own p99 = 0.072 | 3.9 | 51% | 43% |

The Open Yap percentile lands within 0.01 of the live set's own — the first
quantity in this work that transferred between domains unaided. For comparison,
`yield` at its shipped 0.5 gives 19% at 60% precision on Open Yap and 43% at 61%
on live, at 4.0 and 5.3 events/min respectively: the new head wins clearly on the
first and trades precision for reach on the second.

Two things that do **not** help, measured on both domains:

- **per-call percentile fitting** (`--per-call`): live 46% catch at 43% precision
  vs 51%/43% pooled; Open Yap 32%/74% vs 38%/74%. The score scale is stable across
  calls within a domain, so one fit per domain is enough.
- **gating on the state head** (`state_speak ≥ 0.5`): Open Yap 38% → 25% catch with
  precision *falling* 74% → 67%; live 49% → 18% catch, 45% → 26% precision. The
  conjunction removes true positives and does not buy precision back.

**Open.** The 30 blinded clips still adjudicate whether a "Yes" here is a floor
claim; the head's numbers are agreement with an *audio* handoff definition, not
with human judgement. Nothing above ships: the seam is unchanged, the head is
extra, and the percentile fit is 80 + 33 minutes of two datasets.

### Outcome labels on the 13 live captures (step 0, 2026-11-06)

The relay's seven outcome names were reconstructed offline from the 13 live
captures (1,985 s) by `scripts/live-outcomes.py`: replay the shard's recorded
teacher 8-vectors through the rules with the derived mode track (the same replay
as `live_barge.py`), take the caller's utterances and the agent's playback runs
from the capture's two channels, and apply the relay's predicates verbatim.

| label | count |
| --- | ---: |
| caller utterances / playback runs | 303 / 258 |
| ENDPOINT / BARGE / BACKCHANNEL events | 139 / 57 / 69 |
| `early_cut_in` | 8 |
| `late_endpoint` | 15 |
| `real_barge` | 2 |
| `false_barge` | 1 |
| `missed_barge` | 38 |
| `bc_ok` | 10 |
| `bc_intrusive` | 59 |

Readings. The labels are mechanically derivable: no episode needed a judgement
call, so the step-0 kill criterion passes (the only choices are the rules' own
-50 dB VAD and the 0.2 s bridge). The BARGE split reproduces the release-tail
finding *through the label definition*: of 41 utterances that started inside a
playback run and took the floor, 38 got no barge within 0.64 s (`missed_barge`),
2 did (`real_barge`), and the one short sound that did is a false barge; the
other 54 events fire elsewhere, overwhelmingly in the bridged tail. That is not
the same number as the "43% catch" measured by `handoff-eval.py`, and the gap is the definition: the label compares the event's
*hop end* (`bargeFiredAtS = hopS`) to the utterance start, so a crossing late in
the hop lands outside 0.64 s even when the head's peak is inside the finer
window. Treat the label as the product's current accounting, not as a catch
metric. `late_endpoint` at 15/139 endpoints (10.8%) is likewise the relay's
endpoint-time measure, not the "naive ≥1.2 s gap" count that the open question
after this section rejects.

Approximations the capture cannot remove: the relay's "loud" is any nonzero
20 ms mic chunk; offline we use the rules' -50 dB VAD per 80 ms frame and the
relay's 0.2 s bridge. `replyStartS` is approximated as the endpoint's hop end
+ 40 ms because TTS latency is not in the capture. Playback runs are ch1 VAD
runs, with backchannel runs excluded by the replay's BACKCHANNEL event time.
`--events student` replays the unshipped L4 student instead (11 BARGE over the
same 13 captures; its yield stays below 0.5 on the first capture) — a tier
comparison, not the existing vocabulary.

### Shadow comparison on the same captures (step 2, 2026-11-06)

`--policies level,edge,edge+gate` replays the same teacher events under each
barge policy and derives the same seven labels. `level` is the step-0 baseline
(the rules replay as-is); `edge` keeps a BARGE only on a threshold crossing
(yield below `barge_thr` two frames before the event); `edge+gate` also requires
the agent's own channel to be audible within the gate's lookback. The product's
`tuned()` enables edge and leaves the audibility gate default-off; this
comparison runs each as if enabled.

| policy | BARGE events | real | false | missed | harmful (false+missed) |
| --- | ---: | ---: | ---: | ---: | ---: |
| level | 57 | 2 | 1 | 38 | 39 |
| edge | 32 | 4 | 1 | 36 | 37 |
| edge+gate, firing frame only (`lookup=0`, the landed code) | 6 | 2 | 1 | 38 | 39 |
| edge+gate, 320 ms lookback (`lookup=3`, db=-50, the decision text) | 14 | 4 | 1 | 36 | 37 |

Readings. Edge-triggering is the free win on these labels: 57 → 32 events,
harmful outcomes 39 → 37, and it catches two more real floor-takes (2 → 4). The
audibility gate does **not** improve on edge at either lookback: the landed
firing-frame check removes 26 of the 32 edge events but loses 2 of the 4 real
catches, leaving harmful outcomes at the baseline 39; a 320 ms lookback keeps
all 4 real catches but lands at 14 events and the same harmful 37 as edge
alone. So the gate reduces event counts without reducing harmful outcomes —
the plan's kill criterion — and stays default-off. Its real acceptance
(strict-overlap catch) is not measured by these labels: `missed_barge` counts
floor-takes after the agent has stopped, where a barge action has nothing to
stop. Step 1's audio audit still decides. This is the definition gap the
section above names, now with a number on it.

The comparison is an event-stream approximation: filtering happens after the
rules replay, so the rules' internal state evolves as if the suppressed barge
fired. `barge_gate.py` uses the same pattern. A state-faithful replay would need
the policy flags in the Python rules port.

## References

- `scripts/live-outcomes.py` — step 0's offline label derivation and step 2's
  policy comparison; `--selfcheck` pins the seven predicates.

- `docs/voice-tyger-ondevice.md` — per-tier guard numbers, precision rulings, the
  incremental-KV failure record.
- `docs/voice-tyger-s2s-comparison.md` — their live thresholds and the I-17/I-26
  error classes.
- `docs/voice-decisions.md` — decision-log schema, fine-tuning loop, guardrails.
- `docs/voice-tyger-streaming-plan.md` — the shared-encoder ruling and the L15 tap.
- `ports/tyger-mlx/turn_taker.py` — the decision model's exact anatomy (fuse →
  3-layer GRU → five heads).
- `ports/tyger-student/slow_state.py`, `slow_model.py`, `slow_train.py` — the P6
  serializer, decoder shapes and their reproducible eval (`--selfcheck` each).
