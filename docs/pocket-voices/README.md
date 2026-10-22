---
license: apache-2.0
base_model:
- kyutai/pocket-tts
- FluidInference/pocket-tts-coreml
- hexgrad/Kokoro-82M
tags:
- text-to-speech
- voice-cloning
- pocket-tts
- kokoro
- on-device
- audio
---

# Kokoro voices for Pocket TTS

Ten familiar Kokoro voices replicated as **Pocket TTS** cloned voices —
`*_audio_prompt.bin` files, **512 KB each** (a 10-second conditioning prompt
in Pocket's audio-prompt format).

| Files | Source voices |
| --- | --- |
| `af_heart`, `af_bella`, `af_nicole`, `af_sarah`, `af_sky`, `af_jessica` | Kokoro US English (female) |
| `am_adam`, `am_michael`, `am_fenrir`, `am_puck` | Kokoro US English (male) |

Each voice was made by synthesizing a ~17-second reference clip with the
Kokoro voice and running Pocket TTS's voice cloning over it. The
`*_probe.wav` files are short samples of each result ("Hi, this is what I
sound like now.").

## Usage

Load a file with `PocketTtsManager.loadClonedVoice(from:)` and pass the result
to `synthesize(text:voiceData:)`, or place the files in an app's pocket
`voices/` directory and select them by name. Pair with the model pack from
[FluidInference/pocket-tts-coreml](https://huggingface.co/FluidInference/pocket-tts-coreml)
(`v4/` small models recommended).

## Provenance

Generated from [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) voices
(Apache-2.0) via Pocket TTS's cloning
([kyutai/pocket-tts](https://huggingface.co/kyutai/pocket-tts),
[FluidInference/pocket-tts-coreml](https://huggingface.co/FluidInference/pocket-tts-coreml)).
These are approximations produced by cloning — not the original Kokoro voice
embeddings — and no Kokoro weights are redistributed here. Pocket TTS is
Kyutai's model; see its terms for the cloning outputs. Distributed under
Apache-2.0 with the attribution above.
