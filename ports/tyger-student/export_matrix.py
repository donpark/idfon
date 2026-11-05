"""The P7 export matrix (epic #132, issue #161): the deployable int8 shared tier
across every tier the epic names — ONNX / Core ML / Core AI / MLX — for every
adapter the converged checkpoint carries, with the per-adapter calibration artifact,
the tap input layout, and the P4 parity envelope applied per tier.

The gap this closes is the *matrix and its registry*, not another per-step export:
each cell reuses the tier's own exporter (`export.py`, `export_coreml.py`,
`export_coreai.py`, `export_mlx.py`) and only adds the shared gate + measurement.

A cell is (adapter, tier, variant):

  variant  source checkpoint            artifact
  fp32     the converged fp32 student   the tier's own precision (the shipping form)
  int8     the QAT fine-tune (#145)     int8 (ONNX/MLX: per-output-unit group-16
                                        asymmetric, dequantised in-graph; Core ML:
                                        coremltools' symmetric per-block-16 — its
                                        only linear scheme, a different grid)

Gate (P4's envelope): per-head probs ≤ 2e-3 vs the cell's own torch source, state
argmax flips 0, 0 crossings of the adapter's fitted traits thresholds. `loads` is a
separate fact from `exports`: Core AI AOT containers carry an MPSGraph package
version, and anything above 7.0.80 is refused/segfaulted by the 27.0.x loaders (#110).

Usage:
  .venv/bin/python ports/tyger-student/export_matrix.py \
      --student bench-results/shared-qat-ft/student.pt \
      --fp32 /Users/don/dev/idfon/bench-results/shared-consistent-l03/student.pt \
      --shard-root /Users/don/dev/idfon/bench-results \
      [--adapters l4-streaming,...] [--tiers onnx,coreml,coreai,mlx] [--frames 248]
      [--calibrate/--no-calibrate] [--arch h16s]
Output: bench-results/matrix/matrix.json + matrix.md (gitignored; numbers go in the issue)
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

import runners  # noqa: E402
from data import iter_shards  # noqa: E402
from export import StepWrap, load_student, quantize_student  # noqa: E402
from registry import adapter_by_id  # noqa: E402

TAP_SHARDS = {  # adapter -> shard dir under --shard-root (that tap's own recorded features)
    "l15-windowed": "student-shards",
    "l4-windowed": "l4-shards",
    "l4-streaming": "tap4-shards",
}
CELLS = (  # (tier, variant) — the deployable int8 rung plus each tier's native fp32 form
    ("onnx", "int8"), ("onnx", "fp32"),
    ("coreml", "fp32"), ("coreml", "int8"),
    ("coreai", "fp32"),
    ("mlx", "int8"), ("mlx", "fp32"),
)
FRAME_MS = 80.0  # the decision grid: one 8-vector per 80 ms frame (12.5 Hz)
DEFAULT_TEMP_GRID = "0.6,0.7,0.8,0.9,1.0,1.1,1.25"


def tap_layout(adapter_id, width):
    """The tap's input contract: what the tier's step consumes per frame. Parsed
    from the registry id (`l4-streaming` = Nemotron layer 4, cache-aware pass)."""
    parts = adapter_id.split("-")
    layer = next((int(q[1:]) for q in parts if q.startswith("l") and q[1:].isdigit()), None)
    pass_ = parts[-1] if layer is not None and len(parts) > 1 else None
    return {
        "adapter": adapter_id,
        "layer": layer,
        "pass": pass_,
        "streams": 2,
        "stream_width": width,
        "frame_ms": FRAME_MS,
        "inputs": {
            "hu": {"dtype": "float32", "shape": [width], "meaning": "caller stream, one 80 ms frame"},
            "ha": {"dtype": "float32", "shape": [width], "meaning": "agent stream (the second ear)"},
            "act_db": {"dtype": "float32", "shape": [], "meaning": "raw frame energy, dB"},
            "prev_state": {"dtype": "int64", "shape": [], "meaning": "floor state the rules fed back (0-3, 4=begin)"},
            "state": {"dtype": "float32", "shape": [None, 1, 256], "meaning": "carried GRU state (layers,1,width)"},
        },
    }


def remeasure(out_dir):
    """Re-time every loadable cell of an existing matrix.json (the contended/quiet
    distinction: same artifacts, new clock)."""
    rec = json.loads((out_dir / "matrix.json").read_text())
    width, layers = rec["width"], rec["layers"]
    for c in rec["cells"]:
        if not c.get("loads", {}).get("loads"):
            continue
        step, _meta = runners.load(c["tier"], c["path"], width, layers)
        ms, p95 = runners.ms_per_frame(step, np.zeros(1024, np.float32),
                                       np.zeros(1024, np.float32), -30.0, 0,
                                       np.zeros((layers, 1, width), np.float32))
        c["ms_frame"], c["ms_p95"], c["contended"] = round(ms, 4), round(p95, 4), runners.contention()
        print(f"  {c['adapter']} {c['tier']}-{c['variant']}: {ms:.3f} ms/frame "
              f"(p95 {p95:.3f}) at load {c['contended']['load1']}", flush=True)
    rec["remeasured"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    runners.dump_json(out_dir / "matrix.json", rec)
    (out_dir / "matrix.md").write_text(markdown(rec))
    print(f"re-timed -> {out_dir / 'matrix.json'}")


def selfcheck():
    """The pure logic, no checkpoints: the tap layout parse and the table render."""
    lay = tap_layout("l4-streaming", 1024)
    assert (lay["layer"], lay["pass"], lay["stream_width"]) == (4, "streaming", 1024), lay
    assert tap_layout("l15-windowed", 1024)["layer"] == 15
    assert tap_layout("parakeet-l12-full", 1024)["pass"] == "full"
    rec = {"issue": "x", "checkpoint_int8": "a", "checkpoint_fp32": "b", "group": 16,
           "frames": 1, "generated": "now",
           "adapters": {"l4-streaming": {"layout": lay, "shards": "s", "session": "sid",
                                         "frames": 1, "traits": None, "qat_vs_fp32": None}},
           "cells": [{"adapter": "l4-streaming", "tier": "onnx", "variant": "int8",
                      "path": "p", "exports": True, "bytes": 1e6, "probs_max": 1e-6,
                      "argmax_flips": 0, "threshold_flips": {"5": 0}, "state_max": 1e-6,
                      "ms_frame": 0.1, "gate_pass": True,
                      "loads": {"loads": True, "detail": "loaded"}}]}
    md = markdown(rec)
    assert "| onnx-int8 | 1.00 MB |" in md and "PASS" in md, md
    print("selfcheck ok")


def calibrate(py, student, adapter, shards, out, log, sessions=0):
    """The per-adapter calibration artifact: temperature + the rules' threshold knobs
    (`calibrate.py --temp-grid`, the P4 fit). Returns the traits dict."""
    cmd = [py, str(ROOT / "ports" / "tyger-student" / "calibrate.py"),
           "--shards", str(shards), "--student", str(student), "--tap", adapter,
           "--temp-grid", DEFAULT_TEMP_GRID, "--out", str(out)]
    if sessions:
        cmd += ["--sessions", str(sessions)]
    print(f"[calibrate] {adapter} -> {out.name}", flush=True)
    with open(log, "a") as f:
        f.write(f"\n$ {' '.join(cmd)}\n")
        f.flush()
        subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, check=False)
    return json.loads(Path(out).read_text()) if Path(out).exists() else None


def export_onnx(model, adapter, out_dir, variant, group, width, layers):
    import torch

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    wrap = StepWrap(model, tap=adapter).eval()
    ex = (torch.zeros(1, 1, 1024), torch.zeros(1, 1, 1024), torch.zeros(1, 1),
          torch.zeros(1, 1, dtype=torch.long), torch.zeros(layers, 1, width))
    fp32 = out_dir / "StudentStep.onnx"
    torch.onnx.export(wrap, ex, str(fp32), input_names=["hu", "ha", "act_db", "prev_state", "state"],
                      output_names=["out", "state_out"], dynamo=False)
    if variant == "fp32":
        return fp32
    int8 = out_dir / "StudentStepInt8.onnx"
    quantize_student(fp32, int8, group)
    return int8


def export_coreml(model, adapter, out_dir, variant, width, layers):
    from export_coreml import convert

    ml = convert(StepWrap(model, tap=adapter).eval(), width, layers,
                 "int8" if variant == "int8" else "float32")
    pkg = Path(out_dir) / ("StudentStepInt8.mlpackage" if variant == "int8" else "StudentStep.mlpackage")
    shutil.rmtree(pkg, ignore_errors=True)
    ml.save(str(pkg))
    return pkg


def export_coreai(model, adapter, out_dir, arch):
    import importlib.machinery

    import torch

    from export_coreai import convert

    path, _size = convert(StepWrap(model, tap=adapter).to(torch.float32).eval(),
                          out_dir, model.width, model.layers)
    os.environ.setdefault("TYGER_S2S", str(Path.home() / "dev" / "github" / "tyger-s2s"))
    ET = importlib.machinery.SourceFileLoader(
        "export_turn", str(ROOT / "ports" / "tyger-coreai" / "export_turn.py")).load_module()
    ET.compile_asset(path, arch)
    return path


def export_mlx(model, adapter, out_dir, variant, group):
    from export_mlx import export

    path = Path(out_dir) / ("StudentStepInt8.safetensors" if variant == "int8"
                            else "StudentStep.safetensors")
    export(model, path, group=group if variant == "int8" else None)
    return path


def export_cell(tier, variant, model, adapter, out_dir, args):
    if tier == "onnx":
        return export_onnx(model, adapter, out_dir, variant, args.group, model.width, model.layers)
    if tier == "coreml":
        return export_coreml(model, adapter, out_dir, variant, model.width, model.layers)
    if tier == "coreai":
        return export_coreai(model, adapter, out_dir, args.arch)
    if tier == "mlx":
        return export_mlx(model, adapter, out_dir, variant, args.group)
    raise KeyError(tier)


def param_split(model, adapter):
    """The step's marginal anatomy: the tap adapter (the only part a new ASR adds) vs
    the shared trunk + decoder (paid once). fp32 bytes = 4 x params."""
    a = shared = 0
    for name, p in model.state_dict().items():
        n = p.numel()
        if name.startswith(f"adapters.{adapter}."):
            a += n
        else:
            shared += n
    return {"adapter": a, "shared": shared, "adapter_mb_fp32": round(a * 4 / 1e6, 2),
            "shared_mb_fp32": round(shared * 4 / 1e6, 2)}


def frame_samples(shard_dir, n):
    _p, frames, _l, _e, meta = next(iter_shards(str(shard_dir)))
    n = min(n, len(frames["energy"]))
    return list(zip(frames["hu"][:n], frames["ha"][:n], frames["energy"][:n],
                    frames["prev_state"][:n])), meta["session_id"], n


def gate(ref, cand, samples, width, layers, thr_cols):
    """The P4 envelope on the carried-state live path -> the cell's numbers."""
    st_ref = np.zeros((layers, 1, width), np.float32)
    st_c = np.zeros((layers, 1, width), np.float32)
    outs_t, outs_c, state_d = [], [], 0.0
    for hu, ha, act, prev in samples:
        o_t, st_ref = ref(hu, ha, act, prev, st_ref)
        o_c, st_c = cand(hu, ha, act, prev, st_c)
        outs_t.append(o_t)
        outs_c.append(o_c)
        state_d = max(state_d, float(np.abs(st_ref - st_c).max()))
    a_t, a_c = np.stack(outs_t), np.stack(outs_c)
    probs = float(np.abs(a_t[:, 4:] - a_c[:, 4:]).max())      # hazard/yield/bc/p_end
    logits = float(np.abs(a_t[:, :4] - a_c[:, :4]).max())     # state logits (gated via flips)
    flips = int((a_t[:, :4].argmax(1) != a_c[:, :4].argmax(1)).sum())
    thr = {s: int(((a_t[:, s] >= t) != (a_c[:, s] >= t)).sum()) for s, t in thr_cols.items()}
    return {"probs_max": probs, "logits_max": logits, "argmax_flips": flips,
            "threshold_flips": thr, "state_max": state_d}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--student", default=str(ROOT / "bench-results/shared-qat-ft/student.pt"),
                    help="the int8 cells' source: the QAT fine-tune (#145 recipe)")
    ap.add_argument("--fp32", default=str(ROOT / "bench-results/shared-consistent-l03/student.pt"),
                    help="the fp32 cells' source and the shadow's authoritative path")
    ap.add_argument("--shard-root", default=str(ROOT / "bench-results"))
    ap.add_argument("--shards", action="append", default=None, metavar="TAP=DIR",
                    help="override the adapter -> shard dir map")
    ap.add_argument("--adapters", default=None, help="comma list (default: the int8 checkpoint's)")
    ap.add_argument("--tiers", default=None, help="comma list of grid tiers to cover")
    ap.add_argument("--frames", type=int, default=248, help="gate frames per cell")
    ap.add_argument("--group", type=int, default=16, help="int8 group size (the QAT grid)")
    ap.add_argument("--arch", default="h16s", help="Core AI AOT arch token")
    ap.add_argument("--sessions", type=int, default=0, help="limit calibration sessions (0 = all)")
    ap.add_argument("--skip-calibrate", action="store_true")
    ap.add_argument("--out", default=str(ROOT / "bench-results/matrix"))
    ap.add_argument("--py", default=sys.executable, help="interpreter for the calibration subprocess")
    ap.add_argument("--selfcheck", action="store_true", help="check the pure logic, export nothing")
    ap.add_argument("--remeasure", action="store_true",
                    help="re-time every loadable cell in matrix.json (no re-export) — for a "
                         "quiet-machine pass after a contended one")
    args = ap.parse_args()
    if args.selfcheck:
        selfcheck()
        return
    if args.remeasure:
        remeasure(Path(args.out))
        return

    import torch

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    shard_map = dict(TAP_SHARDS)
    for spec in args.shards or []:
        k, _, v = spec.partition("=")
        shard_map[k] = v

    int8_ckpt = torch.load(args.student, map_location="cpu")
    adapters = ([a.strip() for a in args.adapters.split(",")] if args.adapters
                else list(int8_ckpt.get("adapters", [])))
    if not adapters:
        sys.exit(f"{args.student} is not a shared checkpoint (no adapters)")
    for a in adapters:
        if adapter_by_id(a).kind != "tap":
            sys.exit(f"{a}: only tap adapters have a step export")
        if a not in shard_map:
            sys.exit(f"{a}: no shard dir; pass --shards {a}=/path/to/tap-shards")
    tiers = [t.strip() for t in args.tiers.split(",")] if args.tiers else None
    width, layers = int8_ckpt["width"], int8_ckpt["layers"]

    cells, adapter_rows = [], {}
    for adapter in adapters:
        src = Path(args.shard_root) / shard_map[adapter] / "val"
        if not src.is_dir():
            sys.exit(f"{adapter}: missing gate shards at {src}")
        a_dir = out_dir / adapter
        a_dir.mkdir(parents=True, exist_ok=True)
        traits_path = a_dir / "traits.json"
        traits = None
        if not args.skip_calibrate:
            traits = calibrate(args.py, args.student, adapter, src, traits_path,
                               a_dir / "calibrate.log", args.sessions)
        elif traits_path.exists():
            traits = json.loads(traits_path.read_text())
        thr_cols = ({5: traits["decider"]["barge_thr"], 6: traits["decider"]["bc_thr"],
                     7: traits["decider"]["ep_thr"]} if traits else {5: 0.4, 6: 0.4, 7: 0.85})
        samples, session, n = frame_samples(src, args.frames)
        adapter_rows[adapter] = {
            "layout": tap_layout(adapter, adapter_by_id(adapter).width),
            "params": param_split(load_student(args.student, tap=adapter)[0], adapter),
            "shards": str(src), "session": session, "frames": n,
            "traits": traits, "gate_thresholds": {str(k): v for k, v in thr_cols.items()},
        }
        print(f"\n== {adapter} ({n} frames from {session[:16]}…)  traits "
              f"{'fitted' if traits else 'defaults'}", flush=True)

        models = {}
        for variant in ("fp32", "int8"):
            ckpt = args.fp32 if variant == "fp32" else args.student
            models[variant] = load_student(ckpt, tap=adapter)[0]

        # the tier-independent distance: the int8 source checkpoint vs the fp32 student
        ref_fp32 = runners.torch_step(models["fp32"])
        d = gate(ref_fp32, runners.torch_step(models["int8"]), samples, width, layers, thr_cols)
        adapter_rows[adapter]["qat_vs_fp32"] = d
        print(f"  QAT checkpoint vs fp32 student: probs max|d| {d['probs_max']:.2e}, "
              f"argmax flips {d['argmax_flips']}, threshold flips {d['threshold_flips']}", flush=True)

        for tier, variant in CELLS:
            if tiers and tier not in tiers:
                continue
            cell_dir = a_dir / f"{tier}-{variant}"
            shutil.rmtree(cell_dir, ignore_errors=True)
            cell_dir.mkdir(parents=True, exist_ok=True)
            model = models[variant]
            t0 = time.perf_counter()
            try:
                path = export_cell(tier, variant, model, adapter, cell_dir, args)
            except Exception as e:  # a tier that cannot express the rung is a result, not a crash
                cells.append({"adapter": adapter, "tier": tier, "variant": variant,
                              "error": f"{type(e).__name__}: {str(e)[:300]}",
                              "exports": False, "loads": {"loads": False, "detail": "export failed"},
                              "bytes": 0, "gate_pass": False})
                print(f"  {tier}-{variant}: EXPORT FAILED {str(e)[:120]}", flush=True)
                continue
            export_s = time.perf_counter() - t0
            size = runners.bytes_of(path)
            # one load per cell: the Python Core AI binding pays a compile attempt per
            # source .aimodel load (docs/disk-hygiene.md) — never load a cell twice
            try:
                cand, meta = runners.load(tier, path, width, layers)
                loaded = {"loads": True, "detail": "loaded"}
            except Exception as e:
                cand, meta = None, {}
                loaded = {"loads": False, "detail": f"{type(e).__name__}: {str(e)[:160]}"}
            rec = {"adapter": adapter, "tier": tier, "variant": variant, "path": str(path),
                   "exports": True, "export_s": round(export_s, 2), "bytes": size,
                   "loads": loaded, "source": str(args.student if variant == "int8" else args.fp32),
                   "gate_thresholds": {str(k): v for k, v in thr_cols.items()}}
            if tier == "coreai":
                compiled = path.with_name(path.stem + ".compiled.aimodel")
                ok, detail = runners.aot_loadable(compiled)
                rec["aot"] = {"container": str(compiled) if compiled.exists() else None,
                              "loadable": ok, "detail": detail}
            if not loaded["loads"]:
                rec.update({"gate_pass": False, "probs_max": None, "ms_frame": None})
                cells.append(rec)
                print(f"  {tier}-{variant}: {size / 1e6:.2f} MB, NOT LOADABLE "
                      f"({loaded['detail']})", flush=True)
                continue
            g = gate(runners.torch_step(model), cand, samples, width, layers, thr_cols)
            ms, p95 = runners.ms_per_frame(cand, samples[0][0], samples[0][1],
                                           samples[0][2], samples[0][3],
                                           np.zeros((layers, 1, width), np.float32))
            ok = (g["probs_max"] <= 2e-3 and g["argmax_flips"] == 0
                  and all(v == 0 for v in g["threshold_flips"].values()))
            rec.update({**g, "ms_frame": round(ms, 4), "ms_p95": round(p95, 4),
                        "gate_pass": bool(ok), "runner": meta,
                        "contended": runners.contention()})
            cells.append(rec)
            print(f"  {tier}-{variant}: {size / 1e6:.2f} MB, probs {g['probs_max']:.2e}, "
                  f"flips {g['argmax_flips']}/{sum(g['threshold_flips'].values())}, "
                  f"{ms:.3f} ms/frame, loads {loaded['loads']}  "
                  f"{'PASS' if ok else 'FAIL'}", flush=True)

    record = {
        "issue": "donpark/idfon#161 (epic #132 P7)",
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "checkpoint_int8": args.student, "checkpoint_fp32": args.fp32,
        "group": args.group, "frames": args.frames, "width": width, "layers": layers,
        "envelope": {"probs_max": 2e-3, "argmax_flips": 0, "threshold_flips": 0},
        "contention": runners.contention(),
        "adapters": adapter_rows, "cells": cells,
        "notes": [
            "gate numbers are the artifact vs the checkpoint it was exported from (packaging",
            "parity); `qat_vs_fp32` is the tier-independent distance of the int8 source",
            "Core ML int8 is coremltools' symmetric per-block-16 weight scheme (not the QAT grid)",
            "Core AI rows: `loads` is the coreai.runtime load on this Mac; `aot` is the",
            "device container, which the 27.0.x loaders refuse above MPSGraph 7.0.80 (#110)",
        ],
        "skips": [
            {"what": "Core AI int8",
             "why": "coreai_opt.quantization (torchao PT2E, graph + eager modes) exists in the "
                    "installed toolchain but is not wired through export_to_coreai + the AOT "
                    "compiler + the coreai.runtime gate; the tier ships fp32 (its shipping form)"},
            {"what": "parakeet-l12-full adapter row",
             "why": "that adapter lives in a different checkpoint (shared-parakeet*) and has no "
                    "QAT fit; a new ASR adds an adapter row with train_shared --adapter-only TAP "
                    "+ calibrate.py --tap, then --shards TAP=<tap-shards>"},
        ],
    }
    runners.dump_json(out_dir / "matrix.json", record)
    (out_dir / "matrix.md").write_text(markdown(record))
    n_pass = sum(1 for c in cells if c.get("gate_pass"))
    print(f"\n{len(cells)} cells, {n_pass} pass -> {out_dir / 'matrix.json'} + matrix.md")
    raise SystemExit(0 if n_pass == len(cells) else 1)


