#!/usr/bin/env python3
"""Render the idfon voice-compare page: blended Phonon voices vs their source voices.

Each idfon voice is a weighted blend of two Phonon catalog voices' `speaker_wavs`
latents (pure local math — no Gradium API). This renders every blend, its two
sources and the checkpoint default voice over the same audition lines with the
`ptts` CLI, and writes docs/voice-compare.html next to the audio.

    scripts/phonon-voice-compare.py [--ptts PATH] [--kokoro-clips DIR] [--force]

Audio and blended voice files land in docs/voice-compare-audio/ (gitignored,
regenerable). Existing wavs are reused; --force re-renders. The blended
voice files in docs/voice-compare-audio/voices/ are what gets provisioned to
~/.idfon/models/phonon/voices/ once a set is approved.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

# name: [(catalog voice, weight), ...] — see ptts --list-voices for the catalog.
VOICES = {
    "Clara": [("Maeve", 0.5), ("Harper", 0.5)],
    "Nora":  [("Everly", 0.55), ("Imogen", 0.45)],
    "Iris":  [("Hadley", 0.5), ("Delia", 0.5)],
    "Ada":   [("Zoey", 0.5), ("Freya", 0.5)],
    "June":  [("Elodie-Rose", 0.5), ("Juniper", 0.5)],
    "Owen":  [("Edwin", 0.5), ("Preston", 0.5)],
    "Felix": [("Easton", 0.5), ("Alfie", 0.5)],
    "Milo":  [("Trevor", 0.5), ("Micah", 0.5)],
    "Theo":  [("Hugh", 0.5), ("Spencer", 0.5)],
}

# (label, text) — identity, timbre, idfon-relevant hesitations, prosody, flow.
LINES = [
    ("identity", "Hi, this is my voice."),
    ("timbre", "I like reading in the morning, when everything is quiet."),
    ("hesitation", "Um, one moment. Let me check the time in Tokyo."),
    ("question", "Wait — did you hear that?"),
    ("flow", "There is nothing better than a slow conversation on a rainy afternoon."),
]
GLANCE = "Hello. I will be your assistant today — what can I do for you?"

# Kokoro-clip names for the "other route" section (blend-kokoro-voices.py output).
KOKORO = ["Clara", "Nora", "Iris", "Ada", "June", "Owen", "Felix", "Miles", "Theo"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ptts", default="ptts", help="ptts CLI build (default: ptts on PATH)")
    ap.add_argument("--kokoro-clips", default="/tmp/kokoro-clips", type=Path)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    out = root / "docs" / "voice-compare-audio"
    src_dir, voice_dir, audio_dir = out / "src", out / "voices", out / "audio"
    for d in (src_dir, voice_dir, audio_dir):
        d.mkdir(parents=True, exist_ok=True)

    # Resolve catalog voice names to ids through the CLI itself.
    listing = subprocess.run([args.ptts, "--list-voices"], capture_output=True, text=True).stdout
    ids = {m.group(1): m.group(2) for m in
           (re.match(r"(\S+)\s+\S+\s+(\S+)", ln) for ln in listing.splitlines()) if m}

    import numpy as np
    from safetensors import safe_open
    from safetensors.numpy import save_file

    def source(name: str) -> Path:
        """The catalog voice's latent file, downloaded once."""
        path = src_dir / f"{name.lower()}.safetensors"
        if not path.exists():
            import urllib.request
            url = f"https://huggingface.co/gradium/phonon-voices/resolve/main/voices/{ids[name]}.safetensors"
            urllib.request.urlretrieve(url, path)
            print(f"fetched {name}")
        return path

    def tensors(path: Path) -> dict:
        with safe_open(path, framework="np") as f:
            return {k: f.get_tensor(k) for k in f.keys()}

    # Blend the voices.
    for name, recipe in VOICES.items():
        blend_path = voice_dir / f"{name}.safetensors"
        if blend_path.exists() and not args.force:
            continue
        parts = [(tensors(source(src))["speaker_wavs"] * w) for src, w in recipe]
        shapes = {p.shape for p in parts}
        if len(shapes) != 1:
            sys.exit(f"{name}: source latents disagree on shape: {shapes}")
        save_file({"speaker_wavs": sum(parts).astype(np.float32)}, blend_path)
        print(f"blended {name}")

    def render(key: str, text: str, voice: Path | None) -> Path:
        wav = audio_dir / f"{key}.wav"
        if wav.exists() and not args.force:
            return wav
        cmd = [args.ptts, "--lang", "en", "-o", str(wav)]
        if voice is not None:
            cmd += ["--voice", str(voice)]
        cmd.append(text)
        subprocess.run(cmd, capture_output=True, check=True)
        return wav

    # Render every voice over every line (sources dedupe across recipes).
    jobs = {}  # key -> (label, text, voice-path-or-None, chips)
    for name, recipe in VOICES.items():
        for i, (label, text) in enumerate(LINES):
            jobs[f"{name.lower()}-{i}"] = (name, i, text, voice_dir / f"{name}.safetensors")
            for src, _ in recipe:
                jobs[f"src-{src.lower()}-{i}"] = (src, i, text, source(src))
    for i, (label, text) in enumerate(LINES):
        jobs[f"default-{i}"] = ("default", i, text, None)
    for key, (_, _, text, voice) in jobs.items():
        render(key, text, voice)
    for key, text, voice in (
        [(f"{n.lower()}-glance", GLANCE, voice_dir / f"{n}.safetensors") for n in VOICES]
        + [("default-glance", GLANCE, None)]
        + [(f"src-{s.lower()}-glance", GLANCE, source(s))
           for r in VOICES.values() for s, _ in r]
    ):
        render(key, text, voice)
    print(f"rendered {len(jobs) + len(VOICES) + 1} clips")

    html = build_html(out, args.kokoro_clips)
    page = root / "docs" / "voice-compare.html"
    page.write_text(html)
    print(f"wrote {page}")


