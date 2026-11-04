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


# --- the shared decision latent + tap adapters (epic #132) ---------------------
# z is the shared causal decision latent: z_t = GRU(z_{t-1}, sum of the available
# inputs), with ONE decoder (out_norm + the heads above) behind it. Each adapter
# maps one tap's two streams into the fuse width, so every tap path is trained
# toward the same decision endpoint (consistency distillation, #132 P3) and the
# deployed student runs one pass from whichever tap the streaming ASR already
# computes — no second encoder pass. Adapter ids are per (layer, pass) because
# the passes are not interchangeable without their own adapter + calibration fit
# (probe quality per tap: bench-results/tap-probes.md). Auxiliary signals (VAD/BCD
# posteriors, #131) enter as extra adapters of kind "aux", not extra models.

LATENT_WIDTH = 256   # z_t width — the shared trunk's width


@dataclass(frozen=True)
class Adapter:
    id: str        # unique tap identity, e.g. "l4-streaming"
    kind: str      # "tap" (encoder hidden state) | "aux" (posterior/signal)
    width: int     # feature width per stream (1024 for the Nemotron taps)
    note: str


ADAPTERS = (
    Adapter("l15-windowed", "tap", 1024, "the teacher's own inputs (Tyger windowed re-encode)"),
    Adapter("l4-windowed", "tap", 1024, "the shipped L4 encoder cut (#102)"),
    Adapter("l4-streaming", "tap", 1024,
            "the streaming ASR's L4 tap — the deploy target (probe parity with l4-windowed)"),
    Adapter("l24-streaming", "tap", 1024,
            "the ASR's final layer — the portability baseline (probe-poor, #134)"),
    Adapter("l15-streaming", "tap", 1024, "declared: streaming L15 tap, extraction not wired yet"),
    # second-ASR portability (#132 P5): parakeet-unified-en-0.6b (Unified-FastConformer-RNNT,
    # 24 layers x 1024-d, x8 subsampling = the 80 ms grid). L12 is the probe-sweep winner
    # (per-depth table: bench-results/parakeet-tap-probes.md; mean R2 .554 vs the Nemotron
    # l4-streaming .564 — the tap equivalents land mid-encoder here too). "-full" names the
    # full-context pass; a streaming-pass adapter would be its own entry + calibration fit.
    Adapter("parakeet-l12-full", "tap", 1024,
            "parakeet-unified-en-0.6b L12 full-context tap — the second ASR (#132 P5)"),
)


def adapter_by_id(adapter_id):
    for a in ADAPTERS:
        if a.id == adapter_id:
            return a
    raise KeyError(f"no such adapter: {adapter_id!r} (registry.py)")


# Per-adapter gate ceilings where tap information bounds what any model can do
# (#137 P2 measured): on L4 features the endpoint head cannot reach the L15-path
# .02 gate — probe R2 .78 vs .81 — and the shipped L4 student ships at .0273.
# Head.gate stays the universal bar; these override it per adapter in the
# multi-tap report (train_shared), so "gates pass" stays meaningful per tap.
ADAPTER_GATE = {
    "l4-windowed": {"endpoint": {"metric": "mse", "max": 0.028}},
    "l4-streaming": {"endpoint": {"metric": "mse", "max": 0.028}},
}
