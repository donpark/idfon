"""Replay a live call's turn capture through the shipped student and the teacher.

The capture is the on-device `TurnCapture` WAV: stereo 16 kHz s16, ch0 = mic,
ch1 = what the agent played. It is the only real-call audio we have (#104), so
this is the live-call version of the harness: no labels, the axes are

  interrupting onsets   mic starts while the agent is still playing (energy VAD)
  barge catch           student/teacher yield crosses the threshold within
                        640 ms of an onset
  barge false fire      a barge event outside every onset window; "playing"
                        also requires agent audio (the false fires that can
                        actually interrupt)
  yield distribution    student vs teacher yield stats and fit on the same audio
  endpoint timing       student vs teacher ENDPOINT events on the same audio

Features: the windowed re-encode the heads trained on (8 s window per 320 ms
hop, last 4 rows), same as `featurize.py`. The student runs with its own traits.

Usage:
  TYGER_BUNDLE=... ports/tyger-student/.venv/bin/python scripts/analyze-call-capture.py \
      CAPTURE.wav [--student bench-results/student-l4-60/student.pt] \
      [--layer 4] [--traits bench-results/student-l4-60/student.traits.json]
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ports/tyger-student"))

from oracle import HOP, HOP_FRAMES, SR, WIN_S, Oracle  # noqa: E402
from model import Student  # noqa: E402
from registry import by_id  # noqa: E402


def windowed(oracle, wav, layer):
    """Per 320 ms hop: last 8 s re-encoded, last 4 rows (the training contract)."""
    rows = []
    full = WIN_S * SR
    for h in range(len(wav) // HOP):
        x = (h + 1) * HOP
        w = wav[max(0, x - full):x]
        if len(w) < full:
            w = np.concatenate([np.zeros(full - len(w), np.float32), w])
        hs = oracle.encode_hidden(w)
        rows.extend(hs[layer][-min(HOP_FRAMES, len(hs[layer])):])
    return np.stack(rows) if rows else np.zeros((0, 1024), np.float32)


def frame_db(x):
    """80 ms frame energy in dB (the rules' VAD scale)."""
    n = len(x) // 1280
    rms = np.array([np.sqrt(np.mean(x[i * 1280:(i + 1) * 1280] ** 2) + 1e-12)
                    for i in range(n)], np.float32)
    return 20.0 * np.log10(rms + 1e-12)


def onsets(user_db, agent_db, thr=-50.0, quiet=-55.0, hold=5, max_gap=800):
    """Mic onsets while the agent plays: speech starts after >= hold quiet frames."""
    out = []
    quiet_run = 0
    for f in range(len(user_db)):
        if user_db[f] < quiet:
            quiet_run += 1
            continue
        if user_db[f] >= thr and quiet_run >= hold and agent_db[f] > -45.0:
            out.append(f)
        if user_db[f] >= thr:
            quiet_run = 0
    # de-duplicate onsets closer than max_gap frames (one utterance)
    kept = []
    for f in out:
        if not kept or f - kept[-1] > max_gap // 80:
            kept.append(f)
    return kept


def student_vecs(model, hu, ha, energy, oracle, device):
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


def teacher_vecs(oracle, hu, ha, energy):
    sess = oracle.EarsSession(0)
    cache = None
    rows = []
    for f in range(len(energy)):
        o, cache = oracle.head_step(hu[f], ha[f], float(energy[f]), int(sess.prev_state), cache)
        rows.append(o)
        oracle.rules.on_frame(sess, "response", o, float(energy[f]), left=3 - (f % HOP_FRAMES))
    return np.stack(rows)


def events(vecs, energy, oracle, thr):
    sess = oracle.EarsSession(0, ep_thr=thr[0], barge_thr=thr[1], bc_thr=thr[2])
    out = []
    for f in range(len(vecs)):
        e, _final, _reset = oracle.rules.on_frame(sess, "response", vecs[f], float(energy[f]),
                                                  left=3 - (f % HOP_FRAMES))
        out += [(f + 1, x["kind"]) for x in e if x["kind"] != "FRAME"]
    return out


def fires(vecs, barge_thr, deb=2):
    """Rising-edge barge events: the first frame of `deb` consecutive yield >= thr."""
    run = 0
    out = []
    for f in range(len(vecs)):
        if vecs[f][5] >= barge_thr:
            run += 1
            if run == deb:
                out.append(f - deb + 1)
        else:
            run = 0
    return out


def false_fires(vecs, onsets_frames, barge_thr, agent_db, window=8, deb=2):
    """Barge events outside every onset window; `playing` also requires agent audio."""
    ev = fires(vecs, barge_thr, deb)
    outside = [f for f in ev if not any(b <= f < b + window for b in onsets_frames)]
    return len(outside), sum(1 for f in outside if agent_db[f] > -45.0)


def catch(vecs, onsets_frames, barge_thr, window=8, deb=2):
    """Fraction of interrupting onsets with `deb` consecutive yield >= thr in the window."""
    hit = 0
    for f in onsets_frames:
        run = 0
        for k in range(window):
            i = f + k
            if i < len(vecs) and vecs[i][5] >= barge_thr:
                run += 1
                if run >= deb:
                    hit += 1
                    break
            else:
                run = 0
    return hit / len(onsets_frames) if onsets_frames else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--student", default=str(ROOT / "bench-results/student-l4-60/student.pt"))
    ap.add_argument("--traits", default=None, help="the student's decider (default: alongside the checkpoint)")
    ap.add_argument("--layer", type=int, default=4)
    ap.add_argument("--device", default="mps")
    args = ap.parse_args()

    traits_path = Path(args.traits or Path(args.student).with_suffix(".traits.json"))
    default_thr = (0.9146, 0.5, 0.5)
    thr = default_thr
    if traits_path.exists():
        d = json.loads(traits_path.read_text())["decider"]
        thr = (d["ep_thr"], d["barge_thr"], d["bc_thr"])
    print(f"capture {args.capture}\nstudent {args.student}\nthresholds {thr}")

    wav, rate = sf.read(args.capture, dtype="float32", always_2d=True)
    assert rate == SR and wav.shape[1] == 2, f"expected 16 kHz stereo, got {rate} Hz x {wav.shape[1]}"
    user, agent = wav[:, 0], wav[:, 1]
    print(f"{len(user) / SR:.1f} s, mic RMS {np.sqrt(np.mean(user**2)):.4f}, "
          f"agent RMS {np.sqrt(np.mean(agent**2)):.4f}")

    oracle = Oracle(device=args.device).load_bundle()
    hu = windowed(oracle, user, args.layer)
    ha = windowed(oracle, agent, args.layer)
    n = min(len(hu), len(ha))
    hu, ha = hu[:n], ha[:n]
    energy = frame_db(user)[:n]

    ck = torch.load(args.student, map_location=args.device)
    model = Student([by_id(i) for i in ck["heads"]], width=ck["width"], layers=ck["layers"]).to(args.device)
    model.load_state_dict(ck["state_dict"])
    model.eval()
    sv = student_vecs(model, hu, ha, energy, oracle, args.device)

    # the teacher reads L15 from the same windows
    hu15 = windowed(oracle, user, 15)[:n]
    ha15 = windowed(oracle, agent, 15)[:n]
    tv = teacher_vecs(oracle, hu15, ha15, energy)

    user_db, agent_db = frame_db(user)[:n], frame_db(agent)[:n]
    ons = onsets(user_db, agent_db)
    for name, vecs in (("student", sv), ("teacher", tv)):
        y = vecs[:, 5]
        print(f"  {name} yield: mean {y.mean():.3f}  std {y.std():.3f}  "
              f"p99 {np.percentile(y, 99):.3f}  max {y.max():.3f}")
    print(f"  yield corr {np.corrcoef(sv[:, 5], tv[:, 5])[0, 1]:.3f}  "
          f"MSE {np.mean((sv[:, 5] - tv[:, 5]) ** 2):.4f}  "
          f"fit {np.polyfit(tv[:, 5], sv[:, 5], 1)[0]:.2f}*teacher"
          f"{np.polyfit(tv[:, 5], sv[:, 5], 1)[1]:+.2f}")
    print(f"\ninterrupting onsets (mic starts while the agent plays): {len(ons)}")
    for label, vecs in (("student", sv), ("teacher", tv)):
        peaks = [max(float(vecs[f + k][5]) for k in range(8) if f + k < len(vecs))
                 for f in ons]
        print(f"  {label} yield peak per onset: {['%.2f' % p for p in peaks]}")
    for t in (0.10, 0.12, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50):
        s_false, s_playing = false_fires(sv, ons, t, agent_db)
        t_false, t_playing = false_fires(tv, ons, t, agent_db)
        print(f"  barge @{t:.2f}: catch student {catch(sv, ons, t):.2f}  "
              f"teacher {catch(tv, ons, t):.2f}  | false student {s_false} ({s_playing} playing)  "
              f"teacher {t_false} ({t_playing} playing)")

    se = events(sv, energy, oracle, thr)
    te = events(tv, energy, oracle, default_thr)
    for name, ev in (("student", se), ("teacher", te)):
        kinds = {}
        for _, k in ev:
            kinds[k] = kinds.get(k, 0) + 1
        print(f"\n{name}: {len(ev)} events {kinds}")
    ep_s = [f for f, k in se if k == "ENDPOINT"]
    ep_t = [f for f, k in te if k == "ENDPOINT"]
    print(f"ENDPOINT frames student {ep_s[:12]}…\nteacher {ep_t[:12]}…")


if __name__ == "__main__":
    main()
