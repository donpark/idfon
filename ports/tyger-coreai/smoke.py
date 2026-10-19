import asyncio
import numpy as np
import torch
import torch.nn as nn
import coreai.runtime as rt
from coreai_models.export.macos import export_to_coreai

class Tiny(nn.Module):
    def __init__(self):
        super().__init__()
        self.l = nn.Linear(8, 4)
    def forward(self, x):
        return torch.sigmoid(self.l(x))

m = Tiny().eval()
ex = {"x": torch.zeros(1, 8)}
prog = export_to_coreai(m, ex, dynamic_shapes=None, input_names=("x",), output_names=("y",), state_names=None)
pass
import shutil, pathlib
out = pathlib.Path("/tmp/tiny.aimodel")
shutil.rmtree(out, ignore_errors=True)
meta = rt.AIModelAssetMetadata()
meta.license = "openmdw-1.1"
from pathlib import Path
prog.save_asset(Path(out), meta)
print("saved", out, sum(f.stat().st_size for f in out.rglob('*') if f.is_file()), "bytes")

async def gate():
    m2 = await rt.AIModel.load(str(out), rt.SpecializationOptions.cpu_only())
    fn = m2.load_function("main")
    x = np.random.default_rng(0).normal(size=(1, 8)).astype(np.float32)
    res = await fn({"x": rt.NDArray(x)})
    got = res["y"].numpy()
    want = m(torch.from_numpy(x)).detach().numpy()
    print("engine vs torch max|Δ| =", float(np.abs(got - want).max()))
asyncio.run(gate())
