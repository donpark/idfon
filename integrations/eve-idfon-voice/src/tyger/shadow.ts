// Shadow turn-taker: run the tyger decision chain alongside whatever currently
// decides turns, and log every decision to a JSONL file — the swap-over
// convention (collect the diff, then make it authoritative).
//
//   node src/tyger/shadow.ts [bridge-url] [decision-log.jsonl]
//
// Input: the bridge's GET /live/stream (caller audio, 24 kHz s16 mono frames)
// resampled to the model's 16 kHz grid. PHASE-1 SHORTCUT (same as the mac app's
// TurnShadow): the agent channel is silence — no TTS PCM seam exists at the
// bridge — so BARGE events are unreliable and the 8 s window misses the agent's
// preceding utterance. Mode is `listen` (ENDPOINT/BACKCHANNEL are the Segmenter
// swap target).
import { appendFileSync } from "node:fs";
import { get as httpGet } from "node:http";
import { get as httpsGet } from "node:https";
import { createRequire } from "node:module";

import { loadBundle } from "./bundle.ts";
import { TygerEngine } from "./engine.ts";
import { HOP_N, TurnSession, type Event } from "./rules.ts";
import { makeResampler, pcm16ToFloat } from "./stream.ts";

export { makeResampler, pcm16ToFloat };

const require = createRequire(import.meta.url);
const ort = require("onnxruntime-node");

export interface ShadowOptions {
  bridge: string;
  logPath: string;
  peerId?: string;
}

/// Stream a live call through the decision chain; resolves when the stream ends.
export async function runShadow(opts: ShadowOptions): Promise<void> {
  const bundle = loadBundle();
  const enc = await ort.InferenceSession.create(bundle.encoderPath);
  const step = await ort.InferenceSession.create(bundle.stepPath);
  const engine = new TygerEngine(enc, step);
  const sess = new TurnSession();
  const resample = makeResampler();
  let pending: number[] = [];
  let frame = 0;
  let peerId = opts.peerId;
  let pump: Promise<void> = Promise.resolve(); // drives serialize on the stateful engine

  const log = (event: Event | { kind: string; [k: string]: unknown }) => {
    appendFileSync(opts.logPath, JSON.stringify({ ts: Date.now() / 1000, frame, ...event }) + "\n");
  };

  const drive = async (userHop: number[]) => {
    const agentHop = new Array(HOP_N).fill(0); // shortcut: no TTS PCM seam
    const reset = sess.begin_hop(userHop, agentHop, "listen");
    if (reset) engine.reset();
    sess.switch_mode("listen");
    await engine.hop(userHop, agentHop, sess.prev_state, (out8, _i, actDb, left) => {
      const { events } = sess.on_frame("listen", out8, actDb, left);
      for (const e of events) {
        if (e.kind !== "FRAME") log(e);
      }
      frame++;
      return sess.prev_state;
    });
  };

  const onFrame = (data: Record<string, unknown>) => {
    if (data.type !== "audio.frame") return;
    if (peerId && data.peer_id !== peerId) return;
    peerId = data.peer_id;
    const raw = Buffer.from(String(data.pcm_base64), "base64");
    pending.push(...resample(pcm16ToFloat(new Uint8Array(raw))));
    pump = pump.then(async () => {
      while (pending.length >= HOP_N) {
        const hop = pending.slice(0, HOP_N);
        pending = pending.slice(HOP_N);
        await drive(hop);
      }
    });
  };

  // node:http, not fetch: undici's 300 s body timeout kills a silent SSE stream
  // between calls. Reconnect forever — the bridge restarts with the agent.
  const get = opts.bridge.startsWith("https") ? httpsGet : httpGet;
  for (;;) {
    await new Promise<void>((resolve) => {
      const req = get(`${opts.bridge}/live/stream`, { headers: { accept: "text/event-stream" } }, (res) => {
        let buffer = "";
        res.setEncoding("utf8");
        res.on("data", (chunk: string) => {
          buffer += chunk;
          let index;
          while ((index = buffer.indexOf("\n\n")) >= 0) {
            const event = buffer.slice(0, index);
            buffer = buffer.slice(index + 2);
            const line = event.split("\n").find((l) => l.startsWith("data: "));
            if (!line) continue;
            try {
              onFrame(JSON.parse(line.slice(6)));
            } catch {
              /* keep reading */
            }
          }
        });
        res.on("end", resolve);
        res.on("error", () => resolve());
      });
      req.on("error", () => resolve());
    });
    await new Promise((r) => setTimeout(r, 1000));
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const bridge = process.argv[2] ?? process.env.IDFON_BRIDGE_URL ?? "http://127.0.0.1:59861";
  const logPath = process.argv[3] ?? "/tmp/tyger-shadow.jsonl";
  console.log(`shadow: bridge ${bridge} -> ${logPath}`);
  await runShadow({ bridge, logPath });
}
