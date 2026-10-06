import { defineTool } from "eve/tools";
import { z } from "zod";

import { emitEnvelope } from "../outbox";

// Point at part of an artifact on the user's screen: open it and highlight the
// selection (image region, text range, element, or media time). The envelope
// rides the reply; the app presents the artifact and draws the highlight.
export default defineTool({
  description:
    "Point the user at part of an artifact: the app opens it and highlights the " +
    "selection. Use it instead of describing a location in words. The effect is " +
    "delivered automatically; do not restate the selection in your reply.",
  inputSchema: z.object({
    artifact_id: z.string().min(1).describe("Artifact id from its IDFON-ARTIFACT/1."),
    selector: z
      .record(z.string(), z.unknown())
      .describe("Selection: {type:'text',start,end} | {type:'region',x,y,w,h} | {type:'element',...} | {type:'time',start_ms,end_ms}."),
    blob_ticket: z.string().optional().describe("Artifact blob ticket, so the app can fetch it."),
    note: z.string().optional().describe("Short caption for the highlight."),
  }),
  async execute(input, ctx) {
    const body = {
      artifact_id: input.artifact_id,
      selector: input.selector,
      blob_ticket: input.blob_ticket ?? null,
      note: input.note ?? null,
    };
    emitEnvelope(ctx.session.id, `IDFON-POINT/1\n${JSON.stringify(body)}`);
    return { pointed: true };
  },
});
