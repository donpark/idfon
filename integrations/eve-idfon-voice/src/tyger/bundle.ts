// The tyger decision-model bundle: where the ONNX artifacts live on disk and
// that every byte is what was packed (ports/tyger-onnx/pack-bundle.mjs). The
// agent loads it through loadBundle() — the "downloaded locally, verified"
// form of tyger-s2s's bundle.fetch.
//
// Resolution: IDFON_TYGER_BUNDLE (a bundle dir), else ~/.idfon/models/tyger.

import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
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
}

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
  return {
    dir: root,
    manifest,
    encoderPath: join(root, "TygerEncoderDyn.onnx"),
    stepPath: join(root, "TygerStep.onnx"),
  };
}
