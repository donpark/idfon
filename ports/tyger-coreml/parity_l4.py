"""B2 gate: the exported L4 encoder against the fp32 reference, and the decisions
it produces through the L4 student.

Two checks, same audio:
  feature  Core ML encoder(feats) vs the reference chain's hidden_states[4]
  decision both feature sets -> student2-l4 -> the live rules -> ENDPOINT events

Usage:
  TYGER_BUNDLE=... ports/tyger-student/.venv/bin/python ports/tyger-coreml/parity_l4.py \
      [--hops 20] [--student bench-results/student2-l4/student.pt]
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ports/tyger-student"))

from oracle import HOP, HOP_FRAMES, SR, WIN_S, Oracle  # noqa: E402

FIXTURE = ROOT / "ports/tyger-swift/Tests/TygerVoiceTests/runtime"


def mel_window(oracle, wav):
    return oracle.proc(np.asarray(wav, np.float32), sampling_rate=SR,
                       return_tensors="pt")["input_features"]


def events(vecs, energy, oracle):
    sess = oracle.EarsSession(0)
    out = []
    for f in range(len(vecs)):
        e, _final, _reset = oracle.rules.on_frame(sess, "response", vecs[f],
                                                  float(energy[f]), left=3 - (f % HOP_FRAMES))
        out += [(f + 1, x["kind"]) for x in e if x["kind"] != "FRAME"]
    return out


def student_vecs(model, hu, ha, energy, oracle, device="cpu"):
    """Live rules feedback, the gate.py semantics."""
    import torch
    sess = oracle.EarsSession(0)
    hidden = None
    rows = []
    with torch.no_grad():
        for f in range(len(energy)):
            o, hidden = model(torch.as_tensor(hu[f], device=device)[None, None],
                              torch.as_tensor(ha[f], device=device)[None, None],
                              torch.tensor([[float(energy[f])]], device=device),
                              torch.tensor([[int(sess.prev_state)]], device=device), hidden)
            v = model.eight_vector(o)[0, 0].cpu().numpy().astype(np.float64)
            rows.append(v)
            oracle.rules.on_frame(sess, "response", v, float(energy[f]), left=3 - (f % HOP_FRAMES))
    return np.stack(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hops", type=int, default=20)
    ap.add_argument("--student", default=str(ROOT / "bench-results/student2-l4/student.pt"))
    ap.add_argument("--device", default="mps")
    args = ap.parse_args()

    import coremltools as ct
    import torch
    from model import Student
    from registry import by_id

    oracle = Oracle(device=args.device).load_bundle()
    ck = torch.load(args.student, map_location="cpu")
    model = Student([by_id(i) for i in ck["heads"]], width=ck["width"], layers=ck["layers"])
    model.load_state_dict(ck["state_dict"])
    model.to(args.device)
    model.eval()

    models = {}
    for name, rel in (("fp32", "bench-results/coreml-l4-fp32/TygerEncoderL4.mlpackage"),
                      ("fp16", "bench-results/coreml-l4/TygerEncoderL4.mlpackage")):
        p = ROOT / rel
        if p.exists():
            models[name] = ct.models.MLModel(str(p), compute_units=ct.ComputeUnit.CPU_ONLY)
            print(f"loaded {name}: {p}")
    if not models:
        sys.exit("no exported L4 encoder found")

    wav = sf.read(str(FIXTURE / "ch0.wav"), dtype="float32")[0]
    feats_ref, feats_cm, energies = [], {k: [] for k in models}, []
    start = max(0, (WIN_S * SR) // HOP - 1)  # the static graph takes a full 8 s window
    for h in range(start, min(start + args.hops, len(wav) // HOP)):
        x = (h + 1) * HOP
        win = wav[max(0, x - WIN_S * SR):x]
        mel = mel_window(oracle, win)
        ref = oracle.encode_hidden(win)[4]
        feats_ref.append(ref[-min(HOP_FRAMES, len(ref)):])
        act = oracle.rules.frame_energy(win)
        energies.extend(act[-min(HOP_FRAMES, len(act)):])
        for k, m in models.items():
            out = m.predict({"feats": mel.numpy()})
            arr = next(iter(out.values()))
            arr = np.asarray(arr)[0]
            feats_cm[k].append(arr[-min(HOP_FRAMES, len(arr)):])
    ref = np.concatenate(feats_ref)
    print(f"\nfeature parity over {len(ref)} frames (reference = fp32 HF hidden_states[4])")
    for k in models:
        got = np.concatenate(feats_cm[k])
        n = min(len(got), len(ref))
        d = np.abs(got[:n] - ref[:n])
        cos = np.mean(np.sum(got[:n] * ref[:n], 1) /
                      (np.linalg.norm(got[:n], axis=1) * np.linalg.norm(ref[:n], axis=1) + 1e-9))
        print(f"  {k}: mean|d| {d.mean():.5f}  max|d| {d.max():.4f}  cos {cos:.6f}")

    energy = np.array(energies[:len(ref)], np.float64)
    e_ref = events(student_vecs(model, ref, ref, energy, oracle, args.device), energy, oracle)
    print(f"\ndecisions: reference {len(e_ref)} events")
    for name in models:
        got = np.concatenate(feats_cm[name])[:len(ref)]
        e = events(student_vecs(model, got, got, energy, oracle, args.device), energy, oracle)
        hit = sum(1 for f, kind in e_ref
                  if any(abs(f - g) <= 2 and kind == k2 for g, k2 in e))
        print(f"  {name}: {len(e)} events, {hit}/{max(len(e_ref), len(e))} aligned "
              f"({hit / max(len(e_ref), len(e)) * 100:.1f}%)")


if __name__ == "__main__":
    main()
