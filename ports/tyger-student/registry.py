"""The decision-point registry: what the student decides, where each answer's training
signal comes from, and the gate it must pass. This table is the investment surface —
adding a decision point is one entry here plus its labels in the shards; the model,
the training loop, and the gate report all read it.

`kind` is the System One question type (docs/voice-decisions.md): `noul` (P(true)),
`choice`, `score`. `source` names the training signal:

  teacher:<cols>   the fp32 Tyger oracle's per-frame 8-vector (distillation). `cols`
                   indexes the 8-vector slots ("0-3" = state logits, "7" = p_end);
                   `choice` targets are softmaxed, `noul` targets are already probs.
  corpus:<key>     per-frame corpus labels (anyreach dualturn keys, e.g. "hold_ch0").
  outcome:<id>     weak labels from the TYGER_DECISION_LOG (declared, not wired yet).
  gold:<id>        human labels (declared, not wired yet).

`loss`: `ce`/`bce` distill soft teacher targets with cross-entropy — the gradient is
p−t, so it does not vanish where the student is confidently wrong (the spurious-fire
fix; `bce` also trains hard 0/1 corpus labels). `mse` is plain probability matching,
kept for A/B (`train.py --distill-loss mse`) — its gradient vanishes on confident
errors. `gate` is checked by train.py's report:
{"metric": "mse"|"auc", "max"|"min": limit} — {} is report-only (the bar gets set
after the first real run, the way parity6/7 did).
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class Head:
    id: str
    kind: str          # "noul" | "choice" | "score"
    size: int          # output dim (choice: len(labels); noul/score: 1)
    labels: tuple      # choice labels, ("false", "true"), or the score legend
    source: str        # training signal, see module docstring
    loss: str          # "ce" | "bce" | "mse"
    gate: dict
    pos_weight: float = 1.0  # bce only: upweight the positive ("fire") frames — rare-fire heads are ~1% positives
                             # (train.py --pos-weight overrides it on barge/backchannel for the A/B)


# The rules seam (crates/idfon-voice/src/turns.rs, ports/tyger-mlx/turn_taker.py):
# the 8-vector the rules layer reads per frame — 4 state logits, then hazard, yield
# (barge), bc, p_end probabilities. The student must emit this contract unchanged.
SEAM_ORDER = ("state", "hazard", "barge", "backchannel", "endpoint")
SEAM_SIZE = 8

HEADS = (
    # --- the seam: distilled from the teacher (fp32 Tyger, its 8-vector per frame) ---
    Head("state", "choice", 4, ("LISTEN", "HOLD", "SPEAK", "BACKCHANNEL"),
         "teacher:0-3", "ce", {"metric": "mse", "max": 0.02}),
    Head("hazard", "noul", 1, ("false", "true"),
         "teacher:4", "bce", {"metric": "mse", "max": 0.02}),
    Head("barge", "noul", 1, ("false", "true"),
         "teacher:5", "bce", {"metric": "mse", "max": 0.02}),
    Head("backchannel", "noul", 1, ("false", "true"),
         "teacher:6", "bce", {"metric": "mse", "max": 0.02}),
    Head("endpoint", "noul", 1, ("false", "true"),
         "teacher:7", "bce", {"metric": "mse", "max": 0.02}),
    # --- the first decision point the teacher does not have: within-turn pause
    # ("the user is not done"). Labeled directly by the corpus, no teacher slot —
    # the template for every decision point we add from here on.
    Head("hold", "noul", 1, ("false", "true"),
         "corpus:hold_ch0", "bce", {}),
)


def by_id(head_id):
    for h in HEADS:
        if h.id == head_id:
            return h
    raise KeyError(f"no such decision point: {head_id!r} (registry.py)")


def seam_heads():
    """The seam heads in 8-vector order."""
    return [by_id(i) for i in SEAM_ORDER]


def teacher_cols(head):
    """The 8-vector columns a teacher-sourced head distills, or None."""
    if not head.source.startswith("teacher:"):
        return None
    spec = head.source.split(":", 1)[1]
    if "-" in spec:
        a, b = spec.split("-")
        return list(range(int(a), int(b) + 1))
    return [int(spec)]


def corpus_key(head):
    """The shard label key a corpus-sourced head trains on, or None."""
    return head.source.split(":", 1)[1] if head.source.startswith("corpus:") else None
