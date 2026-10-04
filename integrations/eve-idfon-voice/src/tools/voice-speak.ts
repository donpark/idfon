import { defineTool } from "eve/tools";
import { z } from "zod";

import { RATE, wavWrap } from "../audio";
import { putAudio } from "../bridge";
import { createVoiceProvider, engineConfig } from "../providers";

// Self-answering, outbound half: speak the agent's reply back to the caller as
// an idfon audio message. Pair with `voice_transcribe` on the inbound memo.
export function voiceSpeakTool() {
  return defineTool({
    description:
      "Speak text back to the caller as an idfon audio message. Returns an " +
      "IDFON-DATA/1 envelope; include it in your reply text so the caller hears it.",
    inputSchema: z.object({ text: z.string().min(1).describe("Text to speak") }),
    async execute({ text }) {
      const engine = engineConfig();
      const tts = await createVoiceProvider(engine.tts, "tts");
      if (!tts.synthesize) throw new Error(`voice provider '${tts.name}' has no TTS`);
      const wav = wavWrap(await tts.synthesize(text));
      const blob = await putAudio(wav);
      return {
        ticket: blob.ticket,
        size_bytes: blob.size_bytes,
        envelope: `IDFON-DATA/1\nticket=${blob.ticket}\nsize=${blob.size_bytes}`,
        seconds: Math.round((wav.length / (RATE * 2)) * 10) / 10,
      };
    },
  });
}
