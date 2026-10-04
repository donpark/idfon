import { defineTool } from "eve/tools";
import { z } from "zod";

import { opusToPcm24k, RATE, wavWrap } from "../voice/audio";
import { putAudio, sendAwait } from "../voice/bridge";
import { createVoiceProvider, engineConfig } from "../voice/providers";

// Wrapping relay for a voice agent: the voice agent is the liaison between the
// caller and a wrapped agent.
//
//   caller voice memo
//     -> STT (a bundlable TS model or a cloud provider)
//     -> text to the wrapped agent (A2A send, await its reply)
//     -> TTS the wrapped agent's reply
//     -> reply audio blob + IDFON-DATA/1 envelope
//
// The caller hears the wrapped agent; the wrapped agent only ever sees text.
export default defineTool({
  description:
    "Relay a caller's voice memo to a wrapped agent and speak its reply back. " +
    "Transcribes the voice memo, forwards the text to the wrapped agent " +
    "(endpoint id + ticket), and returns the wrapped reply's audio envelope " +
    "(IDFON-DATA/1) plus both texts.",
  inputSchema: z.object({
    path: z
      .string()
      .min(1)
      .optional()
      .describe("Sandbox path of the staged voice recording; omit to auto-detect the newest"),
    wrappedPeerId: z.string().min(1).describe("Wrapped agent peer id"),
    wrappedEndpointId: z.string().min(1).describe("Wrapped agent endpoint id"),
    wrappedTicket: z
      .record(z.string(), z.unknown())
      .describe("Capability ticket authorizing the voice agent to message the wrapped agent"),
    timeoutMs: z.number().int().positive().optional().describe("Reply timeout in ms (default 60000)"),
  }),
  async execute({ path, wrappedPeerId, wrappedEndpointId, wrappedTicket, timeoutMs }, ctx) {
    const sandbox = await ctx.getSandbox();
    if (!path) {
      const found = await sandbox.run({
        command:
          "find /workspace/attachments -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -n 1",
      });
      path = found.stdout.trim();
      if (!path) throw new Error("no staged voice recording found");
    }
    const opus = await sandbox.readBinaryFile({ path });
    if (!opus || opus.length < 4) throw new Error(`recording not found at ${path}`);
    const pcm = await opusToPcm24k(opus);

    const engine = engineConfig();
    const stt = await createVoiceProvider(engine.stt, "stt");
    if (!stt.transcribe) throw new Error(`voice provider '${stt.name}' has no STT`);
    const transcript = (await stt.transcribe(pcm, RATE)).trim();
    if (!transcript) throw new Error("no speech transcribed from the recording");

    const replyTo = `voice-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    const reply = (
      await sendAwait(
        wrappedPeerId,
        wrappedEndpointId,
        wrappedTicket,
        transcript,
        replyTo,
        timeoutMs,
      )
    ).trim();
    if (!reply) throw new Error("wrapped agent returned no reply");

    const tts = await createVoiceProvider(engine.tts, "tts");
    if (!tts.synthesize) throw new Error(`voice provider '${tts.name}' has no TTS`);
    const wav = wavWrap(await tts.synthesize(reply));
    const blob = await putAudio(wav);

    return {
      transcript,
      reply,
      ticket: blob.ticket,
      size_bytes: blob.size_bytes,
      envelope: `IDFON-DATA/1\nticket=${blob.ticket}\nsize=${blob.size_bytes}`,
      reply_seconds: Math.round((wav.length / (RATE * 2)) * 10) / 10,
    };
  },
});
