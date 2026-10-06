import { defineTool } from "eve/tools";
import { z } from "zod";
import WebSocket from "ws";

import {
  opusToPcm24k as toPcm24k,
  putAudio,
  RATE,
  trimLeadingSilence,
  trimTrailingSilence,
  wavWrap,
} from "eve-idfon-voice";

// Live voice reply for one idfon voice memo.
//
// Responds to one idfon voice memo using the GPT-Live-1 model (one backend a
// voice agent can run; see docs/voice-agent.md). The server-side cascade uses
// the shared idfon-voice STT/TTS seam instead.
//
// Input: the staged recording path (IDFON-RECORDING/1 attachment, Ogg Opus
// 48k mono) the model saw in the turn. Output: spoken reply audio (WAV blob
// ticket via the idfon bridge) plus the spoken reply transcript.
//
// Provider values come from the channel's `live` metadata (the agent's
// extensions/idfon.ts), with env only as a manual override.
const DELEGATION_MODEL = "openai/gpt-6-luna";
// Bridge coordinates come from the channel extension's own config (the app
// wires extensions/idfon.ts, and e2e scripts patch that file); env only as a
// manual-override fallback.
import idfonExtension from "eve-idfon";

const live = () =>
  (idfonExtension.config?.live ?? {}) as {
    live_url?: string;
    model?: string;
    api_key_env?: string;
  };
const liveUrl = () => live().live_url || "wss://ai-gateway.vercel.sh/v1/live/sessions";
const liveModel = () => live().model || "openai/gpt-live-1";
const liveApiKey = () => {
  const name = live().api_key_env || "AI_GATEWAY_API_KEY";
  return process.env[name];
};
const MAX_INPUT_SECONDS = 30; // ponytail: single-shot memo cap from the gpt-live guide; longer memos need a real duplex session
const CHUNK_BYTES = 960; // 20 ms of s16le mono
const CHUNK_MS = 20;
const REPLY_QUIET_MS = 2000; // no output audio this long after audio began = reply finished
const REPLY_MAX_MS = 20_000; // hard reply window
const SESSION_TIMEOUT_MS = 60_000;

type LiveReply = { pcm: Buffer; transcript: string };

/**
 * Run delegated work on a gateway text model. Fire-and-forget from the
 * session's perspective: the result is appended to the commentary channel
 * and Live decides when/whether to speak it.
 */
async function handleDelegation(delegationId: string, context: () => string): Promise<string> {
  const { generateText } = await import("ai");
  const { text } = await generateText({
    model: DELEGATION_MODEL,
    prompt: [
      "You assist a live voice conversation. Answer the delegated request concisely " +
        "(the voice model will speak your answer aloud; plain text, no markdown).",
      `Conversation so far:\n${context()}`, `Delegation id: ${delegationId}`,
    ].join("\n\n"),
    maxOutputTokens: 300,
    abortSignal: AbortSignal.timeout(20_000),
  });
  return text;
}

