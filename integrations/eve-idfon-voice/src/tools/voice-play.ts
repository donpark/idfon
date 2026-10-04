import { defineTool } from "eve/tools";
import { z } from "zod";

import { RATE } from "../audio";
import { playAudio } from "../bridge";
import { createVoiceProvider, engineConfig } from "../providers";

// Outbound half of a TS-terminated live call: synthesize and push the audio to
// the caller's return leg (the holder publishes it on the MoQ session).
export function voicePlayTool() {
  return defineTool({
    description:
      "Speak text on the active live call's return leg (server-side TTS). Use " +
      "this to answer during a call when the holder relays caller audio to you.",
    inputSchema: z.object({ text: z.string().min(1).describe("What to say") }),
    async execute({ text }, ctx) {
      const peerId = (
        ctx.session.auth.current?.attributes as { peer_id?: string } | undefined
      )?.peer_id;
      if (!peerId) throw new Error("no authenticated peer id on this turn");
      const engine = engineConfig();
      const tts = await createVoiceProvider(engine.tts, "tts");
      if (!tts.synthesize) throw new Error(`voice provider '${tts.name}' has no TTS`);
      const pcm = await tts.synthesize(text);
      const accepted = await playAudio(peerId, pcm);
      return {
        accepted,
        seconds: Math.round((pcm.length / (RATE * 2)) * 10) / 10,
      };
    },
  });
}
