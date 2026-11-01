"""The student decision model (P1 of docs/voice-decision-model.md): a width-256
2-layer causal GRU over the two L15 streams + frame energy + previous floor state,
with one linear head per registry entry (~1.3M params, ~5.3 MB fp32 — the size brief).

Contract with the rules layer is unchanged: `eight_vector()` assembles the same
8-vector the ports/tyger-* tiers emit per frame — 4 state logits, then hazard,
yield, bc, p_end probabilities — so everything above the seam (turns.rs, the apps'
TurnShadow, the traits) consumes it identically.

Anatomy follows the teacher 1:1 at reduced width (ports/tyger-mlx/turn_taker.py):
fuse projections summed + state embedding -> in_norm -> GRU -> out_norm -> heads.
Energy normalization ((db + 50) / 25 clamped to [-3, 3]) is baked in here, as in
the ONNX step export.
"""
import torch
import torch.nn as nn

from registry import SEAM_SIZE, corpus_key, seam_heads, teacher_cols

ENC_HIDDEN = 1024   # L15 width (the feature tap)
STATE_VOCAB = 5     # the teacher's state_emb rows: 4 states + a begin id


class Student(nn.Module):
    def __init__(self, heads, width=256, layers=2):
        super().__init__()
        self.heads_spec = list(heads)
        self.width = width
        self.layers = layers
        self.proj_user = nn.Linear(ENC_HIDDEN, width)
        self.proj_agent = nn.Linear(ENC_HIDDEN, width)
        self.proj_energy = nn.Linear(1, width)
        self.state_emb = nn.Embedding(STATE_VOCAB, width)
        self.in_norm = nn.LayerNorm(width)
        self.out_norm = nn.LayerNorm(width)
        self.core = nn.GRU(width, width, num_layers=layers, batch_first=True)
        self.heads = nn.ModuleDict({h.id: nn.Linear(width, h.size) for h in self.heads_spec})
        seam = seam_heads()
        assert sum(h.size for h in seam) == SEAM_SIZE, "registry seam must total 8 outputs"

    def forward(self, hu, ha, act_db, prev_state, hidden=None):
        """hu/ha (B, T, 1024) L15 frames, act_db (B, T) raw dB, prev_state (B, T) long
        -> ({head_id: (B, T, size)}, hidden)."""
        act = ((act_db + 50.0) / 25.0).clamp(-3.0, 3.0)
        z = (self.proj_user(hu) + self.proj_agent(ha)
             + self.proj_energy(act.unsqueeze(-1)) + self.state_emb(prev_state))
        z, hidden = self.core(self.in_norm(z), hidden)
        z = self.out_norm(z)
        return {h.id: self.heads[h.id](z) for h in self.heads_spec}, hidden

    def eight_vector(self, outs):
        """Assemble the rules-seam 8-vector: state logits x4, hazard, yield, bc, p_end
        (the noul slots are probabilities, as the teacher emits them)."""
        parts = []
        for h in seam_heads():
            o = outs[h.id]
            parts.append(torch.sigmoid(o) if h.kind == "noul" else o)
        return torch.cat(parts, dim=-1)

    def targets(self, teacher, labels):
        """Per-head training targets from a batch's teacher 8-vector / shard labels.
        Raises if a registry entry's source has no data — labels live in the shards,
        so a new decision point needs a featurize re-run before it can train."""
        out = {}
        for h in self.heads_spec:
            cols = teacher_cols(h)
            if cols is not None:
                t = teacher[..., cols]
                out[h.id] = torch.softmax(t, dim=-1) if h.kind == "choice" else t
            else:
                key = corpus_key(h)
                if key is None:
                    raise NotImplementedError(
                        f"head {h.id!r}: source {h.source!r} is declared but not wired")
                if labels is None or key not in labels:
                    raise KeyError(f"head {h.id!r}: shard labels lack {key!r}; re-run featurize.py")
                out[h.id] = labels[key].float()
        return out

    def losses(self, outs, targets):
        """Per-head losses (registry loss kinds), returned as {head_id: loss}."""
        res = {}
        for h in self.heads_spec:
            o, t = outs[h.id], targets[h.id]
            if h.loss == "mse":
                p = torch.softmax(o, dim=-1) if h.kind == "choice" else torch.sigmoid(o)
                res[h.id] = ((p - t) ** 2).mean()
            elif h.loss == "bce":
                # soft targets (teacher probs) or hard 0/1 labels; grad = p - t (never vanishes);
                # pos_weight rescales the t-term — upweights frames where the teacher says "fire"
                res[h.id] = nn.functional.binary_cross_entropy_with_logits(
                    o.squeeze(-1), t.squeeze(-1), pos_weight=o.new_tensor(h.pos_weight))
            elif h.loss == "ce":
                # soft targets: class-probability rows (torch accepts them as targets)
                res[h.id] = nn.functional.cross_entropy(
                    o.reshape(-1, o.shape[-1]), t.reshape(-1, t.shape[-1]))
            else:
                raise ValueError(f"head {h.id!r}: unknown loss {h.loss!r}")
        return res


def count_params(model):
    return sum(p.numel() for p in model.parameters())
