"""Tone of the caller's turn at each floor handoff, cross-tabbed with the model's fires.

The selector is text (Pipecat's tone reader), the turn model is audio, so this is a
stratifier that does not inherit the turn model's own mistakes. It answers two
questions the fire-sampled audit could not: which emotions the head catches and
misses, and where to sample a harder audit set from.

Handoffs come from `openyap-handoffs.py` (agent speaks, stops, caller starts); the
caller's turn text comes from Open Yap's per-speaker word timings, so no ASR and
no audio are involved on this path.

    .venv/bin/python scripts/openyap-tone.py --wavs /tmp/openyap/wav \\
        --transcripts /tmp/openyap/tar --model /tmp/tonemodel \\
        --shards bench-results/openyap-shards-v2

  --selfcheck   word selection and the sarcasm calibration on fixed inputs
"""
from __future__ import annotations

import argparse
import glob
import importlib.util
import json
import os
import sys

import numpy as np

FRAME_S = 0.08


def _handoffs_module():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "openyap-handoffs.py")
    spec = importlib.util.spec_from_file_location("openyap_handoffs", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def turn_text(words: list[dict], t_on: float, t_off: float, max_words: int = 40) -> str:
    """The caller's words inside their turn, in order."""
    picked = [w["word"] for w in words if w["start"] >= t_on - 0.05 and w["start"] < t_off + 0.05]
    return " ".join(picked[:max_words]).strip()


def sigmoid(x: float) -> float:
    return 1.0 / (1.0 + np.exp(-x))


class Tone:
    """Pipecat's tone reader (tone-text-0.1): emotion, intensity, move, sarcasm."""

    def __init__(self, model_dir: str):
        import onnxruntime as ort
        from tokenizers import Tokenizer
        self.cfg = json.load(open(os.path.join(model_dir, "config.json")))
        self.tok = Tokenizer.from_file(os.path.join(model_dir, "tokenizer.json"))
        self.tok.enable_truncation(max_length=self.cfg["max_len"])
        self.sess = ort.InferenceSession(os.path.join(model_dir, "model_fp16.onnx"),
                                         providers=["CPUExecutionProvider"])
        self.cal = self.cfg.get("calibration") or {}

    def read(self, text: str) -> dict:
        enc = self.tok.encode(text)
        ids = np.array([enc.ids], np.int64)
        mask = np.array([enc.attention_mask], np.int64)
        out = self.sess.run(None, {"input_ids": ids, "attention_mask": mask})
        names = [o.name for o in self.sess.get_outputs()]
        z = dict(zip(names, out))
        emo = softmax(z["emotion"][0] / self.cal.get("emotion_temperature", 1.0))
        sar_raw = float(z["sarcasm"][0][1])
        a = float((self.cal.get("sarcasm") or {}).get("a", 1.0))
        b = float((self.cal.get("sarcasm") or {}).get("b", 0.0))
        sar = sigmoid(a * np.log(max(sar_raw, 1e-6) / max(1 - sar_raw, 1e-6)) + b)
        mv = softmax(z["move"][0] / self.cal.get("move_temperature", 1.0))
        return {"emotion": self.cfg["emotions"][int(emo.argmax())], "p_emotion": float(emo.max()),
                "sarcasm": float(sar), "sarcastic": bool(sar >= self.cfg.get("sarcasm_tau_raw", 0.59)),
                "move": self.cfg["moves"][int(mv.argmax())], "text": text}


def softmax(x: np.ndarray) -> np.ndarray:
    e = np.exp(x - x.max())
    return e / e.sum()


def selfcheck() -> None:
    words = [{"word": "so", "start": 1.0}, {"word": "anyway", "start": 1.2},
             {"word": "wait", "start": 2.5}, {"word": "no", "start": 2.7}]
    assert turn_text(words, 2.4, 3.0) == "wait no", turn_text(words, 2.4, 3.0)
    assert turn_text(words, 0.9, 1.5) == "so anyway"
    assert turn_text([], 0, 1) == ""
    # the Platt curve is monotone and lands above the raw threshold only past the tau
    assert sigmoid(1.389637 * np.log(0.99 / 0.01) - 1.240533) > 0.9
    assert sigmoid(1.389637 * np.log(0.05 / 0.95) - 1.240533) < 0.1
    print("selfcheck ok")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wavs")
    ap.add_argument("--transcripts", help="dir of conv_*.json with per-speaker word timings")
    ap.add_argument("--model", help="dir with config.json, tokenizer.json, model_fp16.onnx")
    ap.add_argument("--shards", help="shard dir: score the model's catch on these handoffs")
    ap.add_argument("--out", help="write the per-handoff rows here (jsonl)")
    ap.add_argument("--selfcheck", action="store_true")
    a = ap.parse_args()
    if a.selfcheck:
        return selfcheck()
    if not (a.wavs and a.transcripts and a.model):
        ap.error("--wavs, --transcripts and --model are required (or --selfcheck)")

    H = _handoffs_module()
    tone = Tone(a.model)
    shards = {}
    if a.shards:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ports", "tyger-student"))
        from data import load_shard
        shards = {os.path.basename(p)[5:-4]: p for p in glob.glob(os.path.join(a.shards, "*.npz"))}

    rows = []
    empty = empty_fired = 0
    for wav in sorted(glob.glob(os.path.join(a.wavs, "*.wav"))):
        cid = os.path.basename(wav)[:-4]
        meta = os.path.join(a.transcripts, cid + ".json")
        if not os.path.exists(meta):
            continue
        j = json.load(open(meta))
        words = j["transcripts"]["a"]["words"]          # a = caller (ch0)
        caller, agent = H.energy(wav)
        y = None
        if cid in shards:
            frames, _l, _e, _m = load_shard(shards[cid])
            y = frames["teacher"][:, 5]
        for h in H.handoffs(caller, agent):
            t_on = h["caller_on"] * FRAME_S
            t_off = h["caller_off"] * FRAME_S
            text = turn_text(words, t_on, t_off)
            if not text:
                empty += 1
                if y is not None:
                    win = y[h["caller_on"]:h["caller_on"] + 9]
                    if len(win) and win.max() >= 0.5:
                        empty_fired += 1
                continue
            t = tone.read(text)
            fired = None
            if y is not None:
                win = y[h["caller_on"]:h["caller_on"] + 9]
                fired = bool(len(win) and win.max() >= 0.5)
            rows.append({"conversation_id": cid, **{k: h[k] for k in ("gap_ms", "caller_run_ms")},
                         **t, "fire_050": fired})

    if not rows:
        sys.exit("no handoffs with text; check --transcripts")

    def table(key, values, label):
        print(f"\n  by {label}:")
        print(f"    {'':<14}{'n':>5}{'catch@0.5':>11}{'mean gap':>10}{'med. run':>10}")
        for v in values:
            sub = [r for r in rows if (r[key] == v)]
            if not sub:
                continue
            got = [r for r in sub if r["fire_050"]]
            print(f"    {v:<14}{len(sub):>5}{100 * len(got) / len(sub):>10.0f}%"
                  f"{np.mean([r['gap_ms'] for r in sub]):>10.0f}"
                  f"{np.median([r['caller_run_ms'] for r in sub]):>10.0f}")

    emo = sorted({r["emotion"] for r in rows})
    table("emotion", emo, "emotion")
    table("move", sorted({r["move"] for r in rows}), "move")
    print("\n  by sarcasm:")
    for v in (True, False):
        sub = [r for r in rows if r["sarcastic"] == v]
        if sub:
            got = [r for r in sub if r["fire_050"]]
            print(f"    {'sarcastic' if v else 'sincere':<14}{len(sub):>5}"
                  f"{100 * len(got) / len(sub):>10.0f}%")
    tot = len(rows)
    fired = sum(1 for r in rows if r["fire_050"])
    print(f"\n  overall: {tot} handoffs with text, {fired} fired ({100 * fired / tot:.0f}%)")
    if empty:
        print(f"  handoffs with no transcribed words: {empty} "
              f"({100 * empty_fired / max(empty, 1):.0f}% of them fired)")
    if a.out:
        with open(a.out, "w") as fh:
            for r in rows:
                fh.write(json.dumps(r) + "\n")
        print(f"  rows -> {a.out}")


if __name__ == "__main__":
    main()
