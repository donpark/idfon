import { defineTool } from "eve/tools";
import { z } from "zod";

import { emitEnvelope } from "../outbox";

// Open an artifact on the user's screen (docs/voice-multimodal.md). Use it to
// bring a result the user should look at to the front; `point` additionally
// highlights a selection inside it.
export default defineTool({
  description:
    "Open an artifact on the user's screen. Use `point` instead when you also " +
    "want to highlight a specific part. The effect is delivered automatically; " +
    "do not restate it in your reply.",
  inputSchema: z.object({
    artifact_id: z.string().min(1).describe("Artifact id from its IDFON-ARTIFACT/1."),
    blob_ticket: z.string().optional().describe("Artifact blob ticket, so the app can fetch it."),
  }),
  async execute(input, ctx) {
    emitEnvelope(ctx.session.id, `IDFON-SHOW/1\n${JSON.stringify({
      artifact_id: input.artifact_id,
      blob_ticket: input.blob_ticket ?? null,
    })}`);
    return { shown: true };
  },
});
