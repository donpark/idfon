"""Slow-tier state serializer (epic #132 P6, issue #160).

A slow-tier decision record is a **pure function of a serialized state**: the fast
tier's shared latent `z` plus the signals it already has (its own 8-vector, frame
energy, rules' previous floor state, playback/listen mode) over a trailing window.
This module builds that state at *clause/turn events* — never per frame — and writes
one `.npz` per session plus an `events.jsonl` provenance index.

Event triggers are runtime-detectable and deterministic (a pure function of the same
serialized signals), so a replay needs no live session state:

  pause / onset        energy crosses VAD_DB (-50 dB) after >= --min-run frames dwell
  fast_endpoint        the fast tier's p_end rises through --trig-endpoint and holds 2 frames
  fast_barge           ... yield through --trig-barge
  fast_backchannel     ... bc through --trig-bc

Candidate thresholds are deliberately lower than the rules' decision thresholds: the
slow tier is called on candidates, and the teacher's frame answer at that event is the
reference (never a trigger). The trigger set is the same for every decoder shape and
for the fast-tier floor, so the comparison is apples to apples.

Each session file holds the stacked per-event windows:

  z           float32 [N, W, 256]   the shared latent, post out_norm (the fast tier's z)
  fast        float32 [N, W, 8]     the fast tier's own 8-vector
  energy      float32 [N, W]        raw dB
  prev_state  int64   [N, W]        the rules' floor state fed to the fast tier
  mode        int8    [N, W]        0 listen / 1 speaking
  activity    int8    [N, W]        1 = energy above VAD_DB
  kind        int64   [N]           EVENT_KINDS index
  frame       int32   [N]           event frame (0-based within the session)
  teacher     float32 [N, 8]        the teacher's 8-vector at the event frame (target)

The window is W=--window frames (25 = 2 s) ending at the event; events before the
window are skipped (warm-up), not padded.

    .venv/bin/python ports/tyger-student/slow_state.py \
        --shards bench-results/tap4-shards/val --out bench-results/slow/val \
        --student bench-results/shared-consistent-l03/student.pt --tap l4-streaming

    .venv/bin/python ports/tyger-student/slow_state.py --selfcheck
"""
import argparse
import glob
import json
import os
import sys

import numpy as np
import torch

FRAME_MS = 80
VAD_DB = -50.0
WINDOW = 25
EVENT_KINDS = ("pause", "onset", "fast_endpoint", "fast_barge", "fast_backchannel")
COMMIT_HORIZON = 5  # frames (400 ms): the slow tier's pause-vs-completion judgment
FAST_COLS = {"endpoint": 7, "barge": 5, "backchannel": 6}
TEACHER_THRESHOLDS = {"endpoint": 0.9146, "barge": 0.5, "backchannel": 0.5}
LATENT_WIDTH = 256


def load_fast(path, tap=None):
    """The fast-tier checkpoint, CPU, plus its underlying SharedLatentStudent + tap."""
    from checkpoint import load as load_model

    model, ckpt = load_model(path, tap=tap, device="cpu")
    core = getattr(model, "_model", model)
    bound = getattr(model, "tap", None)
    if not hasattr(core, "adapters"):
        sys.exit(f"{path} is not a shared-latent checkpoint; P6 needs the shared tier")
    if bound is None:
        bound = next(iter(core.adapters))
    return model, core, bound, ckpt


@torch.no_grad()
def fast_stream(core, tap, hu, ha, energy, prev_state, mode, chunk=250):
    """Run the fast tier with the live replay semantics (carried GRU state, reset on a
    mode switch) and return per-frame (z, fast 8-vector). Replicates
    SharedLatentStudent.forward's math without changing the model."""
    T = len(energy)
    zs = np.empty((T, LATENT_WIDTH), np.float32)
    outs8 = np.empty((T, 8), np.float32)
    hidden = None
    last_mode = None
    for s in range(0, T, chunk):
        e = min(T, s + chunk)
        m = mode[s:e]
        if last_mode is not None and np.any(m != last_mode):
            hidden = None  # the rules reset on a mode switch (gate.student_events)
        last_mode = int(m[-1]) if len(m) else last_mode
        h = torch.from_numpy(np.ascontiguousarray(hu[s:e]))[None]
        a = torch.from_numpy(np.ascontiguousarray(ha[s:e]))[None]
        act = torch.from_numpy(np.ascontiguousarray(energy[s:e])).float()
        prev = torch.from_numpy(np.ascontiguousarray(prev_state[s:e])).long()
        ad = core.adapters[tap]
        actn = ((act + 50.0) / 25.0).clamp(-3.0, 3.0)
        z = (ad["user"](h) + ad["agent"](a) + core.proj_energy(actn.unsqueeze(-1))
             + core.state_emb(prev[None]))
        z, hidden = core.core(core.in_norm(z), hidden)
        z = core.out_norm(z)
        o = {head.id: core.heads[head.id](z) for head in core.heads_spec}
        zs[s:e] = z[0].float().numpy()
        outs8[s:e] = core.eight_vector(o)[0].float().numpy()
    return zs, outs8


