import { defineTool } from "eve/tools";
import { z } from "zod";

import extension from "../extension";

// The holder signs its own card; this tool is how the agent asks it to. Each
// call mints a fresh, subject-bound capability ticket plus the holder's
// endpoint address, so the intro flow never reuses a card.
export default defineTool({
  description:
    "Issue a fresh contact card (endpoint address + capability ticket) for a peer id. " +
    "Use the requester's peer id so the ticket is bound to them.",
  inputSchema: z.object({
    subject: z.string().min(1).describe("Peer id the card is bound to (the requester)."),
    capabilities: z
      .array(z.string())
      .optional()
      .describe("Extra grants beyond message.receive (e.g. agent.receive)."),
  }),
  async execute(input) {
    const response = await fetch(`${extension.config.bridgeUrl}/card`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-idfon-channel-secret": extension.config.secret,
      },
      body: JSON.stringify({ subject: input.subject, capabilities: input.capabilities ?? [] }),
    });
    if (!response.ok) {
      throw new Error(`idfon card issue returned HTTP ${response.status}`);
    }
    const result = (await response.json()) as { ticket: unknown; endpoint_addr: unknown };
    return {
      endpoint_addr: result.endpoint_addr,
      ticket: result.ticket,
      envelope: `IDFON-CARD/1\nsubject=${input.subject}\ncontact=${JSON.stringify(result.endpoint_addr)}\nticket=${JSON.stringify(result.ticket)}`,
    };
  },
});
