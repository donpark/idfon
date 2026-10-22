# tyger-models notices

This repository packages [TYGER](https://huggingface.co/nineninesix/tyger) as
on-device delivery tiers, plus a distilled student turn-taker.

TYGER is developed by [NineNineSix](https://www.nineninesix.ai/).
Copyright 2026 NineNineSix. The `coreai/`, `coreml/` and `mlx/` files are
format and precision exports of TYGER's `model.safetensors` (fp16 for Core AI
and the Core ML encoder; int8-g16 for MLX, with the stem and first layer kept
fp32). They are packaging changes; no weights were retrained. In the original
archive, NVIDIA's tensors are preserved under the `nemotron.` prefix inside
the combined `model.safetensors` and the GRU controller tensors use the
`turn_taker.` prefix.

The ASR component is NVIDIA's Nemotron 3.5 ASR Streaming 0.6B, revision
`ea30d66debe3740a08b573244286791d423d6b3e`, distributed under OpenMDW-1.1
with NVIDIA's own grant. NVIDIA's notices are retained in the upstream TYGER
repository: its model card and figures in
[`upstream/`](https://huggingface.co/nineninesix/tyger/tree/main/upstream)
and NVIDIA's copy of the license in
[`licenses/OpenMDW-1.1.txt`](https://huggingface.co/nineninesix/tyger/tree/main/licenses).

`pathc/TygerStepStudent.mlpackage` is a separately trained model: the TYGER
turn-taker's head architecture, retrained by distillation from TYGER on the
[dualturn-otospeech-turn-taking](https://huggingface.co/datasets/anyreach-ai/dualturn-otospeech-turn-taking)
corpora. Its feature tap, Parakeet Redux
([FluidInference/parakeet-redux-coreml](https://huggingface.co/FluidInference/parakeet-redux-coreml)),
is used at runtime and is not included in this repository.

Training and evaluation data are not included here and keep their own terms:
[Open Yap 1K](https://theagenticdatacompany.com/open-yap-1k) (TYGER's training
corpus) and the dualturn-otospeech-turn-taking corpora (the student's).
