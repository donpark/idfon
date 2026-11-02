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

// Step preference (bundle.ts picks the same order): the distilled student
// (5.3 MB fp32, ports/tyger-student/export.py) over the teacher's int8/fp32
// steps (23/56 MB). One step per bundle — the fallback above the seam is
// classic turn-taking, not the teacher.
const steps = [
  { name: "StudentStep.onnx", files: ["StudentStep.onnx"], state: ["2", "1", "256"],
    note: "distilled student (ports/tyger-student/export.py), fp32" },
  { name: "TygerStepInt8.onnx", files: ["TygerStepInt8.onnx", "TygerStepInt8.onnx.data"], state: ["3", "1", "768"],
    note: "step weights int8 group-16 (GRU+fuse, heads fp32, dequantized in-graph); regenerable via quantize_step.py + qstep-parity.mjs gate" },
  { name: "TygerStep.onnx", files: ["TygerStep.onnx", "TygerStep.onnx.data"], state: ["3", "1", "768"],
    note: "regenerable via ports/tyger-onnx/export_step.py --dyn + --only step" },
];
const step = steps.find((s) => existsSync(join(src, s.files[0])));
if (!step) {
  console.error(`no step in ${src} — run ports/tyger-onnx/export_step.py [--dyn] or the student export first`);
  process.exit(2);
}
// The student's calibrated rules knobs travel with the step (per-model
// thresholds; the agent applies them to its TurnSession).
const TRAITS = "student.traits.json";
const traits = join(root, "ports/tyger-student", TRAITS);
const FILES = [
  "TygerEncoderDyn.onnx",
  "TygerEncoderDyn.onnx.data",
  ...step.files,
  ...(step.name.startsWith("StudentStep") && existsSync(traits) ? [TRAITS] : []),
];
const source = (name) => (name === TRAITS ? traits : join(src, name));
for (const f of FILES) {
  if (!existsSync(source(f))) {
    console.error(`missing ${source(f)} — the ${step.name} pair is incomplete`);
    process.exit(2);
  }
}

mkdirSync(out, { recursive: true });
const files = FILES.map((name) => {
  const from = name === TRAITS ? traits : join(src, name);
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
    note: step.note,
  },
  url_base: urlBase ?? null,
  files,
  io: {
    encoder: { inputs: { mel: ["1", "T", "128"], mask: ["1", "T"] }, outputs: { hidden: ["1", "T/8+1", "1024"] },
               contract: "mel lengths are 8k-7 (33, 41, ..., 801)" },
    step: { inputs: { hu: ["1", "1", "1024"], ha: ["1", "1", "1024"], act_db: ["1", "1"], prev_state: ["1", "1"], state: step.state },
            outputs: { out: ["1", "1", "8"], state_out: step.state },
            contract: "act_db normalization ((db+50)/25 clamp) is baked into the graph" },
  },
};
writeFileSync(join(out, "manifest.json"), JSON.stringify(manifest, null, 2));
console.log(`packed bundle v${manifest.version} -> ${out}`);
for (const f of files) console.log(`  ${f.name}  ${(f.bytes / 1e6).toFixed(0)} MB  ${f.sha256.slice(0, 12)}`);