def build_html(out: Path, kokoro_clips: Path) -> str:
    def player(key: str, chip: str, cls: str) -> str:
        return (f'<div class="v"><span class="chip {cls}">{chip}</span>'
                f'<audio controls preload="none" src="voice-compare-audio/audio/{key}.wav"></audio></div>')

    def rows(name: str, recipe) -> str:
        out_rows = []
        for i, (label, text) in enumerate(LINES):
            tri = player(f"src-{recipe[0][0].lower()}-{i}", recipe[0][0], "src") \
                + player(f"{name.lower()}-{i}", name, "new") \
                + player(f"src-{recipe[1][0].lower()}-{i}", recipe[1][0], "src")
            out_rows.append(f'<div class="line"><div class="text">{label}: “{text}”</div>'
                            f'<div class="tri">{tri}</div></div>')
        return "".join(out_rows)

    cards = []
    for name, recipe in VOICES.items():
        mix = " + ".join(f"{s} ×{w:g}" for s, w in recipe)
        cards.append(f'<h2>{name} <span class="recipe">— {mix}</span></h2>{rows(name, recipe)}')
    glance = "".join(
        f'<div class="row"><span class="word">{n}</span>'
        f'<audio controls preload="none" src="voice-compare-audio/audio/{n.lower()}-glance.wav"></audio></div>'
        for n in list(VOICES) + ["default"]
    )
    default_rows = "".join(
        f'<div class="line"><div class="text">{label}: “{text}”</div>'
        f'<div class="tri">{player(f"default-{i}", "default", "def")}</div></div>'
        for i, (label, text) in enumerate(LINES)
    )
    kokoro = ""
    have = [(n, kokoro_clips / f"{n}.wav") for n in KOKORO]
    have = [(n, p) for n, p in have if p.exists()]
    if have:
        dest = out / "kokoro"
        dest.mkdir(exist_ok=True)
        rows_k = []
        for n, p in have:
            q = dest / p.name
            if not q.exists():
                q.write_bytes(p.read_bytes())
            rows_k.append(f'<div class="row"><span class="word">{n}</span>'
                          f'<audio controls preload="none" src="voice-compare-audio/kokoro/{p.name}"></audio></div>')
        kokoro = (
            '<h2>Kokoro blend clips <span class="recipe">— the other route</span></h2>'
            '<p class="lead">Synthetic clips of blended Kokoro voices (scripts/blend-kokoro-voices.py). '
            'Turning these into Phonon voices needs Gradium\'s speaker encoder (the API); '
            'the blends above need nothing.</p>' + "".join(rows_k)
        )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>idfon voices — blend vs sources</title>
