# Voice calibration registry

Status: **living** (started 2026-10-26). The improvement pipeline's memory —
what each calibration round taught, so proposals get smarter instead of
repeating mistakes. Point the bench at an audio target, score, keep what
scores better, write the lesson here (Harness2's outer loop).

## The loop

1. **Target**: an audio instance or collection to match — `--target ref.wav`
   or `--target-dir refs/` (the profile is learned from it), or a built-in
   profile (`human-hesitation`).
2. **Knobs**: the agent's tunables — reaction vocabulary and the hum fold
   (`BackchannelFiller`/`TurnFiller`), mouth attack fades, filler prompts and
   timing, turn thresholds.
3. **Probe + score**: `scripts/voice-reaction-bench.py` renders candidates
   through the mouth's model and ranks them with
   `scripts/voice-audio-metrics.py` (onset swell, opening energy). Behavior
   replay (`scripts/corpus-regression.py`) and rubric scoring
   (`scripts/voice-prompt-lab.sh`) are the other scorers.
4. **Propose**: edit the candidate list for now; a mutator
   (`scripts/voice-gepa-mutate.py`) is the automation seam.
5. **Record the lesson here.**

## Lessons

### 2026-10-26 — reaction-word sound (bench: human-hesitation profile)

- Vowel starts are unusable **in every spelling**: "Um", "uhm", "ehm", "umm",
  any case, ellipsis or not — all reach full energy within 5 ms of onset (an
  exclamation attack). A human "um" swells in over 150–300 ms.
- What renders soft: murmurs ("Mhm." swells over 145 ms), soft leads
  ("hmm, let me check." — 45 ms), vowels behind a soft first word
  ("So, um, one moment." — 125 ms).
- The text normalizer folds ellipses ("Um..." speaks as "Um."). Softness
  comes from wording, not punctuation.
- Bench ranking (best first): "So, um, one moment.", "hmm, let me check.",
  "Well, one moment.", … every "um/uhm" lead at the bottom. Matches the ear
  verdict that started the round.
- Open: "Mhm." scores last on opening energy though its swell is natural —
  the scorer's opening-energy weight needs its own calibration round. If
  "ums and ahs" are wanted at utterance start, the other knob is a ~120 ms
  attack fade on phatic playback (mouth-side, not yet built).

### 2026-10-26b — UTMOS as the quality floor (second scorer)

- UTMOS (neural MOS, `scripts/utmos-score.py`) gives the pipeline a
  perceptual witness. It confirms the ear on the hums: **"Mhm." = 1.70 MOS,
  "Hmm." = 1.54** — their shape is natural but Phonon's rendering is not.
  The 2026-10-26 "murmurs swell naturally" note gets its correction: the
  swell is right, the sound is wrong.
- In-sentence vowels are quality-fine ("Um, one moment." = 4.21 MOS): their
  problem is onset dynamics, not the sound. Bare "Um." (3.17) and "hmm, let
  me check." (3.54) degrade. The floor demoted both in the ranking.
- Quality-floor policy: a candidate never wins on target-distance below the
  target's own MOS minus 0.25 (or the built-in 4.0 floor).
- Autoresearch found a winner the hand rounds missed: **"so. One moment."**
  (swell 150 ms, head 0.05, MOS fine) — lowercase "so." renders with a
  drawn-out soft onset.

### 2026-10-26c — ear gate passed; the winner ships

- User review of the "Autoresearch winners" clips: **approved**. The
  "so. One moment." family is the hesitation vocabulary.
- Applied to code: the filler lead-in fallback is now `"so. One moment."`
  (`startFillerCover`, both apps; exact spelling kept — the render is the
  audio). Words-only vocabulary and the hum/vowel fold were already shipped.
- The loop's first full cycle is complete: measure target → search → score
  (style + UTMOS floor) → ear gate → ship → registry.

## Knob inventory

| Knob | Where | Scorer |
| --- | --- | --- |
| Reaction vocabulary + hum fold | `BackchannelFiller`, `TurnFiller` (both apps) | voice-reaction-bench |
| **Voice identity** (delivery/attack) | `IDFON_TTS_VOICE` / per-contact voice | voice-audio-metrics |
| Mouth audio modules (Compressor/Gain/Limiter) | ptts `SpeechOptions.post_process` (API-only, not built) | voice-audio-metrics |
| Mouth attack fade (phatic) | playback path (not built) | voice-audio-metrics |
| Filler prompts | `BackchannelFiller.instructions`, `TurnFiller` prompts | voice-prompt-lab |
| Filler timing | `TurnFiller.leadInAfter/fillerGap/maxStill` | corpus replay |
| Turn thresholds | `Thresholds::tuned()` (C ABI) | corpus replay, parity gates |

Scorers: style metrics (`voice-audio-metrics.py`: onset swell, opening
energy, crest — identity metrics like pitch are reported, never scored),
UTMOS quality floor (`utmos-score.py`, torch venv via `UTMOS_PYTHON`),
behavior replay (`corpus-regression.py`), rubric (`voice-prompt-lab.sh`).
Driver: `voice-autoresearch.py` (mechanical proposals, generational search,
round reports; `--selftest`).

### 2026-10-27 — no emotes, but the voice is the expressivity knob

- Phonon has **no emote system** (verified in the tokenizer — zero special
  tokens — and the source: prose in, prose out; the model card's only
  prosody note is that long inputs split at sentences).
- **The voice carries the delivery.** Same text, same model: the default
  voice hits "Um" at 5 ms (exclamation); Hadley swells 110 ms, Trevor
  140 ms — human-shaped. The hot-vowel problem is largely a DEFAULT-VOICE
  trait, not a model law. Voice choice is now a first-class knob
  (`voice-audition.html` "Voice sweep"); per-voice vocabularies are a
  possible refinement.
- The synth has a **native audio-module chain** (Compressor / Gain /
  Limiter, `SpeechOptions.post_process` — API-only, no CLI flag): the
  "exaggerated energy" fix can live inside the mouth without custom DSP.
- Mimi note: Phonon builds on PocketTTS + the Mimi codec (known
  "exaggerated/waterlogged" traits). The codec is not addressable from
  text; voice + modules are the reachable levers. If "waterlogged"
  persists, the mouth choice is the deeper lever (Kokoro is not Mimi).
