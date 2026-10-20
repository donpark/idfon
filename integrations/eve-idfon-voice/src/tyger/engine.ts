// The tyger decision model's feed loop, in-process in the TS agent: growing
// 8 s windows -> mel -> encoder (user + agent, once per hop) -> 4x step per hop
// with the GRU state threaded. Port of the numeric chain in
// ports/tyger-swift/Sources/TygerVoice/TurnRuntime.swift (same semantics as
// ReferenceEars' drive: full-window re-encode, frames paired from the end).
// The rules half lives in ./rules.ts and consumes the 8-vectors.
//
// Sessions are duck-typed onnxruntime-node InferenceSessions (test mocks fit).
// Encoder: TygerEncoderDyn.onnx (mel (1,T,128) + mask (1,T) -> hidden (1,T',1024));
// step: TygerStep.onnx (hu/ha (1,1,1024) + act_db + prev_state + state -> 8 + state).

// require() not import: onnxruntime-node's native binding recognises only its own
// CJS Tensor class (the ESM entry hands out a different one -> "Tensor.location
// must be a string" at session.run).
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const ort = require("onnxruntime-node");

import { process as melProcess } from "./mel.ts";
import { frameEnergy, HOP_N, SR, WINDOW_S } from "./rules.ts";

export type OrtTensor = ort.Tensor;
export interface OrtSession {
  run(feeds: Record<string, OrtTensor>): Promise<Record<string, OrtTensor>>;
}

export class TygerEngine {
  state = new Float32Array(3 * 768);
  winU: number[] = [];
  winA: number[] = [];
  private encoder: OrtSession;
  private step: OrtSession;

  constructor(encoder: OrtSession, step: OrtSession) {
    this.encoder = encoder;
    this.step = step;
  }

  reset(): void {
    this.state.fill(0);
    this.winU = [];
    this.winA = [];
  }

  /// One 320 ms hop -> the new frames' 8-vectors (4 per full hop, fewer at the
  /// start). `onFrame` (optional) gets each frame's 8-vector and returns the
  /// NEXT prev_state — the oracle's interleave order (prev_state -> step ->
  /// on_frame). Without it prevState is constant (the parity drive's contract).
  async hop(
    userHop: ArrayLike<number>, agentHop: ArrayLike<number>, prevState: number,
    onFrame?: (out8: number[], frame: number, actDb: number, left: number) => number,
  ): Promise<number[][]> {
    const cap = WINDOW_S * SR;
    for (const [win, hop] of [[this.winU, userHop], [this.winA, agentHop]] as const) {
      for (let i = 0; i < hop.length; i++) win.push(hop[i]);
      if (win.length > cap) win.splice(0, win.length - cap);
    }
    const hu = await this.encode(this.winU);
    const ha = await this.encode(this.winA);
    const act = frameEnergy(this.winU);
    const n = Math.min(4, hu.length, ha.length, act.length);
    const out: number[][] = [];
    // frames pair from the END (the oracle's -k indexing), act may be one shorter
    let state = prevState;
    for (let k = n, frame = 0; k >= 1; k--, frame++) {
      const actDb = act[act.length - k];
      const o = await this.stepFrame(hu[hu.length - k], ha[ha.length - k], actDb, state);
      out.push(o);
      if (onFrame) state = onFrame(o, frame, actDb, n - 1 - frame);
    }
    return out;
  }

  /// mel window -> hidden rows (T' x 1024), with the extractor's attention mask
  /// (ReferenceEars passes it; without it the encoder attends to the masked
  /// zero row and drifts ~0.06 on p_end).
  private async encode(window: number[]): Promise<Float32Array[]> {
    const { features, validFrames } = melProcess(window);
    const T = features.length;
    const mel = new Float32Array(T * 128);
    for (let t = 0; t < T; t++) mel.set(features[t], t * 128);
    const mask = BigInt64Array.from({ length: T }, (_, t) => (t < validFrames ? 1n : 0n));
    const r = await this.encoder.run({
      mel: new ort.Tensor("float32", mel, [1, T, 128]),
      mask: new ort.Tensor("int64", mask, [1, T]),
    });
    const hidden = r.hidden;
    const rows = hidden.dims[1];
    return Array.from({ length: rows }, (_, i) => hidden.data.slice(i * 1024, (i + 1) * 1024) as Float32Array);
  }

  private async stepFrame(
    hu: Float32Array, ha: Float32Array, actDb: number, prevState: number,
  ): Promise<number[]> {
    const r = await this.step.run({
      hu: new ort.Tensor("float32", hu, [1, 1, 1024]),
      ha: new ort.Tensor("float32", ha, [1, 1, 1024]),
      act_db: new ort.Tensor("float32", Float32Array.from([actDb]), [1, 1]),
      prev_state: new ort.Tensor("int64", BigInt64Array.from([BigInt(prevState)]), [1, 1]),
      state: new ort.Tensor("float32", this.state, [3, 1, 768]),
    });
    // copy: ORT may recycle the output buffer on the next run() — aliasing it as
    // the next call's state feed silently threads the WRONG state
    this.state = Float32Array.from(r.state_out.data as Float32Array);
    return Array.from(r.out.data as Float32Array);
  }
}

export { HOP_N, SR };
