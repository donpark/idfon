"""One step-runner per export tier (epic #132 P7): the parity gate and TurnShadow
both replay frames through ONE surface, so a diff measures the tier, not the harness.

  step(hu, ha, act_db, prev_state, state) -> (out8, state)

hu/ha are (1024,) float32 tap frames, act_db raw dB, prev_state the rules' floor
state, state (layers,1,width) float32 — the StudentStep contract (export.py's
StepWrap: energy normalisation and the 8-vector assembly are inside the graph).

`load()` raises when the tier's runtime cannot open the artifact; callers turn that
into the matrix's *loads* column instead of a crash. A Core AI AOT container can be
produced and still not load (MPSGraph package > 7.0.80 segfaults the iOS 27.0.x
loader, #110), which is why every matrix row carries exports and loads separately.
"""
import glob
import json
import plistlib
from pathlib import Path

import numpy as np

TIERS = ("onnx", "coreml", "coreai", "mlx")
AOT_MAX_PACKAGE = (7, 0, 80)  # the iOS 27.0.x / macOS 27.2 loader ceiling (#110)


def _vtuple(s):
    return tuple(int(x) for x in s.split("."))


def torch_step(model, tap=None):
    """The reference path: the fp32 torch student (pruned to one adapter)."""
    import torch

    model.eval()
    if tap is None and hasattr(model, "adapters"):  # a pruned shared student
        tap = next(iter(model.adapters))

    def step(hu, ha, act_db, prev_state, state):
        with torch.no_grad():
            args = (torch.as_tensor(hu, dtype=torch.float32)[None, None],
                    torch.as_tensor(ha, dtype=torch.float32)[None, None],
                    torch.tensor([[float(act_db)]]),
                    torch.tensor([[int(prev_state)]], dtype=torch.long),
                    torch.as_tensor(state, dtype=torch.float32))
            outs, st = model(*args) if tap is None else model(tap, *args)
            return (model.eight_vector(outs)[0, 0].to(torch.float64).numpy(),
                    st.numpy().astype(np.float32))

    return step


def onnx_step(path):
    import onnxruntime as ort

    sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])

    def step(hu, ha, act_db, prev_state, state):
        out, st = sess.run(None, {
            "hu": hu[None, None], "ha": ha[None, None],
            "act_db": np.array([[float(act_db)]], np.float32),
            "prev_state": np.array([[int(prev_state)]], np.int64),
            "state": state})
        return np.asarray(out[0, 0], np.float64), np.asarray(st, np.float32)

    return step


def coreml_step(path, width, layers, units="ALL"):
    """Core ML predict per frame. I/O is matched by SHAPE (the conversion renames
    `state`; export_coreml.io_by_shape is the one place that knows the shapes)."""
    import coremltools as ct

    from export_coreml import io_by_shape

    unit = {"ALL": ct.ComputeUnit.ALL, "CPU": ct.ComputeUnit.CPU_ONLY}[units]
    cm = ct.models.MLModel(str(path), compute_units=unit)
    ins = io_by_shape(cm.get_spec().description.input, width, layers,
                      expect={"hu", "ha", "act_db", "prev_state", "state"})
    outs = io_by_shape(cm.get_spec().description.output, width, layers, expect={"out", "state"})

    def step(hu, ha, act_db, prev_state, state):
        res = cm.predict({
            ins["hu"]: hu[None, None].astype(np.float32),
            ins["ha"]: ha[None, None].astype(np.float32),
            ins["act_db"]: np.array([[float(act_db)]], np.float32),
            ins["prev_state"]: np.array([[int(prev_state)]], np.int32),
            ins["state"]: state})
        return (np.asarray(res[outs["out"]])[0, 0].astype(np.float64),
                np.asarray(res[outs["state"]]).astype(np.float32))

    return step