/** One GPT-Live session: user PCM in, spoken reply PCM + transcript out. */
function runLiveSession(pcmIn: Buffer, guidance?: string): Promise<LiveReply> {
  const maxIn = RATE * 2 * MAX_INPUT_SECONDS;
  const input = pcmIn.length > maxIn ? pcmIn.subarray(0, maxIn) : pcmIn;
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(liveUrl(), {
      headers: { Authorization: `Bearer ${liveApiKey()}` },
      handshakeTimeout: 10_000,
    });

    const outChunks: Buffer[] = [];
    let transcript = "";
    let inputTranscript = "";
    let started = false;
    let closing = false;
    let gotAudio = false;
    let lastOutputAt = 0;
    let offset = 0;
    let finished = false;

    const send = (event: object) => ws.send(JSON.stringify(event));

    const finish = (result?: LiveReply, error?: Error) => {
      if (finished) return;
      finished = true;
      clearInterval(pacer);
      clearTimeout(watchdog);
      clearTimeout(closeTimeout);
      ws.terminate();
      if (error) reject(error);
      else resolve(result as LiveReply);
    };

    const close = () => {
      if (closing) return;
      closing = true;
      send({ type: "session.close" });
      closeTimeout = setTimeout(
        () => finish(undefined, new Error("gpt-live session close timed out")),
        5000,
      );
    };

    const startTs = Date.now();
    // 20 ms pacer: drains user audio, then silence, then closes the session
    // once the spoken reply has gone quiet.
    const pacer = setInterval(() => {
      if (!started || closing) return;
      if (offset >= input.length && gotAudio && lastOutputAt > 0 && Date.now() - lastOutputAt > REPLY_QUIET_MS) return close();
      if (Date.now() - startTs > REPLY_MAX_MS + MAX_INPUT_SECONDS * 1000) return close();
      const chunk = Buffer.alloc(CHUNK_BYTES);
      if (offset < input.length) {
        input.copy(chunk, 0, offset, Math.min(offset + CHUNK_BYTES, input.length));
        offset = Math.min(offset + CHUNK_BYTES, input.length);
      }
      send({ type: "session.input_audio.append", audio: chunk.toString("base64") });
    }, CHUNK_MS);

    const watchdog = setTimeout(
      () => finish(undefined, new Error("gpt-live session timed out")),
      SESSION_TIMEOUT_MS,
    );
    let closeTimeout: ReturnType<typeof setTimeout>;

    ws.on("open", () => {
      send({
        type: "session.start",
        session: {
          model: liveModel(),
          store: false,
          delegation: { type: "client" },
          audio: { format: { type: "audio/pcm", rate: RATE } },
          instructions: [
            "You are a voice assistant answering a voice message from one person.",
            "Reply with a single short spoken answer. Do not ask follow-up questions.",
            guidance ? `Guidance: ${guidance}` : "",
          ].filter(Boolean).join(" "),
        },
      });
    });

    ws.on("message", (data) => {
      let event: any;
      try {
        event = JSON.parse(String(data));
      } catch {
        return;
      }
      if (event.type === "session.started") {
        started = true;
      } else if (event.type === "session.output_audio.delta") {
        outChunks.push(Buffer.from(event.delta, "base64"));
        gotAudio = true;
        // ponytail: Live streams silence deltas continuously, so quiet-window
        // detection keys on audio energy, not delta recency — otherwise every
        // silence delta resets the timer and we record ~30s of trailing silence
        const chunk = outChunks[outChunks.length - 1];
        let loud = false;
        for (let i = 0; i + 1 < chunk.length; i += 2) {
          if (Math.abs(chunk.readInt16LE(i)) > 300) { loud = true; break; }
        }
        if (loud) lastOutputAt = Date.now();
      } else if (event.type === "session.output_transcript.delta") {
        transcript += event.delta;
      } else if (event.type === "session.input_transcript.delta") {
        inputTranscript += event.delta;
      } else if (event.type === "session.delegation.created") {
        // Delegated work runs on a gateway text model while the voice
        // conversation continues; the result comes back on the commentary
        // channel for Live to speak.
        handleDelegation(event.delegation.id, () => [
          inputTranscript ? `User said: ${inputTranscript}` : "(user speech not yet transcribed)",
          transcript ? `Reply so far: ${transcript}` : "",
        ].filter(Boolean).join("\n"))
          .then((text) => send({ type: "session.commentary.append", delegation_id: event.delegation.id, content: text }))
          .catch((error) => send({ type: "session.thinking.append", delegation_id: event.delegation.id, content: `Delegated work failed: ${error?.message ?? error}` }));
      } else if (event.type === "error") {
        finish(undefined, new Error(`gpt-live session error: ${event.error?.message ?? JSON.stringify(event.error)}`));
      } else if (event.type === "session.closed") {
        finish({
          pcm: trimTrailingSilence(trimLeadingSilence(Buffer.concat(outChunks))),
          transcript: transcript.trim(),
        });
      }
    });

    ws.on("error", (error) => finish(undefined, error instanceof Error ? error : new Error(String(error))));
    ws.on("close", () => {
      if (!finished) finish(undefined, new Error("gpt-live connection closed before session.closed"));
    });
  });
}

export default defineTool({
  description:
    "Turn the user's voice message into a spoken reply using the GPT-Live voice model. " +
    "Call it after a voice message arrives (omit the path to auto-detect the " +
    "staged recording, or pass optional extra " +
    "guidance for the spoken reply. Returns the spoken reply's transcript and an " +
    "IDFON-DATA/1 envelope for the reply audio; include the envelope in your reply text.",
  inputSchema: z.object({
    path: z.string().min(1).optional().describe("Sandbox path of the staged voice recording; omit to auto-detect the newest staged recording"),
    durationMs: z.number().int().positive().optional().describe("Recording duration in ms from the IDFON-RECORDING/1 envelope"),
    guidance: z.string().optional().describe("Optional steering for the spoken reply (tone, what to emphasize)"),
  }),
  async execute({ path, guidance }, ctx) {
    if (!liveApiKey()) throw new Error(`${live().api_key_env || "AI_GATEWAY_API_KEY"} is not set`);

    const sandbox = await ctx.getSandbox();
    // Models often can't relay the exact staged path (sha subdirectory), so
    // fall back to discovering the newest staged audio in /workspace/attachments.
    if (!path) {
      const found = await sandbox.run({
        // the channel stages attachments without extensions (file-<sha>), so
        // don't filter by name — take the newest file
        command: "find /workspace/attachments -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -n 1",
      });
      path = found.stdout.trim();
      if (!path) {
        const listing = await sandbox.run({ command: "ls -la /workspace/attachments 2>&1 | head -5" });
        throw new Error(`no staged recording found; attachments dir: ${listing.stdout || listing.stderr || "empty"}`);
      }
    }
    const opus = await sandbox.readBinaryFile({ path });
    if (!opus || opus.length < 4) throw new Error(`recording not found at ${path}`);
    if (Buffer.from(opus.slice(0, 4)).toString("latin1") !== "OggS") {
      throw new Error("not an Ogg Opus recording");
    }

    const pcmIn = await toPcm24k(opus);
    const reply = await runLiveSession(pcmIn, guidance);
    const wav = wavWrap(reply.pcm);

    const blob = await putAudio(wav);

    return {
      transcript: reply.transcript,
      ticket: blob.ticket,
      size_bytes: blob.size_bytes,
      envelope: `IDFON-DATA/1\nticket=${blob.ticket}\nsize=${blob.size_bytes}`,
      reply_seconds: Math.round((reply.pcm.length / (RATE * 2)) * 10) / 10,
    };
  },
});
