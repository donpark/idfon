import { defineTool } from "eve/tools";
import { z } from "zod";

import { emitEnvelope } from "../outbox";

// Speak text aloud (docs/session-context.md, docs/voice-multimodal.md).
//
// The spoken form is sent as an `IDFON-SPEAK/1` envelope in the reply; the
// TTS-capable voice agent synthesizes it and forwards the audio to the user over
// the existing stream. Keep it short: long text and visuals belong in an
// artifact. Any speaking agent calls this; the voice agent answers it.
export default defineTool({
  description:
    "Speak a short response aloud. Put long text or visuals in an artifact " +
    "instead. The text is delivered to the voice agent automatically; do not " +
    "repeat it in your reply.",
  inputSchema: z.object({
    text: z.string().min(1).describe("The spoken response, short and conversational."),
    voice: z.string().optional().describe("Preferred voice id, if any."),
    language: z.string().optional().describe("BCP-47 language tag."),
    rate: z.number().optional().describe("Speaking rate multiplier."),
    priority: z.enum(["normal", "interrupt"]).optional().describe("Barge-in behavior."),
    correlation_id: z.string().optional().describe("Trace/correlation id for the utterance."),
  }),
  async execute(input, ctx) {
    const body = {
      text: input.text,
      voice: input.voice ?? null,
      language: input.language ?? null,
      rate: input.rate ?? null,
      priority: input.priority ?? "normal",
      correlation_id: input.correlation_id ?? null,
    };
    emitEnvelope(ctx.session.id, `IDFON-SPEAK/1\n${JSON.stringify(body)}`);
    return { spoken: true };
  },
});
