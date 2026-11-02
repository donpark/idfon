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
// Default set: the coreai fp32 encoder + the distilled StudentStep (the
// 5.3 MB step the loaders prefer) + their AOT containers (the gated default
// rung since 2026-10-27 — the fp16 pair drifts `p_end` near the endpoint gate
// and is opt-in, side-loaded), the teacher's TygerStep as the fallback step,
// the pre-27 coreml packages (TygerEncoder, TygerEncoderDyn, StudentStep,
// TygerStep), and the quantized MLX int8 chain (the pre-27 mac tier).
//
// AOT containers are packed as their whole `*.compiled.aimodel` directory: the
// per-arch `<name>.<arch>.aimodelc` child depends on the build host.
// `--only TIER` packs just that tier's default set (when other bundles are
// not on this machine). `--all` packs every bundle incl. fp32 fallbacks and
// bench variants (Q8/…).
// Bundle directories become relative `name` paths (so the store can recreate
// them); `asset` is the content hash in the default hash mode (or the flat
// download filename with `--asset name`, `/` -> `__`).
//
// A tier root that carries a student step must also carry `student.traits.json`
// beside it (`pnpm tyger build` stages it): the apps apply its `decider` to the
// rules seam, so a bundle without it silently falls back to the teacher-tuned
// thresholds.
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const args = process.argv.slice(2);
const arg = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};
// Content-addressed by default (durable files: url_base/<sha256>, immutable).
// `--asset name` emits the HF-style flat filenames for the mirror manifest.
const assetMode = arg("--asset") ?? "hash";
if (!["hash", "name"].includes(assetMode)) {
  console.error(`--asset must be hash|name, got ${assetMode}`);
  process.exit(2);
}
const urlBase = arg("--url-base") ?? (assetMode === "hash"
  ? "https://files.idfon.net/sha256/"
  : "https://huggingface.co/donpark/tyger-models/resolve/main");
// AOT containers carry one child per architecture (`.h17p.aimodelc` = A18 Pro /
// iPhone, `.h16s` = M4 / Mac). Tag entries so a device downloads only its own
// child; untagged entries are shared by every platform.
const iosArchs = (arg("--ios-arch") ?? "h17p").split(",");
const macArchs = (arg("--mac-arch") ?? "h16s").split(",");
const platformOf = (name) => {
  const m = name.match(/\.([a-z0-9]+)\.aimodelc\//);
  if (!m) return undefined;
  if (iosArchs.includes(m[1])) return "ios";
  if (macArchs.includes(m[1])) return "mac";
  return undefined; // unknown arch token: ship to everyone rather than drop it
};

const out = resolve(arg("--out") ?? "dist/tyger-models");
const all = args.includes("--all");
const root = resolve(arg("--root") ?? "bench-results");

const tiers = ["coreai", "coreml", "mlx", "onnx"];
let bundles = all
  ? tiers.flatMap((tier) => {
      try {
        return readdirSync(join(root, tier), { withFileTypes: true })
          .filter((e) => e.name !== ".DS_Store")
          .map((e) => `${tier}/${e.name}`);
      } catch {
        return []; // a tier this set does not carry (e.g. mlx on an app-only pack)
      }
    })
  : [
      "coreai/tyger_encoder_float32.aimodel",
      "coreai/student_step_float32.aimodel",
      "coreai/student.traits.json",
      "coreai/tyger_step_float32.aimodel",
      "coreai/tyger_encoder_float32.compiled.aimodel",
      "coreai/student_step_float32.compiled.aimodel",
      "coreai/tyger_step_float32.compiled.aimodel",
      "coreml/TygerEncoder.mlpackage",
      "coreml/TygerEncoderDyn.mlpackage",
      "coreml/StudentStep.mlpackage",
      "coreml/student.traits.json",
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
    const sha = createHash("sha256").update(buf).digest("hex");
    const asset = assetMode === "hash" ? sha : f.name.replaceAll("/", "__");
    writeFileSync(join(out, asset), buf);
    const platform = platformOf(f.name);
    files.push({ name: f.name, asset, sha256: sha, bytes: buf.length,
                 ...(platform ? { platform } : {}) });
    console.log(`  ${f.name}  ${(buf.length / 1e6).toFixed(0)} MB`);
  }
}

// The agent reads io.step.inputs.state to size the carried GRU state. Both
// steps are packed; the student is preferred, so its state is the contract.
const studentStep = files.some((f) => /student_step/i.test(f.name));
const manifest = {
  version: 1,
  packed_from: "bench-results",
  url_base: urlBase,
  io: {
    step: {
      inputs: { state: studentStep ? ["2", "1", "256"] : ["3", "1", "768"] },
      outputs: { state_out: studentStep ? ["2", "1", "256"] : ["3", "1", "768"] },
      contract: "act_db normalization ((db+50)/25 clamp) is baked into the graph",
    },
  },
  files,
};
writeFileSync(join(out, "manifest.json"), JSON.stringify(manifest, null, 2));
const total = files.reduce((n, f) => n + f.bytes, 0);
console.log(`packed tyger models -> ${out}`);
console.log(`  ${files.length} files, ${(total / 1e6).toFixed(0)} MB total, url_base=${urlBase ?? "(unset)"}`);
