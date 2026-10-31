// Shadow backchannel detector: run the bcd decision chain alongside whatever
// currently decides turns, and log every event to a JSONL file — the tyger
// shadow.ts swap-over convention, observation only. No live path consumes this.
//
//   node src/bcd/shadow.ts [bridge-url] [decision-log.jsonl]
//
// Input: the bridge's GET /live/stream (caller audio, 24 kHz s16 mono frames)
// resampled to the model's 16 kHz grid, cut into 40 ms chunks. PHASE-1 SHORTCUT
// (same as src/tyger/shadow.ts): no TTS PCM seam exists at the bridge, so
// bot_state is the constant "bot long silent" row and backchannel-vs-floor is
// judged on user audio alone.
import { appendFileSync } from "node:fs";
import { get as httpGet } from "node:http";
import { get as httpsGet } from "node:https";
import { createRequire } from "node:module";

import { loadBundle } from "./bundle.ts";
import { BcdDecisions, type BcdDecision } from "./decisions.ts";
import { BcdEngine, botStateRow, CHUNK_N, type FrameOut } from "./engine.ts";
import { makeResampler, pcm16ToFloat } from "../tyger/stream.ts";

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
  const engine = new BcdEngine(await ort.InferenceSession.create(bundle.modelPath));
  const decisions = new BcdDecisions();
  // no TTS PCM seam: "bot long silent" (off >= 5 s), the honest no-signal row
  const botState = [...botStateRow(false, 5, 5, 5), ...botStateRow(false, 5, 5, 5)];
  const resample = makeResampler();
  let pending: number[] = [];
  let peerId = opts.peerId;
  let pump: Promise<void> = Promise.resolve(); // drives serialize on the stateful engine

  const log = (event: BcdDecision | { kind: string; [k: string]: unknown }) => {
    appendFileSync(opts.logPath, JSON.stringify({ ts: Date.now() / 1000, ...event }) + "\n");
  };

  const drive = async (chunk: number[]) => {
    const frames: FrameOut[] = await engine.chunk(chunk, botState);
    for (const f of frames) {
      const d = decisions.onFrame(f.intent, f.vad);
      if (d.kind !== "none") log(d);
    }
  };

  const onFrame = (data: Record<string, unknown>) => {
    if (data.type !== "audio.frame") return;
    if (peerId && data.peer_id !== peerId) return;
    peerId = data.peer_id;
    const raw = Buffer.from(String(data.pcm_base64), "base64");
    pending.push(...resample(pcm16ToFloat(new Uint8Array(raw))));
    pump = pump.then(async () => {
      while (pending.length >= CHUNK_N) {
        const chunk = pending.slice(0, CHUNK_N);
        pending = pending.slice(CHUNK_N);
        await drive(chunk);
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
  const logPath = process.argv[3] ?? "/tmp/bcd-shadow.jsonl";
  console.log(`bcd shadow: bridge ${bridge} -> ${logPath}`);
  await runShadow({ bridge, logPath });
}
