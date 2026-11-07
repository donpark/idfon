# Voice samples: a voice is a 10-second clip and its text

Status: **design** (2026-11-07, Don's direction: "design around 10 sec audio
clips at the base, making TTS just how agent voice gets generated to meet that
audio clip requirement"). Supersedes the voice-file-first thinking: the
`.safetensors` embedding becomes a derived cache, not the artifact.

## The rule

One representation for every voice — human or agent:

| Field | What | Size |
| --- | --- | --- |
| `audio` | ~10 s of clear single-speaker speech | ~256 KB processed, ~0.5 MB raw wav |
| `text` | the transcript of that clip | one or two sentences |

That pair **is** the voice. Nothing else is saved: no voice catalogs, no long
recording archives, no per-model embeddings as the source of truth.

## Why

- **Recreatable anywhere, locally.** xn-ptts conditions from the clip and its
  text (`ptts --voice <clip.wav>`; the transcript feeds the
  `transcript_in_segment` conditioning). No Gradium, no network at replay. The
  old "encoder wall" (2026-10-31) is gone with blixt's faster/smaller xn-ptts
  CoreML build — the runtime base is that pack, not the original gradium f32
  checkpoint (which may not survive cache cleanups anyway).
- **Uniform.** An agent's voice is made by generating the clip with its
  configured TTS once — TTS is just how an agent voice meets the clip
  requirement — after which it behaves exactly like a recorded human voice.
  Mixing voices = generate/re-voice a clip and blend latents (the
  Phonon+Kokoro precedent: `scripts/blend-phonon-voices.py`).
- **Small and migratable.** A sample survives model swaps; an embedding may
  not (voice files record `model_ext` and are refused across checkpoints).

## Creation paths

1. **Record** (human voice): ~10 s of clear speech plus its transcript.
   Consent is the speaker's to give — "clone only voices you have the
   speaker's consent to use" (the xn-ptts `clone-voice.py` rule stands).
2. **Synthesize** (agent voice): run the agent's configured TTS over a fixed
   ~10 s prompt once; the clip becomes the voice. The TTS provider can change
   later without changing the voice — the sample is the voice.
3. **Re-voice / blend** (derived): synthesize through another voice or blend
   sample latents weighted (the mix recipes in
   `scripts/phonon-voice-compare.py`).

## Recreation (the engine seam)

- Sample → conditioning: the engine speaker-encodes the clip and takes the
  text as the prompt transcript. The CLI does this today; the app seam does
  not: `ptts_set_voice` / `load_voice` accept only `voices/<name>.safetensors`
  (`emb`, optional `conditions`). Build one of:
  - **derive-once** (smaller): clip → `emb` → `voices/<name>.safetensors`,
    then the existing name-based `setVoice` works — the embedding is a cache
    the sample can regenerate any time; or
  - **FFI**: `ptts_set_voice_from_clip` in ptts-ffi/PhononTTS so the app
    embeds the clip itself.
- The derived embedding lives beside the sample (the pack's `voices/` dir);
  it may be dropped and rebuilt.

## Shape on disk

`<name>.wav` + `<name>.json` — the transcript and provenance as a sidecar:
`{ text, language, name, source: "recorded" | "synthesized" | "revoiced",
consent, created }`. (Folding `text` into the safetensors `conditions` header
is possible later; the sidecar is the smallest thing every tool can read.)

## Consumers in idfon

- **#202 replay voices**: the replay voice is the user's sample ("My Voice");
  the caller-turn clone fallback replays from it. Today's picker lists cached
  embeddings; the sample model makes any clip a voice.
- **Contact/agent voice identity**: a contact may carry its voice sample
  (contact card / blob ticket) so a fresh device speaks as the agent with no
  catalog download.
- **Voice messages and voice prompts** (future): sample + text is enough to
  re-speak in the voice anywhere.

## Privacy and consent (unchanged from #202)

- Only the user's own voice or the agent's configured voice; no third-party
  cloning. Creation needs consent; the sample records its provenance.
- Recreation and replay are local and send no audio anywhere. Voice
  *creation* may use the network (TTS to generate an agent's clip, a clone
  service at authoring time); replay never does.

## Migration

Named voices already in the pack's `voices/` stay valid — they are the
derived-cache form of samples. New voices enter as samples; the derive-once
step is the only place an embedding is produced.