def event_frames(energy, fast, min_run=2, deb=2,
                 trig={"endpoint": 0.5, "barge": 0.2, "backchannel": 0.2}):
    """Deterministic clause/turn triggers -> [(frame, EVENT_KINDS index)]. One event per
    frame; when triggers coincide the first in EVENT_KINDS priority wins (pause/onset
    before the fast candidates, so the event is a boundary, not a duplicate)."""
    T = len(energy)
    activity = energy > VAD_DB
    found = {}
    for f in range(1, T):
        if activity[f] != activity[f - 1]:
            if f + min_run <= T and bool(np.all(activity[f:f + min_run] == activity[f])):
                found.setdefault(f, "onset" if activity[f] else "pause")
    for axis, thr in trig.items():
        b = fast[:, FAST_COLS[axis]] >= thr
        for f in range(deb, T):
            if b[f] and bool(np.all(b[f - deb + 1:f + 1])) and not b[f - deb]:
                found.setdefault(f, f"fast_{axis}")
    order = {k: i for i, k in enumerate(EVENT_KINDS)}
    return sorted(((f, order[k]) for f, k in found.items()), key=lambda x: x[0])


def serialize_session(frames, core, tap, window=WINDOW, min_run=2, deb=2,
                      trig=None, hu_key="hu", events=None):
    """One session's frames -> stacked event states (dict of arrays). Pure: same inputs,
    same arrays; the event list depends only on the serialized signals."""
    ha_key = "ha" + hu_key[2:]  # hu -> ha, hu_l4 -> ha_l4
    hu, ha = frames[hu_key], frames[ha_key]
    energy = frames["energy"].astype(np.float32)
    prev = frames["prev_state"].astype(np.int64)
    mode = frames.get("mode")
    if mode is None:
        mode = np.zeros(len(energy), np.int8)
    mode = mode.astype(np.int8)
    z, fast = fast_stream(core, tap, hu, ha, energy, prev, mode)

    rows = []
    for f, kind in event_frames(energy, fast, min_run, deb, trig or {}):
        if f + 1 < window or f >= len(energy):
            continue
        sl = slice(f + 1 - window, f + 1)
        rows.append({
            "z": z[sl], "fast": fast[sl], "energy": energy[sl], "prev_state": prev[sl],
            "mode": mode[sl], "activity": (energy[sl] > VAD_DB).astype(np.int8),
            "kind": kind, "frame": f, "teacher": frames["teacher"][f].astype(np.float32),
        })
        # pause-vs-completion label from the teacher's own ENDPOINT events: does a turn
        # commit within the conversational horizon? (Sparse corpus eot/hold point labels
        # are not a dense target; see docs/voice-decision-model.md P6.)
        if events is not None:
            ef, ek = events
            hit = any(k == "ENDPOINT" and f + 1 <= int(e) <= f + 1 + COMMIT_HORIZON
                      for e, k in zip(ef, ek))
            rows[-1]["commit"] = np.int8(1 if hit else 0)
        else:
            rows[-1]["commit"] = np.int8(0)
    if not rows:
        return None
    return {k: np.stack([r[k] for r in rows]) for k in rows[0]}


def save_session(path, session_id, events, window=WINDOW, tap=None, hu_key="hu"):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    np.savez_compressed(path, **events, meta=np.array(json.dumps({
        "session_id": session_id, "events": int(len(events["frame"])),
        "window": int(window), "tap": tap, "hu_key": hu_key, "frame_ms": FRAME_MS,
    })))


def load_session(path):
    with np.load(path) as z:
        meta = json.loads(str(z["meta"]))
        out = {k: z[k] for k in z.files if k != "meta"}
    return out, meta


def iter_sessions(dirpath):
    for path in sorted(glob.glob(os.path.join(dirpath, "*.npz"))):
        yield path, *load_session(path)