def markdown(rec):
    L = [f"# P7 export matrix ({rec['issue']})", "",
         f"int8 source: `{rec['checkpoint_int8']}`  |  fp32 source: `{rec['checkpoint_fp32']}`  |  "
         f"group-{rec['group']}, {rec['frames']} carried-state frames per cell  |  "
         f"generated {rec['generated']}", ""]
    for adapter, row in rec["adapters"].items():
        lay = row["layout"]
        L += [f"## {adapter}", "",
              f"tap layout: layer {lay['layer']}, {lay['pass']} pass, 2 x {lay['stream_width']}-d "
              f"per {int(lay['frame_ms'])} ms frame  |  shards `{row['shards']}` "
              f"({row['frames']} frames from {row['session'][:16]}…)  |  traits "
              + (f"T={row['traits'].get('temperature')} "
                 f"{row['traits']['decider']['ep_thr']}/{row['traits']['decider']['barge_thr']}/"
                 f"{row['traits']['decider']['bc_thr']}" if row.get("traits") else "defaults"), ""]
        q = row.get("qat_vs_fp32") or {}
        if q:
            L += [f"int8 source vs fp32 student (tier-independent): probs max|Δ| "
                  f"{q['probs_max']:.2e}, argmax flips {q['argmax_flips']}, threshold flips "
                  f"{sum(q['threshold_flips'].values())}", ""]
        L += ["| cell | bytes | probs max\\|Δ\\| | argmax flips | thr flips | state max\\|Δ\\| | "
              "ms/frame | gate | exports | loads |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |"]
        for c in [c for c in rec["cells"] if c["adapter"] == adapter]:
            if not c.get("exports"):
                L.append(f"| {c['tier']}-{c['variant']} | — | — | — | — | — | — | — | FAILED | — |")
                continue
            loads = "yes" if c["loads"]["loads"] else f"no ({c['loads']['detail']})"
            if c.get("aot") and c["aot"].get("loadable") is not None:
                loads += f"; AOT {'ok' if c['aot']['loadable'] else 'NO'} ({c['aot']['detail']})"
            L.append("| {t}-{v} | {b:.2f} MB | {p} | {f} | {tf} | {s} | {ms} | {ex} | yes | {ld} |".format(
                t=c["tier"], v=c["variant"], b=c["bytes"] / 1e6,
                p=f"{c['probs_max']:.2e}" if c.get("probs_max") is not None else "—",
                f=c.get("argmax_flips", "—"),
                tf=sum(c["threshold_flips"].values()) if c.get("threshold_flips") else "—",
                s=f"{c['state_max']:.2e}" if c.get("state_max") is not None else "—",
                ms=f"{c['ms_frame']:.3f}" if c.get("ms_frame") is not None else "—",
                ex="PASS" if c["gate_pass"] else "FAIL", ld=loads))
        L.append("")
        aot = [c for c in rec["cells"] if c["adapter"] == adapter and c.get("aot")]
        for c in aot:
            a = c["aot"]
            L += [f"AOT container ({c['tier']}): `{a['container']}` — "
                  + ("loadable" if a["loadable"] else "**not loadable**")
                  + f" ({a['detail']}); the macOS runtime loads the source asset.", ""]
    if rec.get("skips"):
        L += ["## Not covered here", ""]
        for s_ in rec["skips"]:
            L += [f"- **{s_['what']}** — {s_['why']}"]
        L.append("")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    main()
