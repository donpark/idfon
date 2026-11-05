"""Export the student decision model to Core AI (.aimodel) — the OS 27+ default voice
tier (docs/voice-tyger-ondevice.md). Same contract and long I/O names as
ports/tyger-coreai/export_turn.py's step (the on-device AOT loader rejects bundles with
terse input names — coreai-model-zoo `conversion/nemotron_asr`), at the student's sizes:

  hidden_user/hidden_agent (1,1,1024) + energy_db (1,1) + state_id (1,1 int32)
  + gru_state (2,1,256) -> decision_vector (1,1,8) + gru_state_next (2,1,256)

fp32: the step tier's precision ruling (the ANE fp16 defect family, p_end drift).
Energy normalisation is in-graph (head_step semantics).

Gate: coreai.runtime replay over real shard frames with the runtime's own carried
state (the live path) vs torch — export_turn.py's limits (decision max|Δ| < 5e-2 or
cos > 0.9999; state stricter at 1e-3).

Usage:  .venv/bin/python ports/tyger-student/export_coreai.py [--student ...]
        [--shards bench-results/student-shards/val] [--frames 48]
Output: bench-results/student-coreai/student_step_float32.aimodel + parity.md
"""
import argparse
import asyncio
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]

from export import StepWrap, load_student  # noqa: E402


async def gate(path, frames, wrap, width, layers, n):
    import coreai.runtime as rt

    ok_all = True
    for unit in ("gpu", "cpu"):
        opts = (rt.SpecializationOptions.cpu_only() if unit == "cpu"
                else rt.SpecializationOptions.from_preferred_compute_unit_kind(
                    getattr(rt.ComputeUnitKind, unit)()))
        try:
            m = await rt.AIModel.load(str(path), opts)
        except Exception as e:  # e.g. the CPU specialization fails on big graphs
            print(f"[gate {unit}] SKIP (load: {str(e)[:60]})", flush=True)
            continue
        fn = m.load_function("main")
        st_c = np.zeros((layers, 1, width), np.float32)
        import torch
        st_t = torch.zeros(layers, 1, width)
        worst = state_worst = 0.0
        with torch.no_grad():
            for f in range(n):
                a = torch.tensor([[float(frames["energy"][f])]])
                ps = torch.tensor([[int(frames["prev_state"][f])]])
                o_t, st_t = wrap(torch.as_tensor(frames["hu"][f])[None, None],
                                 torch.as_tensor(frames["ha"][f])[None, None], a, ps, st_t)
                res = await fn({
                    "hidden_user": rt.NDArray(frames["hu"][f][None, None].astype(np.float32)),
                    "hidden_agent": rt.NDArray(frames["ha"][f][None, None].astype(np.float32)),
                    "energy_db": rt.NDArray(np.array([[float(frames["energy"][f])]], np.float32)),
                    "state_id": rt.NDArray(np.array([[int(frames["prev_state"][f])]], np.int32)),
                    "gru_state": rt.NDArray(st_c),
                })
                o_c = res["decision_vector"].numpy()[0, 0].astype(np.float64)
                st_c = res["gru_state_next"].numpy().astype(np.float32)  # the runtime's own state
                worst = max(worst, float(np.abs(o_c - o_t[0, 0].numpy().astype(np.float64)).max()))
                state_worst = max(state_worst, float(np.abs(st_c - st_t.numpy()).max()))
        cos_ok = worst < 5e-2  # decision-vector limit from export_turn.py's gate
        ok = cos_ok and state_worst < 1e-3
        ok_all = ok_all and ok
        print(f"[gate {unit}] decision max|Δ| {worst:.6f} (bar 5e-2), state max|Δ| "
              f"{state_worst:.6f} (bar 1e-3) -> {'PASS' if ok else 'FAIL'}", flush=True)
    return ok_all


def convert(step, out, width, layers):
    """Write the step as <out>/student_step_float32.aimodel -> (path, MB). fp32 is the
    tier's precision ruling (the ANE fp16 defect family, p_end drift: docs/
    voice-tyger-ondevice.md)."""
    import shutil

    import coreai.runtime as rt
    import torch
    from coreai_models.export.macos import export_to_coreai

    ex = {
        "hu": torch.zeros(1, 1, 1024),
        "ha": torch.zeros(1, 1, 1024),
        "act_db": torch.zeros(1, 1),
        "prev_state": torch.zeros(1, 1, dtype=torch.int32),
        "state": torch.zeros(layers, 1, width),
    }
    print("[export] student step -> Core AI ...", flush=True)
    prog = export_to_coreai(
        step, ex, dynamic_shapes=None,
        input_names=("hidden_user", "hidden_agent", "energy_db", "state_id", "gru_state"),
        output_names=("decision_vector", "gru_state_next"))
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    path = out / "student_step_float32.aimodel"
    shutil.rmtree(path, ignore_errors=True)
    prog.save_asset(path, rt.AIModelAssetMetadata())
    size = sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) / 1e6
    return path, size


def main():
    import coreai.runtime as rt
    import torch

    ap = argparse.ArgumentParser()
    ap.add_argument("--student", default=str(ROOT / "bench-results/student/student.pt"))
    ap.add_argument("--shards", default=str(ROOT / "bench-results/student-shards/val"))
    ap.add_argument("--frames", type=int, default=48)
    ap.add_argument("--out", default=str(ROOT / "bench-results/student-coreai"))
    ap.add_argument("--arch", default=None,
                    help="arch token for the AOT compile (default: read from an existing "
                         "container, like export_turn.py)")
    ap.add_argument("--tap", default=None,
                    help="shared checkpoints: adapter to prune to (default: the checkpoint's deploy tap)")
    args = ap.parse_args()

    model, tap = load_student(args.student, tap=args.tap)
    step = StepWrap(model, tap).to(torch.float32).eval()
    width, layers = model.width, model.layers

    out = Path(args.out)
    path, size = convert(step, out, width, layers)
    print(f"saved {path.name} ({size:.1f} MB, float32)")

    from data import iter_shards
    _p, frames, _l, _e, meta = next(iter_shards(args.shards))
    n = min(args.frames, len(frames["energy"]))
    ok = asyncio.run(gate(path, frames, step, width, layers, n))
    print(f"gate on {n} real frames (carried state, {meta['session_id'][:16]}…): "
          f"{'PASS' if ok else 'FAIL'}")
    (out / "parity.md").write_text(
        "# StudentStep Core AI gate (float32)\n\n"
        f"- checkpoint: {args.student}\n- frames: {n} from {meta['session_id']} (runtime-carried state)\n"
        f"- result: {'PASS' if ok else 'FAIL'} (decision bar 5e-2 or cos>0.9999, state bar 1e-3)\n"
        f"- size: {size:.1f} MB\n")

    # AOT container for the Swift loaders (a source .aimodel load leaks ANE compiles
    # — the 2026-10-27 disk incident; export_turn.py's compile_asset, same freshness rules)
    import importlib.machinery
    import os
    os.environ.setdefault("TYGER_S2S", str(Path.home() / "dev" / "github" / "tyger-s2s"))
    ET = importlib.machinery.SourceFileLoader(
        "export_turn", str(ROOT / "ports" / "tyger-coreai" / "export_turn.py")).load_module()
    ET.compile_asset(path, args.arch or ET.host_arch())
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
