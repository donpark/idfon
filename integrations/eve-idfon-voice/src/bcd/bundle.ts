// The backchannel-detector (bcd) model bundle: where the detector artifacts
// live on disk. Unlike the tyger bundle there is no packed manifest — the files
// come straight from the Hugging Face repo — so loadBundle() checks the files
// exist and that model.json matches the input contract the engine was built
// against (640-sample chunks, 2 frames per chunk, the 7 state names).
//
// Resolution: IDFON_BCD_BUNDLE (a bundle dir), else ~/.idfon/models/bcd.
// int8 is the default graph; fp32 is picked up if int8 is absent.

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface BcdModelConfig {
  chunk_samples: number;
  frames_per_chunk: number;
  state_names: string[];
  config: Record<string, unknown>;
}

export interface BcdBundle {
  dir: string;
  modelPath: string;
  modelConfig: BcdModelConfig;
}

const DOWNLOAD = `download it first:
  mkdir -p ~/.idfon/models/bcd && cd ~/.idfon/models/bcd
  curl -LO https://huggingface.co/pipecat-ai/backchannel-detector/resolve/main/backchannel-int8.onnx
  curl -LO https://huggingface.co/pipecat-ai/backchannel-detector/resolve/main/model.json`;

const STATE_NAMES = [
  "audio_cache",
  "stem_cache",
  "block0_cache",
  "block1_cache",
  "block2_cache",
  "block3_cache",
  "gru_state",
];

/// Load the bundle. Throws naming what is missing or divergent.
export function loadBundle(dir?: string): BcdBundle {
  const root = dir ?? process.env.IDFON_BCD_BUNDLE ?? join(homedir(), ".idfon/models/bcd");
  const modelPath = ["backchannel-int8.onnx", "backchannel-fp32.onnx"]
    .map((name) => join(root, name))
    .find((p) => existsSync(p));
  if (!modelPath) {
    throw new Error(`bcd bundle: no backchannel-int8.onnx (or fp32) in ${root} — ${DOWNLOAD}`);
  }
  const configPath = join(root, "model.json");
  if (!existsSync(configPath)) {
    throw new Error(`bcd bundle: no model.json in ${root} — ${DOWNLOAD}`);
  }
  const modelConfig: BcdModelConfig = JSON.parse(readFileSync(configPath, "utf8"));
  // the engine hardcodes this contract; refuse a model.json that diverges
  if (modelConfig.chunk_samples !== 640 || modelConfig.frames_per_chunk !== 2) {
    throw new Error(
      `bcd bundle: model.json chunk_samples ${modelConfig.chunk_samples} / frames_per_chunk ` +
        `${modelConfig.frames_per_chunk} != 640 / 2 — engine contract diverges, update src/bcd/engine.ts`,
    );
  }
  if (JSON.stringify(modelConfig.state_names) !== JSON.stringify(STATE_NAMES)) {
    throw new Error(
      `bcd bundle: model.json state_names ${JSON.stringify(modelConfig.state_names)} != ` +
        `${JSON.stringify(STATE_NAMES)} — engine contract diverges, update src/bcd/engine.ts`,
    );
  }
  return { dir: root, modelPath, modelConfig };
}
