"""The two P6 slow-tier decoder shapes (issue #160), trained on serialized event
states from `slow_state.py`.

A. `ZSlow` — cheap heads over the shared latent: a 1-layer GRU over the trailing
   `z` window (2 s), one linear head per question. The decoder sees only `z` (plus
   the event kind), so its marginal bytes are the decoder alone: the fast tier
   already computes `z`. This is the "decode from `z`" shape.

B. `StateSlow` — a tiny sequence decision model over the full serialized state:
   per-frame tokens of `z` + the fast tier's 8-vector + energy + floor state + mode
   + activity, a transformer encoder, then the same heads. This is the
   "tiny decision model over a serialized trailing window" shape. `d=128, layers=2`
   is the small rung; `d=256, layers=4` is the capacity-scaling rung that answers
   whether the gap is parameter count at all (the named 600M–4B checkpoints are
   not runnable in this repo's measurement environment).

Both emit the same structured questions — state (`choice`), end_of_turn / barge_in /
assistant_backchannel (`noul`), decision_confidence (`score`) — and are pure
functions of the serialized state (no carried hidden state, no frame-level loop).

    .venv/bin/python ports/tyger-student/slow_model.py --selfcheck

Training/eval lives in `slow_train.py`.
"""
import argparse
import os
import sys

import torch
import torch.nn as nn

from registry import Head, seam_heads

STATE_LABELS = ("LISTEN", "HOLD", "SPEAK", "BACKCHANNEL")
CONFIDENCE_LABELS = ("low", "medium", "high")
SLOW_HEADS = tuple(seam_heads()) + (
    Head("commit", "noul", 1, ("false", "true"), "teacher events:ENDPOINT+400ms", "bce", {}),
    Head("confidence", "score", 3, CONFIDENCE_LABELS, "teacher:0-3 (derived)", "ce", {}),
)
EVENT_KINDS = ("pause", "onset", "fast_endpoint", "fast_barge", "fast_backchannel")
N_KINDS = len(EVENT_KINDS)
LATENT_WIDTH = 256


class SlowHeads(nn.Module):
    """The decoder head set shared by both shapes."""

    def __init__(self, width, heads=SLOW_HEADS):
        super().__init__()
        self.heads_spec = list(heads)
        self.heads = nn.ModuleDict({h.id: nn.Linear(width, h.size) for h in self.heads_spec})

    def forward(self, h):
        return {head.id: self.heads[head.id](h) for head in self.heads_spec}


def probabilities(outs):
    """Head outputs -> the record's answer probabilities."""
    return {
        "state": torch.softmax(outs["state"], dim=-1),
        "endpoint": torch.sigmoid(outs["endpoint"].squeeze(-1)),
        "barge": torch.sigmoid(outs["barge"].squeeze(-1)),
        "backchannel": torch.sigmoid(outs["backchannel"].squeeze(-1)),
        "commit": torch.sigmoid(outs["commit"].squeeze(-1)),
        "confidence": torch.softmax(outs["confidence"], dim=-1),
    }


class ZSlow(nn.Module):
    """Shape A: cheap GRU decoder over the trailing shared-latent window."""

    arch = "z-gru"

    def __init__(self, heads=SLOW_HEADS, hidden=128, layers=1):
        super().__init__()
        self.width, self.layers = hidden, layers
        self.core = nn.GRU(LATENT_WIDTH, hidden, num_layers=layers, batch_first=True)
        self.event = nn.Embedding(N_KINDS, hidden)
        self.out_norm = nn.LayerNorm(hidden)
        self.heads_spec = list(heads)
        self.heads = SlowHeads(hidden, heads)

    def forward(self, z, kind):
        h, _ = self.core(z)
        h = self.out_norm(h[:, -1] + self.event(kind))
        return self.heads(h)

    def config(self):
        return {"hidden": self.width, "layers": self.layers}


