#!/usr/bin/env python3
"""Synthesize reference clips for idfon's Phonon voices by blending Kokoro style vectors.

Each voice below is a weighted blend of two Kokoro-82M voice style vectors, spoken
through a fixed reference script. The clips feed Phonon's speaker encoder
(xn-ptts `create_voice`) to make 256KB voice embeddings. Fully synthetic chain:
Kokoro blends -> clip -> Phonon embedding. No real speakers anywhere.

    uv run --with kokoro --with misaki[en] --with soundfile --with torch \
        scripts/blend-kokoro-voices.py OUTDIR [NAME ...]

Writes OUTDIR/NAME.wav (24 kHz mono). Names default to the full set.
Kokoro weights/voices download from hexgrad/Kokoro-82M on first run.
"""
import sys
from pathlib import Path

# name: (voice_a, weight_a, voice_b, weight_b)
VOICES = {
    "Clara": ("af_bella", 0.50, "af_sarah", 0.50),
    "Nora":  ("bf_emma", 0.60, "bf_isabella", 0.40),
    "Iris":  ("af_nicole", 0.50, "bf_lily", 0.50),
    "Ada":   ("af_heart", 0.50, "af_jessica", 0.50),
    "June":  ("af_sky", 0.55, "bf_alice", 0.45),
    "Owen":  ("am_michael", 0.55, "bm_daniel", 0.45),
    "Felix": ("bm_lewis", 0.50, "am_liam", 0.50),
    "Miles": ("am_fenrir", 0.50, "bm_george", 0.50),
    "Theo":  ("am_adam", 0.55, "am_eric", 0.45),
}

# ~15 s of clean, varied speech: the Phonon clone and audition listen to this.
SCRIPT = (
    "Hi, this is my voice. I like reading in the morning, when everything is quiet. "
    "On weekends I walk down to the market, and then I make coffee and call a friend. "
    "There is nothing better than a slow conversation on a rainy afternoon."
)


def main() -> None:
    outdir = Path(sys.argv[1] if len(sys.argv) > 1 else "clips")
    names = sys.argv[2:] or list(VOICES)
    outdir.mkdir(parents=True, exist_ok=True)

    import soundfile as sf
    import torch
    from huggingface_hub import hf_hub_download
    from kokoro import KPipeline

    def style(name: str) -> torch.Tensor:
        p = hf_hub_download("hexgrad/Kokoro-82M", f"voices/{name}.pt")
        return torch.load(p, weights_only=True)

    pipeline = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
    for name in names:
        a, wa, b, wb = VOICES[name]
        vec = style(a) * wa + style(b) * wb
        chunks = [audio for _, _, audio in pipeline(SCRIPT, voice=vec, speed=1.0)]
        clip = torch.cat(chunks)
        wav = clip.numpy()
        sf.write(outdir / f"{name}.wav", wav, 24000)
        print(f"ok {name}: {len(wav)/24000:.1f}s <- {a}*{wa} + {b}*{wb}")


if __name__ == "__main__":
    main()
