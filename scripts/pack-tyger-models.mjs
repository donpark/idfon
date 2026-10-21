#!/usr/bin/env node
// Pack the tyger turn-model tiers for download-on-first-use delivery (the
// iOS/mac `TygerModelStore`): flattens `bench-results/{coreai,coreml}` bundles
// into one asset per file plus a `manifest.json` pinning every byte
// (sha256 + size) — the `ports/tyger-onnx/pack-bundle.mjs` manifest shape.
// Upload the output dir to any static host or a GitHub release and point the
// app at the manifest URL (`IDFON_TYGER_MODELS` / `-tygermodels` overrides).
//
//   node scripts/pack-tyger-models.mjs [--url-base URL] [--out DIR] [--all]
//
// Default set: the coreai fp16 pair (the iOS 27+ shipping tier) and the three
// coreml packages the pre-27 loader needs (TygerEncoder, TygerEncoderDyn,
// TygerStep). `--all` packs every bundle incl. fp32 fallbacks and bench
// variants. Bundle directories become relative `name` paths (so the store can
// recreate them); `asset` is the flat download filename (`/` -> `__`).
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const args = process.argv.slice(2);
const arg = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};
const urlBase = arg("--url-base") ?? null;
const out = resolve(arg("--out") ?? "dist/tyger-models");
const all = args.includes("--all");
const root = resolve("bench-results");

const bundles = all
  ? ["coreai", "coreml"].flatMap((tier) =>
      readdirSync(join(root, tier), { withFileTypes: true })
        .filter((e) => e.isDirectory())
        .map((e) => `${tier}/${e.name}`))
  : [
      "coreai/tyger_encoder_float16.aimodel",
      "coreai/tyger_step_float16.aimodel",
      "coreml/TygerEncoder.mlpackage",
      "coreml/TygerEncoderDyn.mlpackage",
      "coreml/TygerStep.mlpackage",
    ];

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
  if (!statSync(dir).isDirectory()) {
    console.error(`missing bundle: ${dir}`);
    process.exit(1);
  }
  const picked = [];
  walk(dir, bundle, picked);
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