def coreai_step(path, unit="gpu"):
    """Core AI runtime step. The Python binding is async and leaks ~1 IOSurface per
    call (ports/tyger-coreai/GATES.md), so replays stay short and sequential."""
    import asyncio

    import coreai.runtime as rt

    loop = asyncio.new_event_loop()
    try:
        opts = (rt.SpecializationOptions.cpu_only() if unit == "cpu"
                else rt.SpecializationOptions.from_preferred_compute_unit_kind(
                    getattr(rt.ComputeUnitKind, unit)()))
        model = loop.run_until_complete(rt.AIModel.load(str(path), opts))
        fn = model.load_function("main")
    finally:
        loop.close()
    loop = asyncio.new_event_loop()

    def step(hu, ha, act_db, prev_state, state):
        res = loop.run_until_complete(fn({
            "hidden_user": rt.NDArray(hu[None, None].astype(np.float32)),
            "hidden_agent": rt.NDArray(ha[None, None].astype(np.float32)),
            "energy_db": rt.NDArray(np.array([[float(act_db)]], np.float32)),
            "state_id": rt.NDArray(np.array([[int(prev_state)]], np.int32)),
            "gru_state": rt.NDArray(state)}))
        return (res["decision_vector"].numpy()[0, 0].astype(np.float64),
                res["gru_state_next"].numpy().astype(np.float32))

    return step


def mlx_step(path):
    from export_mlx import load_step

    return load_step(path)


def load(tier, path, width, layers, unit=None):
    if tier == "onnx":
        return onnx_step(path), {}
    if tier == "coreml":
        return coreml_step(path, width, layers, units=unit or "ALL"), {}
    if tier == "coreai":
        for u in ([unit] if unit else ["gpu", "cpu"]):
            try:
                return coreai_step(path, u), {"unit": u}
            except Exception as e:  # the CPU specialization can fail on a graph (GATES.md)
                last = f"{u}: {str(e)[:120]}"
        raise RuntimeError(f"coreai load failed ({last})")
    if tier == "mlx":
        return mlx_step(path), {}
    raise KeyError(f"unknown tier {tier!r} (have {TIERS})")


def mpsgraph_version(compiled_dir):
    """The MPSGraph package version an AOT container was built against, or None.
    A container above AOT_MAX_PACKAGE does not load on the shipping OSes (#110)."""
    for man in glob.glob(str(Path(compiled_dir) / "*.aimodelc" / "**"
                              / "mpsExecutable.mpsgraphpackage" / "manifest.plist"),
                         recursive=True):
        try:
            with open(man, "rb") as f:
                d = plistlib.load(f)
            return next(iter(d.get("Package Version", {})), None)
        except Exception:
            continue
    return None


def aot_loadable(compiled_dir):
    """-> (bool|None, detail). None = no AOT container produced."""
    kids = glob.glob(str(Path(compiled_dir) / "*.aimodelc"))
    if not kids:
        return None, "no AOT container"
    ver = mpsgraph_version(compiled_dir)
    if ver is None:
        return None, "AOT container has no MPSGraph package version"
    ok = _vtuple(ver) <= AOT_MAX_PACKAGE
    return ok, (f"MPSGraph {ver} "
                f"{'<=' if ok else '>'} {'.'.join(map(str, AOT_MAX_PACKAGE))} (#110)")


def bytes_of(path):
    """Artifact bytes on disk (a directory sums its children; ONNX external weights
    live beside the graph in `<name>.onnx.data`, which is part of the artifact)."""
    p = Path(path)
    if p.is_file():
        side = Path(str(p) + ".data")
        return p.stat().st_size + (side.stat().st_size if side.exists() else 0)
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())


def ms_per_frame(step, hu, ha, act, prev, state, reps=200):
    """Median per-frame ms for one step call (one tap frame in, one 8-vector out)."""
    import time

    for _ in range(20):  # warmup (JIT / first-touch)
        step(hu, ha, act, prev, state)
    t = []
    for _ in range(reps):
        t0 = time.perf_counter()
        step(hu, ha, act, prev, state)
        t.append(time.perf_counter() - t0)
    t.sort()
    return float(np.median(t) * 1e3), float(t[int(len(t) * 0.95)] * 1e3)


def contention():
    """loadavg-based contention stamp for every latency number (the matrix may run
    beside other heavy MPS work; an honest number carries its conditions)."""
    import os
    load = os.getloadavg()[0]
    cores = os.cpu_count() or 1
    return {"load1": round(load, 2), "cores": cores, "contended": load > cores / 2}


def dump_json(path, obj):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(obj, indent=2, default=float) + "\n")
