"""#102 Leg 2 — the L15 drift gate: can the streaming (cache-aware) encoder's layer-15
features drive the turn heads, or do they have to be the windowed re-encode?

Reference (what the heads were trained and tuned on, and what ships today): per
320 ms hop, re-encode the last 8 s window, read hidden_states[15], take its last 4
rows.  Candidate (the tap): one cache-aware pass over contiguous 560 ms mel chunks
(56 new + 9 pre-encode cache frames, the ASR's chunking), read hidden_states[15]
per chunk and drop the overlap row.

Scores both feature timelines through the SAME turn-taker + rules with live
prev_state, and reports parity7's decision agreement (same kind within +-2 frames,
aligned / max(ref, cand)) plus per-head |delta| -- the >=99% bar from #102.

Usage:
  TYGER_BUNDLE=... ports/tyger-student/.venv/bin/python ports/tyger-coreml/l15_tap.py
      [--split val] [--sessions 4] [--minutes 3] [--lookahead 3] [--student PATH]

Needs the reference shards (ports/tyger-student/featurize.py output) for the same
session ids; rows are read from the dataset in the split's order, like featurize.
"""
import argparse
import os
import sys
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ports/tyger-student"))

from data import load_shard, pick_features  # noqa: E402
from oracle import GRID, HOP, HOP_FRAMES, SR, WIN_S, Oracle, decode_channel, resample16k  # noqa: E402
from transformers.cache_utils import DynamicCache  # noqa: E402
from transformers.models.nemotron_asr_streaming.modeling_nemotron_asr_streaming import (  # noqa: E402
    NemotronAsrStreamingEncoderCausalConvPaddingCache)

CHUNK_MEL = 56      # the ASR's chunk (560 ms)
PRE_ENCODE = 9      # its pre-encode cache (mel frames carried between chunks)
DATASET = "anyreach-ai/dualturn-otospeech-turn-taking"


def l15_stream(oracle, wav, lookahead, layer=15):
    """(samples,) -> (frames, 1024) L15 rows in time order, one cache-aware pass."""
    enc = oracle.asr.encoder
    feats = oracle.proc(np.asarray(wav, np.float32), sampling_rate=SR,
                        return_tensors="pt")["input_features"].to(oracle.device)
    cache = DynamicCache(config=enc.config)
    pc = NemotronAsrStreamingEncoderCausalConvPaddingCache()
    T = feats.shape[1]
    rows = []
    with torch.no_grad():
        for end in range(PRE_ENCODE + CHUNK_MEL, T + 1, CHUNK_MEL):
            out = enc(input_features=feats[:, end - PRE_ENCODE - CHUNK_MEL:end],
                      use_cache=True, past_key_values=cache, padding_cache=pc,
                      num_lookahead_tokens=lookahead, output_hidden_states=True)
            h = out.hidden_states[layer][0].float()
            rows.append(h[1:])  # the first row re-covers the 9 cached mel frames
    return torch.cat(rows).detach().cpu().numpy() if rows else np.zeros((0, 1024), np.float32)


def align(ref, cand, span=8):
    """Best constant frame offset (cand[i] vs ref[i+off]) by mean cosine."""
    best = (0, -2.0)
    for off in range(-span, span + 1):
        a, b = (ref[off:], cand) if off >= 0 else (ref, cand[-off:])
        n = min(len(a), len(b))
        if n < 50:
            continue
        a, b = a[:n], b[:n]
        cos = float(np.mean(np.sum(a * b, 1) /
                            (np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1) + 1e-9)))
        if cos > best[1]:
            best = (off, cos)
    return best


def head_vecs(oracle, hu, ha, energy, vec_fn=None):
    """Per-frame 8-vectors. vec_fn (student) bypasses the teacher step."""
    outs, cache = [], None
    sess = oracle.EarsSession(0)
    for f in range(len(energy)):
        prev = int(sess.prev_state)
        if vec_fn is None:
            o, cache = oracle.head_step(hu[f], ha[f], float(energy[f]), prev, cache)
        else:
            o = vec_fn(hu[f], ha[f], float(energy[f]), prev)
        outs.append(o)
        oracle.rules.on_frame(sess, "response", o, float(energy[f]), left=3 - (f % HOP_FRAMES))
    return np.stack(outs)


def events_of(oracle, vecs, energy):
    sess = oracle.EarsSession(0)
    evs = []
    for f in range(len(vecs)):
        e, _final, _reset = oracle.rules.on_frame(
            sess, "response", vecs[f], float(energy[f]), left=3 - (f % HOP_FRAMES))
        for x in e:
            if x["kind"] != "FRAME":
                evs.append((f + 1, x["kind"]))
    return evs


def aligned_count(a, b, tol=2):
    used = set()
    for fa, ka in a:
        for j, (fb, kb) in enumerate(b):
            if j not in used and ka == kb and abs(fa - fb) <= tol:
                used.add(j)
                break
    return len(used), len(a) - len(used), len(b) - len(used)


