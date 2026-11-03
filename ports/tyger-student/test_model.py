import unittest

import torch

from model import SharedLatentStudent, Student
from registry import ADAPTERS, HEADS, SEAM_SIZE


class StudentLayoutTests(unittest.TestCase):
    def test_shipped_student_checkpoint_layout_is_unchanged(self):
        """student.pt and the exported tiers load by name — this layout is the
        shipped contract and must survive any refactor (epic #132 rule: no
        live-call behavior change outside the shadow/swap-over convention)."""
        keys = sorted(n for n, _ in Student(HEADS).named_parameters())
        self.assertEqual(keys, [
            "core.bias_hh_l0", "core.bias_hh_l1", "core.bias_ih_l0", "core.bias_ih_l1",
            "core.weight_hh_l0", "core.weight_hh_l1", "core.weight_ih_l0", "core.weight_ih_l1",
            "heads.backchannel.bias", "heads.backchannel.weight",
            "heads.barge.bias", "heads.barge.weight",
            "heads.endpoint.bias", "heads.endpoint.weight",
            "heads.hazard.bias", "heads.hazard.weight",
            "heads.hold.bias", "heads.hold.weight",
            "heads.state.bias", "heads.state.weight",
            "in_norm.bias", "in_norm.weight",
            "out_norm.bias", "out_norm.weight",
            "proj_agent.bias", "proj_agent.weight",
            "proj_energy.bias", "proj_energy.weight",
            "proj_user.bias", "proj_user.weight",
            "state_emb.weight",
        ])


class SharedLatentTests(unittest.TestCase):
    def test_every_registry_adapter_feeds_the_same_seam(self):
        """One forward per tap adapter -> the same 8-vector seam (epic #132 P1)."""
        m = SharedLatentStudent(HEADS)
        for a in ADAPTERS:
            hu = torch.randn(2, 5, a.width)
            outs, _ = m(a.id, hu, hu, torch.zeros(2, 5), torch.zeros(2, 5, dtype=torch.long))
            self.assertEqual(tuple(m.eight_vector(outs).shape), (2, 5, SEAM_SIZE), a.id)
            self.assertEqual(sorted(outs), sorted(h.id for h in HEADS), a.id)

    def test_adapters_are_per_tap_but_the_trunk_and_decoder_are_shared(self):
        """Adapters are per-tap; the latent GRU and heads are one shared set —
        the structural claim of the consistency-distillation plan (P3)."""
        m = SharedLatentStudent(HEADS)
        names = {n for n, _ in m.named_parameters()}
        tap_params = {n for n in names if n.startswith("adapters.")}
        self.assertEqual({n.split(".")[1] for n in tap_params}, {a.id for a in ADAPTERS})
        self.assertEqual({n.split(".")[0] for n in names - tap_params},
                         {"proj_energy", "state_emb", "in_norm", "out_norm", "core", "heads"})


if __name__ == "__main__":
    unittest.main()
