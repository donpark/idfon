"""Training shards: the wire format between featurize.py (corpus -> shards) and
train.py (shards -> student). One .npz per corpus session, everything aligned on
the 80 ms frame grid the decision model runs on:

  hu          float32 [T, 1024]   the caller's L15 frames (the feature tap)
  ha          float32 [T, 1024]   the agent's own L15 frames (the second ear)
  energy      float32 [T]         frame energy in dB (normalized inside the model)
  prev_state  int64   [T]         the floor state the rules fed the teacher (0-3, 4=begin)
  teacher     float32 [T, 8]      the fp32 teacher's 8-vector per frame (state logits + probs)
  lab_<key>   int8    [T]         corpus labels, one array per anyreach key (vad/eot/hold/bot/bc x ch)
  ev_frames   int32   [K]         the teacher's events, frames 1-based (gate.py's reference)
  ev_kinds        str [K]         their kinds (ENDPOINT/BARGE/BACKCHANNEL/...)
  meta        JSON string         {"session_id", "frames"}

`bench-results/student-shards/` is the usual home (gitignored pipeline scratch).
"""
import glob
import json
import os

import numpy as np

FRAME_KEYS = ("hu", "ha", "energy", "prev_state", "teacher")


def save_shard(path, session_id, frames, labels, events=None):
    """frames: {key: array} for FRAME_KEYS; labels: {corpus_key: int array};
    events: (ev_frames, ev_kinds) or None."""
    for k in FRAME_KEYS:
        assert k in frames, f"shard frame missing: {k}"
    T = len(frames["energy"])
    for k, v in list(frames.items()) + list(labels.items()):
        assert len(v) == T, f"shard array {k} has {len(v)} frames, expected {T}"
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    arrays = dict(frames)
    arrays.update({f"lab_{k}": np.asarray(v, dtype=np.int8) for k, v in labels.items()})
    if events is not None:
        arrays["ev_frames"] = np.asarray(events[0], dtype=np.int32)
        arrays["ev_kinds"] = np.asarray(events[1])
    arrays["meta"] = np.array(json.dumps({"session_id": session_id, "frames": int(T)}))
    np.savez_compressed(path, **arrays)


def load_shard(path):
    """-> (frames, labels, events, meta). events is (ev_frames, ev_kinds) or None."""
    with np.load(path) as z:
        skip = set(FRAME_KEYS) | {"ev_frames", "ev_kinds", "meta"}
        frames = {k: z[k] for k in z.files if not k.startswith("lab_") and k not in skip}
        frames.update({k: z[k] for k in FRAME_KEYS})
        labels = {k[len("lab_"):]: z[k] for k in z.files if k.startswith("lab_")}
        events = ((z["ev_frames"], z["ev_kinds"]) if "ev_frames" in z.files else None)
        meta = json.loads(str(z["meta"]))
    frames["prev_state"] = frames["prev_state"].astype(np.int64)
    return frames, labels, events, meta


def pick_features(frames, layer=15):
    """The feature streams for one encoder layer: canonical hu/ha at L15 (the teacher's
    own inputs), hu_l{K}/ha_l{K} for any other layer featurize recorded."""
    layer = int(layer)
    if layer == 15:
        return frames["hu"], frames["ha"]
    ku, ka = f"hu_l{layer}", f"ha_l{layer}"
    if ku not in frames:
        raise KeyError(f"shard lacks layer {layer} features; featurize with --feature-layers {layer}")
    return frames[ku], frames[ka]


def iter_shards(dirpath):
    for path in sorted(glob.glob(os.path.join(dirpath, "*.npz"))):
        yield path, *load_shard(path)
