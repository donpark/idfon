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

import type { Thresholds } from "./rules.ts";

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
  /// The student's calibrated rules knobs (`student.traits.json`) — thresholds
  /// are per-model and do not transfer from the teacher. null: bundle defaults.
  traits: Partial<Thresholds> | null;
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
  // The student ships its own calibrated knobs beside the step (the teacher's
  // optimum costs it ~9 pts of event agreement on live audio). A bundle packed
  // before 2026-11-01 has none: fall back to the rules defaults.
  let traits: Partial<Thresholds> | null = null;
  const traitsPath = join(root, "student.traits.json");
  if (step.includes("StudentStep") && existsSync(traitsPath)) {
    const decider = (JSON.parse(readFileSync(traitsPath, "utf8")) as { decider?: Partial<Thresholds> })
      .decider;
    if (decider) traits = decider;
  }
  return {
    dir: root,
    manifest,
    encoderPath: join(root, "TygerEncoderDyn.onnx"),
    stepPath: step,
    stateShape,
    traits,
  };
}