def build_split(shards, out, student, tap, hu_key="hu", window=WINDOW, min_run=2, deb=2,
                trig=None, device="cpu", limit=0):
    """Serialize every shard in a directory. Writes <session>.npz + events.jsonl."""
    _model, core, bound, _ckpt = load_fast(student, tap)
    core.eval()
    tap = bound
    paths = sorted(glob.glob(os.path.join(shards, "*.npz")))
    if limit:
        paths = paths[:limit]
    if not paths:
        sys.exit(f"no shards in {shards}")
    os.makedirs(out, exist_ok=True)
    index = []
    total = 0
    for path in paths:
        with np.load(path) as z:
            frames = {k: z[k] for k in z.files
                      if not k.startswith(("lab_", "ev_")) and k != "meta"}
            events = ((z["ev_frames"], z["ev_kinds"]) if "ev_frames" in z.files else None)
            sid = json.loads(str(z["meta"]))["session_id"] if "meta" in z.files else os.path.basename(path)
        ev = serialize_session(frames, core, tap, window, min_run, deb, trig, hu_key, events)
        if ev is None:
            print(f"  {sid[:16]}… no events, skipped", flush=True)
            continue
        save_session(os.path.join(out, f"{os.path.splitext(os.path.basename(path))[0]}.npz"),
                     sid, ev, window, tap, hu_key)
        kinds = [EVENT_KINDS[int(k)] for k in ev["kind"]]
        for i, f in enumerate(ev["frame"].tolist()):
            index.append({"session_id": sid, "frame": int(f), "kind": kinds[i],
                          "teacher_scores": [round(float(x), 6) for x in ev["teacher"][i]]})
        total += len(ev["frame"])
        print(f"  {sid[:16]}… {len(frames['energy'])} frames -> {len(ev['frame'])} events", flush=True)
    with open(os.path.join(out, "events.jsonl"), "w") as f:
        for row in index:
            f.write(json.dumps(row) + "\n")
    counts = {k: sum(1 for r in index if r["kind"] == k) for k in EVENT_KINDS}
    print(f"wrote {total} events to {out} ({', '.join(f'{k} {v}' for k, v in counts.items())})")
    return index


def record(state_probs, answers, teacher, session_id, frame, kind, model_name,
           thresholds=TEACHER_THRESHOLDS, z_ref=None):
    """One record in the `docs/voice-decisions.md` v0.1 shape (Jev fields retained).
    `state` carries the scalar signals a reader can diff; the latent window is the
    referenced tensor state (the whole decoder input), never hidden live state."""
    state_labels = ("LISTEN", "HOLD", "SPEAK", "BACKCHANNEL")
    choice = state_labels[int(np.argmax(state_probs))].lower()
    conf = max(float(x) for x in state_probs)
    bins = [0.0, 0.0, 0.0]
    bins[0 if conf < 1 / 3 else 1 if conf < 2 / 3 else 2] = 1.0
    return {
        "schema_version": "IDFON-VOICE-DECISION/1",
        "source_ref": {"dataset": "anyreach-ai/dualturn-otospeech-turn-taking",
                       "revision": "v0.1", "conversation_id": session_id,
                       "start_ms": max(0, int(frame) * FRAME_MS - 2000),
                       "end_ms": int(frame) * FRAME_MS + FRAME_MS,
                       "channels": {"user": "ch0", "agent": "ch1"}},
        "trace": f"{session_id}:e{int(frame)}",
        "turn_id": f"{session_id}:e{int(frame)}",
        "ts": round(int(frame) * FRAME_MS / 1000.0, 2),
        "tier": "on_device",
        "model": model_name,
        "policy": {"rules_revision": "idfon-voice-turns", "frame_ms": FRAME_MS,
                   "thresholds": dict(thresholds)},
        "state": {"mode": "speaking" if answers.get("_mode") else "listen",
                  "event": kind, "latent_ref": z_ref},
        "questions": {
            "turn_state": {"type": "choice", "instructions": "Which turn state is likeliest?",
                           "criteria": {k.lower(): k for k in state_labels}},
            "end_of_turn": {"type": "noul", "instructions": "Has the caller finished?",
                            "criteria": {"true": "Commit the turn.", "false": "Hold."}},
            "barge_in": {"type": "noul",
                         "instructions": "Is the caller cutting in while the agent is speaking?",
                         "criteria": {"true": "Yield.", "false": "Keep the floor."}},
            "assistant_backchannel": {"type": "noul",
                                      "instructions": "Should the agent acknowledge briefly?",
                                      "criteria": {"true": "Acknowledge.", "false": "Listen silently."}},
            "commit": {"type": "noul",
                       "instructions": "Will this pause commit the turn within 400 ms?",
                       "criteria": {"true": "Commit now.", "false": "Keep holding."}},
            "decision_confidence": {"type": "score",
                                    "instructions": "How confident is the turn-state call?",
                                    "criteria": ["low", "medium", "high"]},
        },
        "answers": {
            "turn_state": {"type": "choice", "choice": choice,
                           "probabilities": {k.lower(): round(float(p), 6)
                                             for k, p in zip(state_labels, state_probs)},
                           "confidence": round(conf, 6)},
            "end_of_turn": {"type": "noul", "noul": round(float(answers["endpoint"]), 6)},
            "barge_in": {"type": "noul", "noul": round(float(answers["barge"]), 6)},
            "assistant_backchannel": {"type": "noul",
                                      "noul": round(float(answers["backchannel"]), 6)},
            "commit": {"type": "noul", "noul": round(float(answers.get("commit", 0.0)), 6)},
            "decision_confidence": {"type": "score", "score": round(conf, 6),
                                    "confidence": round(conf, 6),
                                    "legend": {"0": "low", "1": "medium", "2": "high"},
                                    "probabilities": {str(i): round(b, 6) for i, b in enumerate(bins)}},
        },
        "action": {"id": "not_executed", "executed": False},
        "teacher_proposal": {"source": "tyger-rules", "events": []},
        "outcome": None,
        "label": None,
        "teacher_scores": {
            "heads": ["state_listen", "state_hold", "state_speak", "state_backchannel",
                      "hazard", "yield", "bc", "p_end"],
            "values": [round(float(x), 6) for x in teacher[:8]],
        },
    }