def student_fn(path, device="cpu"):
    from model import Student
    from registry import by_id
    ck = torch.load(path, map_location=device)
    m = Student([by_id(i) for i in ck["heads"]], width=ck["width"], layers=ck["layers"]).to(device)
    m.load_state_dict(ck["state_dict"])
    m.eval()
    hidden = {}

    def vec(hu, ha, act, prev):
        with torch.no_grad():
            o, hidden["h"] = m(torch.as_tensor(hu, device=device)[None, None],
                               torch.as_tensor(ha, device=device)[None, None],
                               torch.tensor([[float(act)]], device=device),
                               torch.tensor([[int(prev)]], device=device),
                               hidden.get("h"))
            return m.eight_vector(o)[0, 0].cpu().numpy().astype(np.float64)

    return vec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", default="val")
    ap.add_argument("--sessions", type=int, default=4)
    ap.add_argument("--minutes", type=float, default=3)
    ap.add_argument("--lookahead", type=int, default=3)
    ap.add_argument("--shards", default=str(ROOT / "bench-results/student-shards/val"))
    ap.add_argument("--student", default=None, help="also score this student.pt instead of the teacher step")
    ap.add_argument("--layer", type=int, default=15, help="encoder layer the heads read (#102's cut sweep: 4)")
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args()

    oracle = Oracle(device=args.device).load_bundle()
    vec_fn = student_fn(args.student, args.device) if args.student else None
    from datasets import load_dataset
    from transformers import AutoModel

    mimi = AutoModel.from_pretrained("kyutai/mimi", dtype=torch.float32).eval()
    rows = iter(load_dataset(DATASET, split=args.split, streaming=True))
    limit = int(args.minutes * 60 * GRID)
    total = np.zeros(4, int)
    feats = []
    for _ in range(args.sessions):
        row = next(rows)
        sid = row["session_id"]
        path = Path(args.shards) / f"{sid}.npz"
        if not path.exists():
            print(f"{sid[:16]}… no reference shard at {path}", flush=True)
            continue
        ref_frames, labels, teacher_events, meta = load_shard(path)
        T = int(row["num_frames"])
        codes = {ch: np.array(row[f"codes_{ch}"], dtype=np.int16).reshape(T, 8)[:limit]
                 for ch in ("ch0", "ch1")}
        wav = {ch: resample16k(decode_channel(mimi, codes[ch])) for ch in ("ch0", "ch1")}
        huf, haf = pick_features(ref_frames, args.layer)
        ref = {"ch0": huf, "ch1": haf}
        cand = {ch: l15_stream(oracle, wav[ch], args.lookahead, args.layer) for ch in ("ch0", "ch1")}
        off, cos = align(ref["ch0"], cand["ch0"])
        off1, cos1 = align(ref["ch1"], cand["ch1"])
        n = min(len(ref["ch0"]), len(cand["ch0"]) - off, len(ref["ch1"]), len(cand["ch1"]) - off1)
        cand = {ch: cand[ch][off:off + n] for ch in ("ch0", "ch1")}
        ref = {ch: ref[ch][:n] for ch in ("ch0", "ch1")}
        energy = ref_frames["energy"][:n]
        d = np.abs(np.concatenate([cand[c] for c in cand]) - np.concatenate([ref[c] for c in ref]))
        vref = head_vecs(oracle, ref["ch0"], ref["ch1"], energy, vec_fn)
        vcand = head_vecs(oracle, cand["ch0"], cand["ch1"], energy, vec_fn)
        eref = events_of(oracle, vref, energy)
        ecand = events_of(oracle, vcand, energy)
        hit, only_ref, only_cand = aligned_count(eref, ecand)
        agree = hit / max(len(eref), len(ecand))
        total += [hit, only_ref, only_cand, max(len(eref), len(ecand))]
        vd = np.abs(vref - vcand)
        feats.append((cos, cos1, float(d.mean()), float(vd.max()),
                      float(np.mean(vd[:, 7])), agree))
        print(f"{sid[:16]}… {n} frames  off {off:+d}/{off1:+d}  cos {cos:.4f}/{cos1:.4f}  "
              f"feat|d| {d.mean():.4f}  head|d| p_end {np.mean(vd[:, 7]):.4f} "
              f"max {vd.max():.3f}  events ref/cand {len(eref)}/{len(ecand)}  "
              f"agree {agree * 100:.1f}%  ({hit} aligned, -{only_ref}/+{only_cand})", flush=True)
    print(f"\nTOTAL aligned {total[0]}/{total[3]} = {total[0] / max(total[3], 1) * 100:.2f}% "
          f"(bar 99%), missing {total[1]}, spurious {total[2]}")


if __name__ == "__main__":
    main()
