// Assemble the tyger decision-model bundle from bench-results/onnx into the
// model store (~/.idfon/models/tyger) — the "downloaded locally" form the eve TS
// agent loads (src/tyger/bundle.ts verifies it before use).
//
//   node pack-bundle.mjs [--out DIR] [--url-base URL]
//
// manifest.json pins every byte: version, source bundle revision, per-file
// sha256 + size, and the I/O contract the engine feeds. --url-base records
// where the files may be fetched from later; packing from local exports is the
// current source of truth.
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const args = process.argv.slice(2);
const argOf = (flag) => (args.includes(flag) ? args[args.indexOf(flag) + 1] : undefined);

const out = argOf("--out") ?? join(homedir(), ".idfon/models/tyger");
const urlBase = argOf("--url-base");
const src = join(root, "bench-results/onnx");

const FILES = [
  "TygerEncoderDyn.onnx",
  "TygerEncoderDyn.onnx.data",
  "TygerStep.onnx",
  "TygerStep.onnx.data",
];
for (const f of FILES) {
  if (!existsSync(join(src, f))) {
    console.error(`missing ${join(src, f)} — run ports/tyger-onnx/export_step.py [--dyn] first`);
    process.exit(2);
  }
}

mkdirSync(out, { recursive: true });
const files = FILES.map((name) => {
  const from = join(src, name);
  const to = join(out, name);
  copyFileSync(from, to);
  const buf = readFileSync(to);
  return {
    name,
    bytes: statSync(to).size,
    sha256: createHash("sha256").update(buf).digest("hex"),
  };
});

const manifest = {
  version: 1,
  created: new Date().toISOString(),
  source: {
    // the weights' origin (the HF bundle the exports were run against)
    bundle: "nineninesix/tyger",
    note: "regenerable via ports/tyger-onnx/export_step.py --dyn + --only step",
  },
  url_base: urlBase ?? null,
  files,
  io: {
    encoder: { inputs: { mel: ["1", "T", "128"], mask: ["1", "T"] }, outputs: { hidden: ["1", "T/8+1", "1024"] },
               contract: "mel lengths are 8k-7 (33, 41, ..., 801)" },
    step: { inputs: { hu: ["1", "1", "1024"], ha: ["1", "1", "1024"], act_db: ["1", "1"], prev_state: ["1", "1"], state: ["3", "1", "768"] },
            outputs: { out: ["1", "1", "8"], state_out: ["3", "1", "768"] },
            contract: "act_db normalization ((db+50)/25 clamp) is baked into the graph" },
  },
};
writeFileSync(join(out, "manifest.json"), JSON.stringify(manifest, null, 2));
console.log(`packed bundle v${manifest.version} -> ${out}`);
for (const f of files) console.log(`  ${f.name}  ${(f.bytes / 1e6).toFixed(0)} MB  ${f.sha256.slice(0, 12)}`);