def selfcheck():
    """No checkpoint needed: a random SharedLatentStudent is a deterministic stand-in."""
    from model import SharedLatentStudent
    from registry import HEADS, adapter_by_id

    torch.manual_seed(0)
    model = SharedLatentStudent(HEADS, adapters=[adapter_by_id("l4-streaming")])
    model.eval()
    T = 400
    rng = np.random.default_rng(0)
    energy = np.full(T, -60.0, np.float32)
    energy[40:120] = -30  # a voiced run -> pause at 120, onset at 40
    energy[200:260] = -28
    energy[300:360] = -26
    frames = {"hu": rng.standard_normal((T, 1024)).astype(np.float32) * 0.1,
              "ha": rng.standard_normal((T, 1024)).astype(np.float32) * 0.1,
              "energy": energy, "prev_state": np.zeros(T, np.int64),
              "teacher": np.zeros((T, 8), np.float32)}
    ev1 = serialize_session(frames, model, "l4-streaming")
    ev2 = serialize_session(frames, model, "l4-streaming")
    assert ev1 is not None, "no events on a patterned energy track"
    for k in ev1:
        assert np.array_equal(ev1[k], ev2[k]), f"serializer is not deterministic: {k}"
    assert ev1["z"].shape[1:] == (WINDOW, LATENT_WIDTH), ev1["z"].shape
    assert ev1["fast"].shape[1:] == (WINDOW, 8)
    assert ev1["z"].dtype == np.float32 and ev1["kind"].dtype.kind == "i"
    # the pause/onset tracks are found and survive the window warm-up
    kinds = [EVENT_KINDS[int(k)] for k in ev1["kind"]]
    assert "pause" in kinds and "onset" in kinds, kinds
    assert int(ev1["frame"].min()) >= WINDOW - 1, ev1["frame"]

    rec = record(np.array([0.1, 0.5, 0.3, 0.1]), {"endpoint": 0.2, "barge": 0.3,
                 "backchannel": 0.4, "_mode": 0}, np.zeros(8), "s", 120, "pause", "selfcheck")
    assert rec["answers"]["turn_state"]["choice"] == "hold"
    assert rec["schema_version"] == "IDFON-VOICE-DECISION/1"
    assert set(rec["answers"]) == {"turn_state", "end_of_turn", "barge_in",
                                   "assistant_backchannel", "commit",
                                   "decision_confidence"}
    print("slow_state selfcheck ok")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--selfcheck", action="store_true")
    ap.add_argument("--shards", default=None, help="shard dir to serialize")
    ap.add_argument("--out", default=None)
    ap.add_argument("--student", default="bench-results/shared-consistent-l03/student.pt",
                    help="shared-latent fast checkpoint (the latent source)")
    ap.add_argument("--tap", default="l4-streaming", help="fast checkpoint adapter")
    ap.add_argument("--hu-key", default="hu",
                    help="feature key: 'hu' (canonical) or 'hu_l4' (a recorded layer)")
    ap.add_argument("--window", type=int, default=WINDOW)
    ap.add_argument("--min-run", type=int, default=2)
    ap.add_argument("--deb", type=int, default=2)
    ap.add_argument("--trig-endpoint", type=float, default=0.5)
    ap.add_argument("--trig-barge", type=float, default=0.2)
    ap.add_argument("--trig-bc", type=float, default=0.2)
    ap.add_argument("--limit", type=int, default=0, help="first N sessions (debug)")
    args = ap.parse_args()
    if args.selfcheck:
        selfcheck()
    elif args.shards and args.out:
        trig = {"endpoint": args.trig_endpoint, "barge": args.trig_barge,
                "backchannel": args.trig_bc}
        build_split(args.shards, args.out, args.student, args.tap, args.hu_key,
                    args.window, args.min_run, args.deb, trig, limit=args.limit)
    else:
        ap.error("need --shards/--out or --selfcheck")
