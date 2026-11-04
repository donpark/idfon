"""student.pt I/O for both decision models: the shipped `Student` and the epic-#132
`SharedLatentStudent` (one checkpoint per multi-tap training run, `tap` naming the
adapter the eval tools replay by default — the deploy target). `load()` returns a
model callable with Student's (hu, ha, act, prev, hidden) signature so gate.py /
harness.py / calibrate.py replay either model unchanged (TapBound binds the tap).

Checkpoint keys: state_dict, heads, width, layers, params — plus `adapters`
(constructed tap ids) and `tap` on shared checkpoints.
"""
import torch

from model import SharedLatentStudent, Student
from registry import adapter_by_id, by_id


class TapBound:
    """A SharedLatentStudent bound to one tap adapter, called like Student."""

    def __init__(self, model, tap):
        if tap not in {n for n in model.adapters}:
            raise KeyError(f"checkpoint has no adapter {tap!r} (has: {sorted(model.adapters)})")
        self._model, self.tap = model, tap

    def __call__(self, hu, ha, act, prev, hidden=None):
        return self._model(self.tap, hu, ha, act, prev, hidden)

    def eight_vector(self, outs):
        return self._model.eight_vector(outs)

    def __getattr__(self, name):  # heads_spec, eval(), state_dict(), window, ...
        return getattr(self._model, name)


def save(path, model, heads, tap=None):
    """Write student.pt from a Student or SharedLatentStudent (pass `tap` for the
    latter — the adapter the eval tools should replay by default)."""
    ckpt = {"state_dict": model.state_dict(), "heads": [h.id for h in heads],
            "width": model.width, "layers": model.layers,
            "params": sum(p.numel() for p in model.parameters())}
    if tap is not None:
        ckpt["adapters"] = list(model.adapters)
        ckpt["tap"] = tap
    torch.save(ckpt, path)
    return ckpt


def load(path, tap=None, device="cpu"):
    """student.pt -> (model, ckpt). Shared checkpoints come back TapBound (tap
    defaults to the checkpoint's recorded deploy tap)."""
    ckpt = torch.load(path, map_location=device)
    heads = [by_id(i) for i in ckpt["heads"]]
    if "adapters" in ckpt:
        core = SharedLatentStudent(heads, adapters=[adapter_by_id(i) for i in ckpt["adapters"]],
                                   width=ckpt["width"], layers=ckpt["layers"])
        core.load_state_dict(ckpt["state_dict"])
        core.to(device).eval()
        return TapBound(core, tap or ckpt.get("tap")), ckpt
    model = Student(heads, width=ckpt["width"], layers=ckpt["layers"])
    model.load_state_dict(ckpt["state_dict"])
    model.to(device).eval()
    return model, ckpt
