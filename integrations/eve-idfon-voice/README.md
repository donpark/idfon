# eve-idfon-voice

Shared TypeScript toolkit for idfon voice agents: STT/TTS provider seam, audio
helpers, channel glue, turn heuristics, and voice tool factories. Runs as
source (Node ≥ 24 type-stripping); `node --test test/` is the suite.

## Modules

- `src/providers.ts` — the STT/TTS provider seam (OpenAI-compatible gateway and friends)
- `src/turn.ts` — turn heuristics shared with the Rust `idfon-voice` crate (energy endpointer, silence trim, clause batching, echo suppression)
- `src/audio.ts`, `src/bridge.ts`, `src/wrap.ts`, `src/tools/` — channel glue and voice tool factories

## `src/tyger/` — the tyger decision model in-process

The `nineninesix/tyger` turn-taker as the voice loop's decision layer (the
`tyger` option in `docs/voice-tyger-option.md`; artifacts + gates in
`ports/tyger-onnx/`). No Python in this path: the ONNX bundle runs via
onnxruntime-node.

- `rules.ts` — the tyger rules (ENDPOINT/BARGE/BACKCHANNEL, warmup, MIN_SPEECH,
  debounce, backchannel refractory). Byte-identical to the Python oracle
  (`crates/idfon-voice/tests/data/turns-fixtures.json`).
- `mel.ts` / `mel-filters.ts` — the Nemotron feature extractor (validated ≤2e-3
  vs the Python extractor; measured 1.9e-6).
- `engine.ts` — `TygerEngine`: growing 8 s windows → encoder ×2/hop → 4× step
  per hop with the GRU state threaded (composed chain: max|Δ| 1.4e-5 vs torch).
- `bundle.ts` — `loadBundle()`: the verified model bundle
  (`~/.idfon/models/tyger`, manifest with sha256; `IDFON_TYGER_BUNDLE` overrides).
- `endpointer.ts` — `TygerEndpointer`: wire PCM in, turn decisions out. Used by
  `live-relay.mjs` as the authoritative endpointer with the energy path as
  fail-open fallback (`IDFON_ENDPOINTER=energy` opts out).
- `shadow.ts` — the shadow turn-taker: decision logs from a live call's audio
  (the swap-over convention), plus the shared stream helpers (`stream.ts`).
- `language.ts` — the `IDFON_VOICE_LANG` knob (STT language + the bundle ASR's
  prompt ids).

Corpus decision agreement vs the fp32 oracle: **99.89%** (916/917, ±2 frames)
over 72 min of the `dualturn-otospeech` corpus — see `ports/tyger-onnx/README.md`.
