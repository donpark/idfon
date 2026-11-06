"""Stage our 42/13 encoder export into a copy of the 3.5 multilingual bundle.

Why this is not `tools/asr-tap-latency/stage_models.py`: the English manager feeds
five encoder inputs and has no `prompt_id`, so that script bakes `prompt_id=101`
into the MIL program. The multilingual manager feeds `prompt_id` as a real input,
which is what our export declares. So here the artifact goes in **unmodified** and
the prompt stays a runtime value — the test is whether our encoder transcribes
through their multilingual decoder, not whether a baked constant can be shipped.

Everything except `encoder/` is symlinked from the downloaded bundle (decoder,
joint, tokenizer, caches config), so nothing is copied twice and no published dir
is touched.

Usage:
  ports/tyger-student/.venv/bin/python tools/asr-bundle-swap/stage_models.py \
      --bundle bench-results/asr-bundle-swap/hf/multilingual/560ms \
      --encoder bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage \
      --out bench-results/asr-bundle-swap/models/staged-560ms --verify
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path

import numpy as np

SHARED = ("decoder.mlmodelc", "decoder_joint.mlmodelc", "joint.mlmodelc", "tokenizer.json")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bundle", required=True, help="downloaded <lang>/560ms dir")
    ap.add_argument("--encoder", required=True, help="our tap-declaring .mlpackage")
    ap.add_argument("--out", required=True, help="staged model dir (must not be a bundle)")
    ap.add_argument("--prompt-id", type=int, default=0, help="en-US, used by --verify")
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args()

    import coremltools as ct

    bundle = Path(os.path.expanduser(args.bundle)).resolve()
    encoder = Path(os.path.expanduser(args.encoder)).resolve()
    out = Path(os.path.expanduser(args.out)).resolve()
    assert bundle != out, "refusing to stage over the downloaded bundle"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    for name in SHARED:
        os.symlink(bundle / name, out / name)

    meta = json.loads((bundle / "metadata.json").read_text())
    spec = ct.models.MLModel(str(encoder)).get_spec()
    inputs = [i.name for i in spec.description.input]
    assert "prompt_id" in inputs, f"artifact has no prompt_id input: {inputs}"
    depth = int(next(i for i in spec.description.input if i.name == "cache_channel")
                .type.multiArrayType.shape[2])
    mel_frames = int(next(i for i in spec.description.input if i.name == "mel")
                     .type.multiArrayType.shape[2])
    # The published 3.5 artifacts ship att_context_size [42, 13]; our export was
    # built for the same contract, so both must agree or this is not the same tier.
    assert meta["cache_channel_shape"] == [1, 24, depth, 1024], meta["cache_channel_shape"]
    assert meta["total_mel_frames"] == mel_frames, (meta["total_mel_frames"], mel_frames)
    (out / "metadata.json").write_text(json.dumps(meta, indent=2))
    print(f"metadata: cache_channel_shape {meta['cache_channel_shape']} (depth {depth}), "
          f"chunk {meta['chunk_mel_frames']} mel / {meta['chunk_mel_frames'] * 10} ms, "
          f"total {meta['total_mel_frames']}, prompt_dictionary "
          f"{len(meta['prompt_dictionary'])} entries, default {meta['default_prompt_id']}")

    if args.verify:
        # The prompt must stay live: same audio, two prompt ids, different frames.
        rng = np.random.default_rng(0)
        base = {
            "mel": rng.standard_normal((1, 128, mel_frames)).astype(np.float32),
            "mel_length": np.array([mel_frames], np.int32),
            "cache_channel": np.zeros((1, 24, depth, 1024), np.float32),
            "cache_time": np.zeros((1, 24, 1024, 8), np.float32),
            "cache_len": np.array([1], np.int32),
        }
        m = ct.models.MLModel(str(encoder))
        a = m.predict(dict(base, prompt_id=np.array([args.prompt_id], np.int32)))["encoded"]
        b = m.predict(dict(base, prompt_id=np.array([101], np.int32)))["encoded"]
        d = float(np.max(np.abs(a - b)))
        print(f"prompt sensitivity: en-US ({args.prompt_id}) vs auto (101) max|d| = {d:.3g}")
        assert d > 0, "prompt_id has no effect — the artifact would not be a native prompt path"

    subprocess.run(["xcrun", "coremlcompiler", "compile", str(encoder), str(out)], check=True)
    # coremlcompiler names the output after the package; the manager looks for `encoder`.
    (out / f"{encoder.stem}.mlmodelc").rename(out / "encoder.mlmodelc")
    enc = out / "encoder.mlmodelc"
    assert enc.is_dir(), enc
    print(f"staged: {out} (encoder compiled from {encoder.name}, prompt_id kept as input)")


if __name__ == "__main__":
    main()
