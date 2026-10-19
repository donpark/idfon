"""MLX port of the TYGER turn-taker: fuse -> 3-layer causal GRU -> five heads
(docs/voice-tyger-ondevice.md, S2). Port of tyger-s2s's `app/plugins/ears/tyger/controller.py`,
module names preserved so the bundle's `turn_taker.*` weights load 1:1.

Per frame it reads the user's and the agent's layer-15 features, the user's normalised
frame energy `(db + 50) / 25` clamped to [-3, 3] (the caller normalises, as in their
`head_step`), and the previous state id, and emits the 8-vector the turn rules read:
4 state logits, then hazard, yield (barge), backchannel and endpoint probabilities.

GRU follows torch's `nn.GRU` equations exactly (gate order r, z, n):
    r = σ(W_ir x + b_ir + W_hr h + b_hr)
    z = σ(W_iz x + b_iz + W_hz h + b_hz)
    n = tanh(W_in x + b_in + r ⊙ (W_hn h + b_hn))
    h' = (1 − z) ⊙ n + z ⊙ h
so stepping it one frame at a time with a carried state (the live path) matches
batch evaluation (parity2.py checks both).
"""
from pathlib import Path

import mlx.core as mx
from safetensors import safe_open

WIDTH = 768
LAYERS = 3
ENC_HIDDEN = 1024
N_STATE = 4


def load_turn_weights(bundle_dir):
    """{name: mx.array} as the model uses them: torch Linear rows transposed to mlx
    (in, out) except the GRU cell weights and state_emb."""
    w = {}
    with safe_open(Path(bundle_dir) / "model.safetensors", framework="np") as f:
        for k in f.keys():
            if k.startswith("turn_taker."):
                w[k[len("turn_taker."):]] = mx.array(f.get_tensor(k))
    for k in list(w):
        if k.endswith(".weight") and not k.startswith("core.") and k != "state_emb.weight":
            w[k] = w[k].T  # torch Linear (out, in) -> mlx rows (in, out)
    return w


class GRUCell:
    """One torch-GRU layer's weights, stepped frame by frame (or over a batch of frames)."""

    def __init__(self, w_ih, w_hh, b_ih, b_hh):
        d = WIDTH
        # torch (3d, d) with gate blocks [r, z, n] -> mlx rows per gate
        self.wx = [w_ih[0:d].T, w_ih[d:2 * d].T, w_ih[2 * d:3 * d].T]  # (d, d) each
        self.wh = [w_hh[0:d].T, w_hh[d:2 * d].T, w_hh[2 * d:3 * d].T]
        self.bx = [b_ih[0:d], b_ih[d:2 * d], b_ih[2 * d:3 * d]]
        self.bh = [b_hh[0:d], b_hh[d:2 * d], b_hh[2 * d:3 * d]]

    def __call__(self, x, h):
        # x, h: (B, d)
        xr = x @ self.wx[0] + self.bx[0]
        xz = x @ self.wx[1] + self.bx[1]
        xn = x @ self.wx[2] + self.bx[2]
        hr = h @ self.wh[0] + self.bh[0]
        hz = h @ self.wh[1] + self.bh[1]
        hn = h @ self.wh[2] + self.bh[2]
        r = mx.sigmoid(xr + hr)
        z = mx.sigmoid(xz + hz)
        n = mx.tanh(xn + r * hn)
        return (1 - z) * n + z * h


class MlpHead:
    def __init__(self, w1, b1, w2, b2):
        self.w1, self.b1, self.w2, self.b2 = w1, b1, w2, b2

    def __call__(self, z):
        return (nn_silu(z @ self.w1 + self.b1)) @ self.w2 + self.b2


def nn_silu(x):
    return x * mx.sigmoid(x)


