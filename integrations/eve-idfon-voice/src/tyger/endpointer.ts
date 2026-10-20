// The tyger chain as a voice loop's ENDPOINTER — the decision model made
// authoritative: caller PCM in, turn decisions out ("endpoint" / "backchannel"
// / "barge"), replacing energy+quiet-tail heuristics. The wire is 24 kHz s16
// mono; the model's grid is 16 kHz (stream.ts resamples).
//
// Mode: "listen" while the loop listens (ENDPOINT/BACKCHANNEL), "speaking"
// while the agent's reply plays (BARGE). The agent channel should be the
// reply's PCM (the model's second ear); callers without a TTS seam pass
// silence — BARGE is unreliable then (the shadow's documented shortcut).

import { loadBundle } from "./bundle.ts";
import { TygerEngine } from "./engine.ts";
import { HOP_N, TurnSession, type Event } from "./rules.ts";
import { makeResampler, pcm16ToFloat } from "./stream.ts";

export type EndpointerEvent = "endpoint" | "backchannel" | "barge";

export class TygerEndpointer {
  private engine: TygerEngine;
  private sess: TurnSession;
  private resampleU: (x: ArrayLike<number>) => number[];
  private resampleA: (x: ArrayLike<number>) => number[];
  private pendingU: number[] = [];
  private pendingA: number[] = [];
  private mode = "listen";

  constructor(engine: TygerEngine, sess: TurnSession = new TurnSession()) {
    this.engine = engine;
    this.sess = sess;
    this.resampleU = makeResampler();
    this.resampleA = makeResampler();
  }

  /// "listen" (ENDPOINT/BACKCHANNEL) or "speaking" (BARGE).
  setMode(mode: "listen" | "speaking"): void {
    this.mode = mode;
  }

  reset(): void {
    this.engine.reset();
    this.pendingU = [];
    this.pendingA = [];
  }

  /// Feed one 24 kHz s16 mono chunk (user mic; agent = what the agent played,
  /// or zeros). Returns the decisions the chunk produced.
  async push(pcm: Uint8Array | Buffer, agentPcm?: Uint8Array | Buffer): Promise<EndpointerEvent[]> {
    this.pendingU.push(...this.resampleU(pcm16ToFloat(pcm)));
    this.pendingA.push(...this.resampleA(agentPcm ? pcm16ToFloat(agentPcm) : new Array(pcm.length / 2).fill(0)));
    const out: EndpointerEvent[] = [];
    while (this.pendingU.length >= HOP_N && this.pendingA.length >= HOP_N) {
      const hopU = this.pendingU.slice(0, HOP_N);
      const hopA = this.pendingA.slice(0, HOP_N);
      this.pendingU = this.pendingU.slice(HOP_N);
      this.pendingA = this.pendingA.slice(HOP_N);
      const reset = this.sess.begin_hop(hopU, hopA, this.mode);
      if (reset) this.engine.reset();
      this.sess.switch_mode(this.mode);
      await this.engine.hop(hopU, hopA, this.sess.prev_state, (out8, _i, actDb, left) => {
        const { events } = this.sess.on_frame(this.mode, out8, actDb, left);
        for (const e of events) {
          if (e.kind === "ENDPOINT") out.push("endpoint");
          else if (e.kind === "BACKCHANNEL") out.push("backchannel");
          else if (e.kind === "BARGE") out.push("barge");
        }
        return this.sess.prev_state;
      });
    }
    return out;
  }
}

/// Load the bundle and build the endpointer (throws if the bundle is missing
/// or corrupt — callers fail open to their energy fallback).
export async function createTygerEndpointer(): Promise<TygerEndpointer> {
  const bundle = loadBundle();
  const createRequire = (await import("node:module")).createRequire;
  const ort = createRequire(import.meta.url)("onnxruntime-node");
  const enc = await ort.InferenceSession.create(bundle.encoderPath);
  const step = await ort.InferenceSession.create(bundle.stepPath);
  return new TygerEndpointer(new TygerEngine(enc, step));
}

export type { Event };
