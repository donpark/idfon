import { defineTool } from "eve/tools";
import { z } from "zod";

import { emitEnvelope } from "../outbox";

// Request a screenshot from the user's device (docs/voice-multimodal.md). The
// request is emitted to the outbox and rides the reply; the app captures its
// window and sends the image back as a follow-up turn, so the screenshot
// arrives as a new message rather than in this tool's result.
export default defineTool({
  description:
    "Request a screenshot of the user's screen (your app window). Use it when " +
    "seeing what the user sees would answer the question. The screenshot " +
    "arrives as a follow-up message; tell the user you are looking.",
  inputSchema: z.object({
    reason: z.string().optional().describe("Why the screenshot is needed (shown to the user)."),
  }),
  async execute({ reason }, ctx) {
    emitEnvelope(ctx.session.id, `IDFON-SCREENSHOT/1\n${JSON.stringify({ reason: reason ?? null })}`);
    return { requested: true };
  },
});