class TurnTaker:
    def __init__(self, bundle_dir=None, weights=None):
        w = weights if weights is not None else load_turn_weights(bundle_dir)
        self.w = w
        self.cells = []
        for i in range(LAYERS):
            # torch Linear/GRU weights are (out, in) -> mlx rows stay as-is in our matmuls
            self.cells.append(GRUCell(w[f"core.weight_ih_l{i}"], w[f"core.weight_hh_l{i}"],
                                      w[f"core.bias_ih_l{i}"], w[f"core.bias_hh_l{i}"]))
        self.state_emb = w["state_emb.weight"]  # (5, 768)
        self.in_w = {n: (w[f"{n}.weight"], w[f"{n}.bias"]) for n in ("proj_user", "proj_agent", "proj_energy")}
        self.in_norm = (w["in_norm.weight"], w["in_norm.bias"])
        self.out_norm = (w["out_norm.weight"], w["out_norm.bias"])
        self.state_head = (w["state_head.weight"], w["state_head.bias"])
        self.hazard_head = (w["hazard_head.weight"], w["hazard_head.bias"])
        self.yield_head = MlpHead(w["yield_head.0.weight"], w["yield_head.0.bias"], w["yield_head.2.weight"], w["yield_head.2.bias"])
        self.bc_head = MlpHead(w["bc_head.0.weight"], w["bc_head.0.bias"], w["bc_head.2.weight"], w["bc_head.2.bias"])
        self.ep_head = MlpHead(w["ep_head.0.weight"], w["ep_head.0.bias"], w["ep_head.2.weight"], w["ep_head.2.bias"])

    def fuse(self, h_user, h_agent, act, prev_state):
        """(B, T, 1024) features, (B, T) normalised energy, (B, T) state ids -> (B, T, 768)."""
        pw, pb = self.in_w["proj_user"]
        aw, ab = self.in_w["proj_agent"]
        ew, eb = self.in_w["proj_energy"]
        z = (h_user @ pw + pb) + (h_agent @ aw + ab) + (act[:, :, None] @ ew + eb) + self.state_emb[prev_state]
        return mx.fast.layer_norm(z, self.in_norm[0], self.in_norm[1], 1e-5)

    def outputs(self, z):
        """(B, T, 768) -> (B, T, 8): state logits x4, then hazard, yield, bc, ep probabilities."""
        z = mx.fast.layer_norm(z, self.out_norm[0], self.out_norm[1], 1e-5)
        state = z @ self.state_head[0] + self.state_head[1]
        haz = mx.sigmoid(z @ self.hazard_head[0] + self.hazard_head[1])
        yie = mx.sigmoid(self.yield_head(z))
        bc = mx.sigmoid(self.bc_head(z))
        ep = mx.sigmoid(self.ep_head(z))
        return mx.concatenate([state, haz, yie, bc, ep], axis=-1)

    def step(self, h_user, h_agent, act, prev_state, state=None):
        """One frame (B, 1, 1024)/(B, 1)/(B, 1) from the carried GRU state (3, B, 768; None: fresh)
        -> (outputs (B, 1, 8), new state). This is the live path."""
        b = h_user.shape[0]
        if state is None:
            state = [mx.zeros((b, WIDTH)) for _ in range(LAYERS)]
        z = self.fuse(h_user, h_agent, act, prev_state)[:, 0]  # (B, 768)
        outs = []
        for i, cell in enumerate(self.cells):
            z = cell(z, state[i])
            outs.append(z)
        return self.outputs(z[:, None, :]), outs

    def forward(self, h_user, h_agent, act, prev_state, state=None):
        """T frames at once (batch path). Returns (outputs (B, T, 8), the new state)."""
        b, t, _ = h_user.shape
        if state is None:
            state = [mx.zeros((b, WIDTH)) for _ in range(LAYERS)]
        z = self.fuse(h_user, h_agent, act, prev_state)  # (B, T, 768)
        frames = []
        for k in range(t):
            zk = z[:, k]
            for i, cell in enumerate(self.cells):
                zk = cell(zk, state[i])
                state[i] = zk
            frames.append(zk)
        return self.outputs(mx.stack(frames, axis=1)), state
