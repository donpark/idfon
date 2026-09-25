import { defineTool } from "eve/tools";
import { z } from "zod";

import extension from "../extension";

export default defineTool({
  description: "Send a text message to another authenticated idfon peer.",
  inputSchema: z.object({
    peerId: z.string().min(1),
    endpointId: z.string().min(1),
    capabilityTicket: z.record(z.string(), z.unknown()),
    text: z.string().min(1),
    conversation: z.string().optional(),
    a2aDepth: z.number().int().min(0).max(1).default(0),
  }),
  async execute(input) {
    const response = await fetch(`${extension.config.bridgeUrl}/send`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-idfon-channel-secret": extension.config.secret,
      },
      body: JSON.stringify({
        peer_id: input.peerId,
        endpoint_id: input.endpointId,
        capability_ticket: input.capabilityTicket,
        text: input.text,
        conversation: input.conversation,
        a2a_depth: input.a2aDepth,
      }),
    });
    if (!response.ok) {
      throw new Error(`idfon peer send returned HTTP ${response.status}`);
    }
    return response.json();
  },
});
