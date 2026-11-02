// The tyger decision-model bundle: where the ONNX artifacts live on disk and
// that every byte is what was packed (ports/tyger-onnx/pack-bundle.mjs). The
// agent loads it through loadBundle() — the "downloaded locally, verified"
// form of tyger-s2s's bundle.fetch.
//
// Resolution: IDFON_TYGER_BUNDLE (a bundle dir), else ~/.idfon/models/tyger.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface BundleFile {
  name: string;
  bytes: number;
  sha256: string;
}
export interface BundleManifest {
  version: number;
  created: string;
  source: { bundle: string; note?: string };
  url_base: string | null;
  files: BundleFile[];
  io: Record<string, unknown>;
}
export interface TygerBundle {
  dir: string;
  manifest: BundleManifest;
  encoderPath: string;
  stepPath: string;
  /// The step's carried GRU state shape: teacher 3x768, student 2x256.
  stateShape: number[];
}

/// Step preference: the distilled student first (5.3 MB), then the teacher's
/// int8/fp32 steps. The encoder is shared by both.
const STEP_ORDER = ["StudentStep.onnx", "StudentStepInt8.onnx", "TygerStepInt8.onnx", "TygerStep.onnx"];

/// Load (and verify) the bundle. Throws naming the file on any mismatch.
export function loadBundle(dir?: string): TygerBundle {
  const root = dir ?? process.env.IDFON_TYGER_BUNDLE ?? join(homedir(), ".idfon/models/tyger");
  const manifest: BundleManifest = JSON.parse(readFileSync(join(root, "manifest.json"), "utf8"));
  for (const f of manifest.files) {
    const path = join(root, f.name);
    const bytes = statSync(path).size;
    if (bytes !== f.bytes) {
      throw new Error(`bundle corrupt: ${f.name} is ${bytes} bytes, manifest says ${f.bytes}`);
    }
    const sha = createHash("sha256").update(readFileSync(path)).digest("hex");
    if (sha !== f.sha256) {
      throw new Error(`bundle corrupt: ${f.name} sha256 ${sha.slice(0, 12)} != ${f.sha256.slice(0, 12)}`);
    }
  }
  const step = STEP_ORDER.map((name) => join(root, name)).find((path) => existsSync(path))
    ?? join(root, "TygerStep.onnx");
  // `io.step.inputs.state` is the packer's contract (`pack-bundle.mjs`). Older
  // bundles predate it — they only ever carried the teacher's 3x768 state.
  const io = manifest.io?.step as { inputs?: Record<string, string[]> } | undefined;
  const dims = io?.inputs?.state?.map(Number);
  const stateShape = dims?.length === 3 && dims.every(Number.isFinite) ? dims : [3, 1, 768];
  return {
    dir: root,
    manifest,
    encoderPath: join(root, "TygerEncoderDyn.onnx"),
    stepPath: step,
    stateShape,
  };
}
