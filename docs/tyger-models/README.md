---
language:
- en
license: openmdw-1.1
license_link: LICENSE.md
pipeline_tag: audio-classification
base_model:
- nvidia/nemotron-3.5-asr-streaming-0.6b
- FluidInference/parakeet-redux-coreml
tags:
- decision-model
- turn-taking
- endpoint-detection
- barge-in
- backchannel
- full-duplex
- streaming
- on-device
- coreml
- core-ai
- mlx
- gru
- audio
---

# tyger-models

**On-device delivery tiers for [TYGER](https://huggingface.co/nineninesix/tyger)
— an open-weight speech decision model for full-duplex voice agents — plus
`TYGER-Step-Student`, a distilled turn-taker that reads
[Parakeet Redux](https://huggingface.co/FluidInference/parakeet-redux-coreml)
features instead of Nemotron's.**

TYGER knows when to respond, keep listening, yield, and backchannel. This repo
is the shipping form: the same decisions, at device scale, in the formats
iOS and macOS load directly. It holds weights and a download manifest, no
inference code.

## What's here

| Path | Model | Format | Size |
| --- | --- | --- | ---: |
| `coreai/` | TYGER chain (encoder + turn heads) | Core AI `.aimodel`, fp16 | ~0.77 GB |
| `coreml/` | TYGER chain | Core ML `.mlpackage` (encoder fp16, step fp32) | ~0.86 GB |
| `mlx/` | TYGER chain | MLX int8-g16 `.safetensors` (pre-27 macOS) | 1.58 GB¹ |
| `pathc/` | **TYGER-Step-Student** (turn heads only) | Core ML `.mlpackage`, fp32 | **56 MB** |
| `manifest.json` | — | delivery manifest (sha256 per file) | — |

¹ the artifact stores dequantized fp32 weights.

The tiers are interchangeable exports of
[nineninesix/tyger](https://huggingface.co/nineninesix/tyger)'s
`model.safetensors` (638M Nemotron + 14M GRU heads); see that model page for
the architecture, event semantics (endpoint / barge-in / backchannel), guards
and thresholds. `pathc/` is a different animal and is documented below.

## TYGER-Step-Student (`pathc/`)

The turn-taker alone — **14M parameters** (a causal GRU, 3 layers, width 768,
plus the input projections and five output heads; the same architecture as
TYGER's GRU) — retrained to read **Parakeet Redux** encoder features instead of
Nemotron layer-15 features.

**Why:** a voice agent that runs Parakeet for transcription already computes
this model's input. The student shares that encoder pass, so the turn model's
delivery cost collapses from a second ~0.8 GB encoder chain to **56 MB of
heads**, identical across device tiers. Total first-use voice download with
ASR + TTS + this model: ~375 MB.

**Input / output** (per 320 ms hop, same contract as TYGER's step):

| | |
| --- | --- |
| Input features | Parakeet Redux `Preprocessor` + `Encoder` output: 188 rows @ 12.5 Hz × 1,024 dims per stream (user + agent) |
| Tap contract | 15 s right-aligned, zero-padded window (mel_length 1501); run both encoder models **CPU-only** (ANE/GPU drifts from training features and is not faster) |
| Per-frame extras | frame energy + the previous state |
| State | GRU carried state `(3, 1, 768)`, ~9 KiB per conversation |
| Output, per frame | the turn state logits (listen, hold, speak, backchannel) + hazard, yield, backchannel and endpoint scores — 8 numbers |

### Training

Distilled from **TYGER** (the fp32 Nemotron chain as teacher) on dual-channel
English conversation — the
[dualturn-otospeech-turn-taking](https://huggingface.co/datasets/anyreach-ai/dualturn-otospeech-turn-taking)
corpora, codec-round-tripped as in calls: 96 sessions (~4.8 h of frames) for
training, 24 sessions (~1.3 h) held out for evaluation. Targets are the
teacher's per-frame 8-vectors; boundary frames are weighted 3× (MSE, equal
group weighting). 250 + 200 epochs, AdamW with cosine decay. One training
seed. The rules that turn scores into events (warm-up frames, speech gate,
silence fallback) live app-side and are unchanged from tyger-s2s's.

### Evaluation (in use)

Scored by replaying held-out conversations through the full chain and
comparing *behavior* — did the model act at real turn-ends — not frame identity
with the teacher. 24 validation sessions, 156 human turn-ends:

| Metric | Teacher (TYGER) | Student |
| --- | ---: | ---: |
| Real turn-ends caught | 87% | **91%** (142/156) |
| False endpoints / min | 6.2 | 6.7 |
| Backchannel precision / recall | 20% / 48% | 22% / 44% |

Core ML export parity against the training-time framework: max |Δ| 1e-5 over
400 carried-state frames.

**Limits:** English only. The evaluation is recorded conversation replayed
through the pipeline — not a live voice-agent benchmark — and one training
seed. Frame-identity with the teacher is ~48%: the student learns the
teacher's behavior, not its every twitch. Backchannel recall is modest for
teacher and student alike. False-endpoint rates are corpus- and
threshold-dependent; tune thresholds in the app.

## Intended use

Turn-taking control for full-duplex voice agents on device: deciding when the
user has finished, when they cut in, when a backchannel fits, and when to
hold the floor. The agent above it sees only text and turn events.

Not for transcription (use the ASR alongside it), not for safety-critical
decisions, not for non-English speech.

## Delivery format

`manifest.json` pins every file (`name`, `asset`, `sha256`, `bytes`) with a
`url_base`. Files are flattened (`/` → `__`); `name` keeps the bundle-relative
path so a client can recreate the `.mlpackage`/`.aimodel` directory trees and
verify each byte before installing. The format is what an app-side
download-on-first-use store consumes: fetch the manifest, fetch only the
active tier's files.

## License

The `coreai/`, `coreml/` and `mlx/` tiers are exports of
[TYGER](https://huggingface.co/nineninesix/tyger), whose weights and files are
**OpenMDW-1.1**; NVIDIA's original Nemotron card, figures and license terms
travel with that repo (`upstream/`, `licenses/`). This repo's tiers and the
`pathc/` student are distributed under the same **OpenMDW-1.1** terms. See
[LICENSE.md](LICENSE.md) and [NOTICE.md](NOTICE.md).

`TYGER-Step-Student` was trained by distillation from TYGER on the
dualturn-otospeech-turn-taking corpora; see that dataset's own terms for the
training data. Its feature extractor is
[Parakeet Redux](https://huggingface.co/FluidInference/parakeet-redux-coreml)
(used, not redistributed here).

## Provenance & acknowledgments

- **TYGER** — [nineninesix/tyger](https://huggingface.co/nineninesix/tyger)
  (weights), [nineninesix-ai/tyger-s2s](https://github.com/nineninesix-ai/tyger-s2s)
  (Apache-2.0 runtime the rules port follows). Thanks to NineNineSix.
- **Nemotron 3.5 ASR Streaming 0.6B** —
  [nvidia/nemotron-3.5-asr-streaming-0.6b](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b),
  unchanged upstream.
- **Parakeet Redux** —
  [FluidInference/parakeet-redux-coreml](https://huggingface.co/FluidInference/parakeet-redux-coreml).
- **Training data** — The Agentic Data Company's
  [Open Yap 1K](https://theagenticdatacompany.com/open-yap-1k) (TYGER's
  training corpus) and the
  [dualturn-otospeech-turn-taking](https://huggingface.co/datasets/anyreach-ai/dualturn-otospeech-turn-taking)
  corpora (the student's).

## Citation

If you use these tiers, please cite TYGER and its training data:

```bibtex
@misc{tyger_2026,
  author    = {{NineNineSix}},
  title     = {{TYGER}: Speech Recognition and Duplex Turn Control},
  year      = {2026},
  publisher = {NineNineSix},
  url       = {https://huggingface.co/nineninesix/tyger}
}

@misc{openyap_2026,
  author    = {{The Agentic Data Company}},
  title     = {{Open Yap 1K}: 1,000 hours of full-duplex natural conversation},
  year      = {2026},
  url       = {https://theagenticdatacompany.com/open-yap-1k}
}
```
