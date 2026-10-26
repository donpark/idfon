# tyger-s2s vs idfon — implementation comparison

Status: **reference** (2026-10-25, one-shot audit of `/Users/don/dev/github/tyger-s2s`
against our voice stack). Read with `voice-tyger-streaming-plan.md` — the ranked
gap list below is the evidence behind its build order.

**Scorecard**: rules engine ✅ verified-equal · grid/encoder ✅ equal ·
thresholds ⚠️ drift · turn lifecycle ≈ equivalent-by-topology · barge ❌ missing
`played_s` history trim · backchannel ⚠️ ours fixed-text, theirs contextual ·
mouth chunker ❌ ours not built yet · 2nd ear ❌ ours = their pre-I-17
arrival-order bug · ASR ⚠️ theirs one encoder for both consumers · history ❌
trim contract absent.

## What matches exactly

- **Turn rules**: `rules.py` ↔ `crates/idfon-voice/src/turns.rs` is 1:1
  (fixtures byte-identical, 8 cases/1386 frames). Constants equal: VAD −50 dB,
  MIN_SPEECH 350 ms, WARMUP 6 frames, onset gap 8 frames (640 ms), ONSET_MAX 4 s,
  BARGE_PRE 2 s seed, bc refractory 15 frames (1.2 s), θ 0.2. `state_decision`
  equal. Only the head ends a turn (no silence rule) both sides.
- **The grid**: 16 kHz, 80 ms frame, 320 ms hop, 8 s re-encode window, L15 tap,
  GRU 3×768. Theirs fp32-only ("bf16 changed an event"); ours has guarded lossy
  tiers — the deliberate on-device difference.
- **Turn lifecycle**: their speaking state ends on the page's `played:<id>:<n>`
  playback report (or 2 s past the server's guess); ours ends on the bus's
  chunk completions (`StreamTracker`) — equivalent by construction.

## What differs (ranked; fix order = the plan's build order)

1. **Threshold drift** (trivial): their shipping config (`config/default.yaml`,
   live-tuned 2026-10-13) is `ep_thr 0.915`, `barge_thr 0.4`, `bc_thr 0.4`;
   ours runs the bundle defaults (0.9146 / 0.5 / 0.5) — our barge is less
   sensitive, our backchannels rarer. Their per-conversation sliders found
   these live; `IDFON_TURN_TIER` + `-tygerdemo` are our calibration path.
   Care: `turns.rs` fixtures pin behavior at the defaults — pass thresholds
   explicitly when changing them.
   **Adopted 2026-10-25**: the runtime constructs with `Thresholds::tuned()`
   (0.915 / 0.4 / 0.4) through the C ABI; the library `Default` stays the
   bundle set so the parity fixtures remain byte-comparable.
2. **2nd ear timing** (the deepest fix): they measured arrival-order pairing
   putting the 2nd ear 316–783 ms (median 566) AHEAD of what the user heard
   (I-17) and replaced it with per-mic-block playback tags. Ours is
   arrival-order pairing (`PlaybackBus` notify at schedule time) — the same
   error class, skewing the yield/backchannel heads. On-device we can do
   better than tags: the app owns the playback clock. Acceptance metric to
   copy: their `second_ear.py --echo-db` (agent echo in the mic as mic−ear
   level; their live figure −65…−73 dB).
3. **Barge history trim** (slice 3 spec): their chain is `onset_s` → tags →
   `B {played_s}` → `Speaker.heard(played_s)` (line offsets) →
   `History.add_barged` (heard lines + interrupted marker " —"). Ours stops
   playback but records/reports the FULL reply (recordSpokenTurn runs before
   playback; the agent's context believes it said everything). The contract
   "you only said this much" must cross the AFM/eve boundary.
4. **Chunker** (slice 4 spec): adopt `mouth/chunker.py` wholesale —
   `first_chunk: sentence` (user-tested as much better than `clause`),
   MIN_CHARS 40, SENT_MAX 220, boundaries confirmed only when whitespace
   follows (0.50 / 3,000 / example.com safe), abbreviation + acronym +
   initial exceptions, `say_clean` sanitizer for mouths without
   paralinguistic tags.
5. **Contextual backchannels**: theirs are `filler` LLM calls on the ASR
   partial (≤12 tokens), hum when partial < 4 words, RECENT_ACKS=3 shown to
   the LLM (prompt-only "don't repeat" failed: 17/100 repeats → 0), empty ack
   = no ack. Ours is one fixed cue (round-tripped: "Mm-hmm." renders clean;
   "Mm-hm." phonemizes to "lim"). Our `Event.partial` already carries the
   partial; the loop discards it.
6. **Filler economy**: tool lead-ins ("Checking the time in Tokyo"), "still
   looking" lines (≤2, 0.8 s gaps) — mechanical timing beats prompt preambles.
7. **Floor protocol** (`F`/`G`, 1.2 s silence grant) for proactive speech —
   only when background tasks exist; relevant to the off-device agent's wire.

## Topology notes (for the off-device agent)

Their EARS↔MOUTH wire is the right vocabulary to reuse rather than invent:
`T` turn, `C` backchannel (+ ASR partial), `B` barge (+ `played_s`), `A` reply
audio, `K` backchannel audio (kept apart — our `FeedbackEar` rule), `X` text,
`D` done{barged, bc, proactive}, `F`/`G` floor. Their `halting` state + held
endpoints exist only because MOUTH is remote and async — the semantics our
loop gets for free today and needs explicitly when the loop crosses a wire.

## Where we are ahead

On-device quantized tiers with parity guards (they cannot quantize at all),
fail-open classic turn-taking, the feedback transcript-echo guard (3 s
window), silence check-in, and sub-10 ms cue/reply first audio (Phonon) vs
their LLM-generated acks.
