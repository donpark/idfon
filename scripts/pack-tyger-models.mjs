#!/usr/bin/env node
// Pack the tyger turn-model tiers for download-on-first-use delivery (the
// iOS/mac `TygerModelStore`): flattens `bench-results/{coreai,coreml}` bundles
// into one asset per file plus a `manifest.json` pinning every byte
// (sha256 + size) — the `ports/tyger-onnx/pack-bundle.mjs` manifest shape.
// Upload the output dir to the HuggingFace repo the app points at
// (`donpark/tyger-models`; the store's default manifest URL) — models ship
// via HuggingFace, never git — and point the app at the manifest URL
// (`IDFON_TYGER_MODELS` / `-tygermodels` overrides). `url_base` defaults to
// that repo's resolve base so a packed manifest is always fetchable (the
// store decodes it non-optional and fails the whole delivery on null).
//
//   node scripts/pack-tyger-models.mjs [--url-base URL] [--out DIR] [--all] [--only TIER]
//
// Default set: the coreai fp32 pair + their A18 (.h17p) AOT containers (the
// gated default rung since 2026-10-27 — the fp16 pair drifts `p_end` near the
// endpoint gate and is opt-in, side-loaded), the three coreml packages the
// pre-27 loader needs (TygerEncoder, TygerEncoderDyn, TygerStep), and the
// quantized MLX int8 chain (the pre-27 mac tier).
// `--only TIER` packs just that tier's default set (when other bundles are
// not on this machine). `--all` packs every bundle incl. fp32 fallbacks and
// bench variants (Q8/…).
// Bundle directories become relative `name` paths (so the store can recreate
// them); `asset` is the flat download filename (`/` -> `__`).
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const args = process.argv.slice(2);
const arg = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};
const urlBase = arg("--url-base") ?? "https://huggingface.co/donpark/tyger-models/resolve/main";
const out = resolve(arg("--out") ?? "dist/tyger-models");
const all = args.includes("--all");
const root = resolve("bench-results");

const tiers = ["coreai", "coreml", "mlx"];
let bundles = all
  ? tiers.flatMap((tier) =>
      readdirSync(join(root, tier), { withFileTypes: true })
        .filter((e) => e.name !== ".DS_Store")
        .map((e) => `${tier}/${e.name}`))
  : [
      "coreai/tyger_encoder_float32.aimodel",
      "coreai/tyger_step_float32.aimodel",
      "coreai/tyger_encoder_float32.compiled.aimodel/tyger_encoder_float32.h17p.aimodelc",
      "coreai/tyger_step_float32.compiled.aimodel/tyger_step_float32.h17p.aimodelc",
      "coreml/TygerEncoder.mlpackage",
      "coreml/TygerEncoderDyn.mlpackage",
      "coreml/TygerStep.mlpackage",
      "mlx/TygerChainInt8.safetensors",
    ];
const only = arg("--only");
if (only) bundles = bundles.filter((b) => b.startsWith(`${only}/`));

const walk = (dir, prefix, into) => {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === ".DS_Store") continue;
    const path = join(dir, entry.name);
    const name = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) walk(path, name, into);
    else into.push({ name, path });
  }
};

mkdirSync(out, { recursive: true });
const files = [];
for (const bundle of bundles) {
  const dir = join(root, bundle);
  if (!statSync(dir).isDirectory() && !statSync(dir).isFile()) {
    console.error(`missing bundle: ${dir}`);
    process.exit(1);
  }
  const picked = [];
  if (statSync(dir).isFile()) picked.push({ name: bundle, path: dir });
  else walk(dir, bundle, picked);
  for (const f of picked) {
    const buf = readFileSync(f.path);
    const asset = f.name.replaceAll("/", "__");
    writeFileSync(join(out, asset), buf);
    files.push({
      name: f.name,
      asset,
      sha256: createHash("sha256").update(buf).digest("hex"),
      bytes: buf.length,
    });
    console.log(`  ${f.name}  ${(buf.length / 1e6).toFixed(0)} MB`);
  }
}

const manifest = {
  version: 1,
  packed_from: "bench-results",
  url_base: urlBase,
  files,
};
writeFileSync(join(out, "manifest.json"), JSON.stringify(manifest, null, 2));
const total = files.reduce((n, f) => n + f.bytes, 0);
console.log(`packed tyger models -> ${out}`);
console.log(`  ${files.length} files, ${(total / 1e6).toFixed(0)} MB total, url_base=${urlBase ?? "(unset)"}`);