<style>
  body {{
    margin: 0 auto; max-width: 56rem; padding: 2.5rem 1.25rem 4rem;
    font-family: "Iowan Old Style", Charter, Georgia, serif;
    color: #1C2A24; background: #F2F5F3; line-height: 1.6;
  }}
  h1 {{ font-size: 1.75rem; margin: 0 0 0.75rem; }}
  p.lead {{ color: #58685F; margin: 0 0 1.25rem; max-width: 60ch; }}
  h2 {{
    font-family: system-ui, sans-serif; font-size: 0.8125rem; font-weight: 600;
    color: #58685F; margin: 2.25rem 0 0.5rem; padding-bottom: 0.5rem;
    border-bottom: 2px solid #1C2A24;
  }}
  h2 .recipe {{ font-weight: 400; text-transform: none; letter-spacing: 0; }}
  .row {{
    display: flex; align-items: center; gap: 1.25rem;
    padding: 0.5rem 0; border-bottom: 1px solid #C9D2CC;
  }}
  .row .word {{ width: 9rem; flex: none; }}
  .line {{ padding: 0.75rem 0; border-bottom: 1px solid #C9D2CC; }}
  .line .text {{ color: #58685F; font-size: 0.9375rem; margin-bottom: 0.375rem; }}
  .tri {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.75rem; }}
  .v {{ display: flex; flex-direction: column; gap: 0.25rem; }}
  .chip {{
    font-family: system-ui, sans-serif; font-size: 0.6875rem; font-weight: 600;
    letter-spacing: 0.03em; text-transform: uppercase; color: #58685F;
  }}
  .chip.new {{ color: #1C2A24; }}
  .chip.new::before {{ content: "★ "; }}
  .chip.def {{ font-style: italic; }}
  audio {{ width: 100%; height: 2rem; }}
  .row audio {{ width: 22rem; }}
  footer {{ margin-top: 2.5rem; color: #58685F; font-size: 0.9375rem; max-width: 60ch; }}
  code {{ font-family: ui-monospace, Menlo, monospace; font-size: 0.875em; }}
</style>
</head>
<body>

<h1>idfon voices — blend vs sources</h1>
<p class="lead">
  Nine candidate voices for idfon, each a weighted blend of two Phonon catalog
  voices (their conditioning latents averaged — local math, no API). Every line
  plays the same text three ways: source A, the blend, source B. Pick what sounds
  familiar without being anyone in particular. Run
  <code>scripts/phonon-voice-compare.py</code> to re-render.
</p>

<h2>The set at a glance</h2>
<p class="lead">One sentence across all voices, in order.</p>
{glance}

{"".join(cards)}

<h2>Phonon default <span class="recipe">— the voice being replaced</span></h2>
{default_rows}

{kokoro}

<footer>
  Audio and blend files are regenerable and live in
  <code>docs/voice-compare-audio/</code> (gitignored). Approved blends get
  provisioned to <code>~/.idfon/models/phonon/voices/</code> and picked with
  <code>IDFON_TTS_VOICE=NAME</code>.
</footer>

</body>
</html>
"""


if __name__ == "__main__":
    main()