class StateSlow(nn.Module):
    """Shape B: transformer decision model over the serialized per-frame state."""

    arch = "state-transformer"

    def __init__(self, heads=SLOW_HEADS, d=128, layers=2, nhead=4, dropout=0.0):
        super().__init__()
        self.d, self.layers = d, layers
        self.inp = nn.Linear(LATENT_WIDTH + 8 + 3, d)  # z, fast 8, energy/mode/activity
        self.prev = nn.Embedding(5, d)
        self.pos = nn.Embedding(64, d)  # max trailing window
        self.event = nn.Embedding(N_KINDS, d)
        layer = nn.TransformerEncoderLayer(d, nhead, dim_feedforward=2 * d, dropout=dropout,
                                           batch_first=True, norm_first=True)
        self.encoder = nn.TransformerEncoder(layer, layers, enable_nested_tensor=False)
        self.norm = nn.LayerNorm(d)
        self.heads_spec = list(heads)
        self.heads = SlowHeads(d, heads)

    def forward(self, z, fast, energy, prev_state, mode, activity, kind):
        T = z.shape[1]
        energy = ((energy + 50.0) / 25.0).clamp(-3.0, 3.0)
        x = torch.cat([z, fast, energy.unsqueeze(-1), mode.float().unsqueeze(-1),
                       activity.float().unsqueeze(-1)], dim=-1)
        h = self.inp(x) + self.prev(prev_state.long()) + self.pos(
            torch.arange(T, device=z.device))[None]
        h = self.norm(self.encoder(h))
        h = h[:, -1] + self.event(kind)
        return self.heads(h)

    def config(self):
        return {"d": self.d, "layers": self.layers}


def build(arch, config=None):
    config = config or {}
    if arch == "z-gru":
        return ZSlow(SLOW_HEADS, **config)
    if arch == "state-transformer":
        return StateSlow(SLOW_HEADS, **config)
    if arch == "state-transformer-large":
        m = StateSlow(SLOW_HEADS, d=256, layers=4)
        m.arch = "state-transformer-large"  # same class, its own artifact identity
        return m
    raise KeyError(f"unknown slow decoder: {arch!r}")


def forward_state(model, s):
    """One batch of serialized event states -> head outputs. `s` is the dict of
    stacked slow_state arrays (torch tensors, batch-first)."""
    if model.arch == "z-gru":
        return model(s["z"], s["kind"])
    return model(s["z"], s["fast"], s["energy"], s["prev_state"], s["mode"],
                 s["activity"], s["kind"])


def count_params(model):
    return sum(p.numel() for p in model.parameters())


def save(path, model, heads=SLOW_HEADS):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    torch.save({"arch": model.arch, "config": model.config(),
                "heads": [h.id for h in heads], "state_dict": model.state_dict(),
                "params": count_params(model)}, path)


def load(path, device="cpu"):
    ckpt = torch.load(path, map_location=device)
    model = build(ckpt["arch"], ckpt.get("config"))
    model.load_state_dict(ckpt["state_dict"])
    return model.to(device).eval(), ckpt


def selfcheck():
    torch.manual_seed(0)
    B, T = 4, 25
    z = torch.randn(B, T, LATENT_WIDTH)
    fast = torch.rand(B, T, 8)
    energy = torch.rand(B, T) * 60 - 60
    prev = torch.randint(0, 5, (B, T))
    mode = torch.randint(0, 2, (B, T), dtype=torch.int8)
    act = (energy > -50).to(torch.int8)
    kind = torch.randint(0, N_KINDS, (B,))
    for arch in ("z-gru", "state-transformer", "state-transformer-large"):
        m = build(arch)
        m.eval()
        with torch.no_grad():
            outs = m(z, kind) if arch == "z-gru" else m(z, fast, energy, prev, mode, act, kind)
        probs = probabilities(outs)
        assert probs["state"].shape == (B, 4) and probs["endpoint"].shape == (B,)
        assert torch.allclose(probs["state"].sum(-1), torch.ones(B), atol=1e-5)
        assert torch.allclose(probs["confidence"].sum(-1), torch.ones(B), atol=1e-5)
        assert sorted(outs) == sorted(h.id for h in SLOW_HEADS)
        p = f"/tmp/slow-selfcheck-{arch.replace('-', '_')}.pt"
        save(p, m)
        m2, ckpt = load(p)
        assert ckpt["arch"] == arch and count_params(m2) == count_params(m)
        with torch.no_grad():
            outs2 = m2(z, kind) if arch == "z-gru" else m2(z, fast, energy, prev, mode, act, kind)
        for k in outs:
            assert torch.allclose(outs[k], outs2[k], atol=1e-6), (arch, k)
        print(f"{arch:<24} {count_params(m):>9,} params  {count_params(m) * 4 / 1e6:5.2f} MB fp32")
    print("slow_model selfcheck ok")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args()
    if args.selfcheck:
        selfcheck()
    else:
        ap.error("need --selfcheck (training/eval: slow_train.py)")
