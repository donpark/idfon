// The backchannel detector's feed loop, in-process: one 40 ms chunk (640
// samples @ 16 kHz) per run(), the causal caches + GRU state threaded between
// calls (each `*_out` fed back as its `*_input`). Outputs are per 20 ms frame
// (2 per chunk): intent softmax (continuer, assessment, negative, floor_take,
// non_speech), aux vad (user voice activity), aux vap (8 bins).
//
// Sessions are duck-typed onnxruntime-node InferenceSessions (test mocks fit).
// State shapes are verified against the graph's input metadata and model.json's
// state_names (loadBundle() refuses a divergent model.json).

// require() not import: onnxruntime-node's native binding recognises only its own
// CJS Tensor class (the ESM entry hands out a different one -> "Tensor.location
// must be a string" at session.run).
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const ort = require("onnxruntime-node");

export type OrtTensor = ort.Tensor;
export interface OrtSession {
  run(feeds: Record<string, OrtTensor>): Promise<Record<string, OrtTensor>>;
}

export const CHUNK_N = 640; // 40 ms at 16 kHz
export const FRAMES_PER_CHUNK = 2; // 20 ms frames

const STATE_SHAPES: Record<string, number[]> = {
  audio_cache: [1, 240],
  stem_cache: [1, 80, 4],
  block0_cache: [1, 128, 4],
  block1_cache: [1, 128, 8],
  block2_cache: [1, 128, 16],
  block3_cache: [1, 128, 32],
  gru_state: [2, 1, 192],
};

export interface FrameOut {
  intent: number[]; // softmax: continuer, assessment, negative, floor_take, non_speech
  vad: number; // user voice activity (auxiliary)
  vap: number[]; // user then bot activity at 0-0.2 / 0.2-0.6 / 0.6-1.2 / 1.2-2.0 s ahead
}

/// One bot_state frame row: [bot_speaking, since_onset/5, since_last_200ms_pause/5,
/// since_stop/5, filler_playing, 0, 0, 0], each seconds value clipped to [0, 5].
export function botStateRow(
  botSpeaking: boolean,
  sinceOnsetS: number,
  sinceLastPause200msS: number,
  sinceStopS: number,
  fillerPlaying = false,
): number[] {
  const clip = (s: number) => Math.min(Math.max(s, 0), 5) / 5;
  return [
    botSpeaking ? 1 : 0,
    clip(sinceOnsetS),
    clip(sinceLastPause200msS),
    clip(sinceStopS),
    fillerPlaying ? 1 : 0,
    0,
    0,
    0,
  ];
}

export class BcdEngine {
  private session: OrtSession;
  private state: Record<string, Float32Array>;

  constructor(session: OrtSession) {
    this.session = session;
    this.state = zeroState();
  }

  reset(): void {
    this.state = zeroState();
  }

  /// One 40 ms chunk -> the 2 new frames' outputs. `botState` is two
  /// botStateRow() rows (16 floats), one per 20 ms frame.
  async chunk(pcm: ArrayLike<number>, botState: ArrayLike<number>): Promise<FrameOut[]> {
    if (pcm.length !== CHUNK_N) {
      throw new Error(`bcd: chunk is ${pcm.length} samples, want ${CHUNK_N} (40 ms @ 16 kHz)`);
    }
    if (botState.length !== 16) {
      throw new Error(`bcd: bot_state is ${botState.length} floats, want 16 (two rows of 8)`);
    }
    const feeds: Record<string, OrtTensor> = {
      chunk: new ort.Tensor("float32", Float32Array.from(pcm), [1, CHUNK_N]),
      bot_state: new ort.Tensor("float32", Float32Array.from(botState), [1, 2, 8]),
    };
    for (const [name, shape] of Object.entries(STATE_SHAPES)) {
      feeds[name] = new ort.Tensor("float32", this.state[name], shape);
    }
    const r = await this.session.run(feeds);
    // copy: ORT may recycle the output buffer on the next run() — aliasing it as
    // the next call's state feed silently threads the WRONG state
    for (const name of Object.keys(STATE_SHAPES)) {
      this.state[name] = Float32Array.from(r[`${name}_out`].data as Float32Array);
    }
    const out: FrameOut[] = [];
    for (let f = 0; f < FRAMES_PER_CHUNK; f++) {
      out.push({
        intent: Array.from(r.intent.data.slice(f * 5, f * 5 + 5) as Float32Array),
        vad: (r.vad.data as Float32Array)[f],
        vap: Array.from(r.vap.data.slice(f * 8, f * 8 + 8) as Float32Array),
      });
    }
    return out;
  }
}

function zeroState(): Record<string, Float32Array> {
  const state: Record<string, Float32Array> = {};
  for (const [name, shape] of Object.entries(STATE_SHAPES)) {
    state[name] = new Float32Array(shape.reduce((a, b) => a * b, 1));
  }
  return state;
}
