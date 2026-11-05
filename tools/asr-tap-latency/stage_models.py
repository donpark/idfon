"""Stage a model directory the shipping app's `StreamingNemotronAsrManager` can load,
with our tap-declaring encoder export in place of the stock one.

Instrumentation only: no weight, pass or threshold changes. Two packaging facts make
the staged dir differ from `~/.idfon/models/nemotron-streaming/560ms`:

1. **cache depth.** The 42/13 export declares a fixed `cache_channel [1,24,42,1024]`,
   and the manager sizes its caches from `metadata.json` (`cache_channel_shape`,
   70 in the shipping bundle = the 56/0 pass). The staged metadata says 42.
2. **prompt_id.** Our export declares `prompt_id [1]` (the multilingual manager's
   contract); `StreamingNemotronAsrManager.processChunk` feeds only mel/mel_length/
   cache_channel/cache_time/cache_len, so Core ML rejects the call with
   "Feature prompt_id is required but not specified". The staged copy bakes
   `prompt_id = 101` (the export's own default, `asr_tap.py`'s
   `default_prompt_id`) into the MIL program as a const — a packaging fix that
   leaves every weight and op untouched. `--verify` proves the baked model's
   outputs are bit-identical to the 6-input artifact's.

Usage:
  ports/tyger-student/.venv/bin/python tools/asr-tap-latency/stage_models.py \
      --encoders ~/.idfon/models/nemotron-streaming/560ms \
      --tap bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage \
      --out bench-results/asr-manager-probe/models/560ms
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path

import numpy as np


STRING, INT32 = 2, 23  # MILSpec.DataType


def bake_prompt(spec, pid: int = 101):
    """Replace the `prompt_id` program input with a const of `pid` (MIL proto edit)."""
    fn = spec.mlProgram.functions["main"]
    assert [v.name for v in fn.inputs].count("prompt_id") == 1, \
        "artifact has no prompt_id program input"
    # The prompt is consumed as `cast(prompt_id, int16) -> gather(prompt_eye, idx)`;
    # only the reference has to change, so every consumer is retargeted at the const.
    retargeted = 0
    for key, block in fn.block_specializations.items():
        # MIL op lists must stay topologically sorted: the const goes right
        # before its first consumer, not at the end.
        first = min((k for k, op in enumerate(block.operations)
                     if any(v.name == "prompt_id" for a in op.inputs.values()
                            for v in a.arguments)), default=0)
        const = type(block.operations[0])()
        const.type = "const"
        out = const.outputs.add()
        out.name = "prompt_id_const"
        tt = out.type.tensorType
        tt.dataType = INT32
        tt.rank = 1
        tt.dimensions.add().constant.size = 1
        for attr, value in (("val", [pid]), ("name", ["prompt_id_const"])):
            a = const.attributes[attr]
            at = a.type.tensorType
            at.dataType = STRING if attr == "name" else INT32
            at.rank = 1
            at.dimensions.add().constant.size = 1
            got = a.immediateValue.tensor
            if attr == "name":
                got.strings.values.append("prompt_id_const")
            else:
                got.ints.values.extend(value)
        for op in block.operations:
            for arg in op.inputs.values():
                for v in arg.arguments:
                    if v.name == "prompt_id":
                        v.name = "prompt_id_const"
                        retargeted += 1
        block.operations.insert(first, const)
    assert retargeted, "no op consumed prompt_id"
    kept = [v for v in fn.inputs if v.name != "prompt_id"]
    fn.ClearField("inputs")
    for v in kept:
        fn.inputs.add().CopyFrom(v)
    # The model's own interface (what MLFeatureProvider is validated against) is
    # `description`, not the program's value list: drop it there too.
    desc = [v for v in spec.description.input if v.name != "prompt_id"]
    spec.description.ClearField("input")
    for v in desc:
        spec.description.input.add().CopyFrom(v)
    return retargeted


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--encoders", default="~/.idfon/models/nemotron-streaming/560ms")
    ap.add_argument("--tap",
                    default="bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage")
    ap.add_argument("--out", default="bench-results/asr-manager-probe/models/560ms")
    ap.add_argument("--prompt-id", type=int, default=101)
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args()

    import coremltools as ct

    src = Path(os.path.expanduser(args.encoders))
    tap = Path(args.tap)
    out = Path(os.path.expanduser(args.out))
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    # Shipping decoder / joint / tokenizer / metadata; only encoder/ is replaced.
    for name in ("decoder.mlmodelc", "joint.mlmodelc", "decoder_joint.mlmodelc",
                 "tokenizer.json"):
        if (src / name).exists():
            os.symlink((src / name).resolve(), out / name)
    meta = json.loads((src / "metadata.json").read_text())
    depth = int(ct.models.MLModel(str(tap)).get_spec().description.input[2]
                .type.multiArrayType.shape[2])
    meta["cache_channel_shape"] = [1, 24, depth, 1024]
    (out / "metadata.json").write_text(json.dumps(meta, indent=2))
    print(f"metadata: cache_channel_shape -> {meta['cache_channel_shape']} "
          f"(artifact depth {depth})")

    # Copy the package (weights included), patch only the program protobuf, then
    # compile it so the staged dir holds a real .mlmodelc like the shipping one.
    (out / "encoder").mkdir()
    pkg = out / "encoder" / "encoder_int8.mlpackage"
    shutil.copytree(tap, pkg, symlinks=True)
    model_pb = pkg / "Data" / "com.apple.CoreML" / "model.mlmodel"
    spec = ct.models.MLModel(str(tap)).get_spec()  # load by .mlpackage, not the staged name
    n = bake_prompt(spec, args.prompt_id)
    model_pb.write_bytes(spec.SerializeToString())
    print(f"baked prompt_id={args.prompt_id}: {n} consumer(s) retargeted -> {pkg}")

    patched = ct.models.MLModel(str(pkg))
    names = [i.name for i in patched.get_spec().description.input]
    print("staged encoder inputs:", names)
    assert names == ["mel", "mel_length", "cache_channel", "cache_time", "cache_len"], names

    if args.verify:
        rng = np.random.default_rng(0)
        mel = rng.standard_normal((1, 128, 65)).astype(np.float32)
        ch = rng.standard_normal((1, 24, depth, 1024)).astype(np.float32)
        tm = rng.standard_normal((1, 24, 1024, 8)).astype(np.float32)
        base = {"mel": mel, "mel_length": np.array([65], np.int32),
                "cache_channel": ch, "cache_time": tm, "cache_len": np.array([1], np.int32)}
        ref = ct.models.MLModel(str(tap)).predict(dict(base, prompt_id=np.array([args.prompt_id], np.int32)))
        got = patched.predict(base)
        worst = {k: float(np.max(np.abs(np.asarray(got[k], np.float64) -
                                       np.asarray(ref[k], np.float64))))
                 for k in ref}
        print("baked vs 6-input max|d|:", {k: f"{v:.3g}" for k, v in worst.items()})
        assert worst["encoded"] == 0.0 and worst["tap_l4"] == 0.0, worst
        print("verify: baked prompt_id is bit-identical to the artifact's own default")

    subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg),
                    str(out / "encoder")], check=True)
    shutil.rmtree(pkg)
    enc = out / "encoder" / "encoder_int8.mlmodelc"
    assert enc.is_dir(), enc
    print(f"staged model dir: {out} (encoder {enc.name})")


if __name__ == "__main__":
    main()
