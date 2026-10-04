import { defineTool } from "eve/tools";
import { z } from "zod";

import { opusToPcm24k, RATE } from "../audio";
import { createVoiceProvider, engineConfig } from "../providers";

// Self-answering, inbound half: turn the caller's voice memo into text for the
// agent to reason over. The agent's reply is spoken by `voice_speak`.
export function voiceTranscribeTool() {
  return defineTool({
    description:
      "Transcribe the caller's voice memo to text. Call it when a voice message " +
      "arrives, then answer normally; use `voice_speak` to reply in voice.",
    inputSchema: z.object({
      path: z
        .string()
        .min(1)
        .optional()
        .describe("Sandbox path of the staged recording; omit to auto-detect the newest"),
    }),
    async execute({ path }, ctx) {
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
      const engine = engineConfig();
      const stt = await createVoiceProvider(engine.stt, "stt");
      if (!stt.transcribe) throw new Error(`voice provider '${stt.name}' has no STT`);
      const transcript = (await stt.transcribe(await opusToPcm24k(opus), RATE)).trim();
      return { transcript };
    },
  });
}
