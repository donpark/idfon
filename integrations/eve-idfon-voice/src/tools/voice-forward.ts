import { defineTool } from "eve/tools";
import { z } from "zod";

import { forwardToWrapped, wrapTarget } from "../wrap";

// Text forward for a wrapping voice agent. Use this when the caller's words
// are already text — e.g. a live call where the cascade transcribed for us —
// and this agent is the voice for a wrapped agent.
export function voiceForwardTool() {
  return defineTool({
    description:
      "Forward the caller's message to the wrapped agent and return its reply " +
      "text. Use this when wrapping another agent; then say the returned reply " +
      "(the caller hears it).",
    inputSchema: z.object({
      text: z.string().min(1).describe("What the caller said, as text"),
      wrappedPeerId: z.string().optional(),
      wrappedEndpointId: z.string().optional(),
      wrappedTicket: z.record(z.string(), z.unknown()).optional(),
      timeoutMs: z.number().int().positive().optional(),
    }),
    async execute({ text, wrappedPeerId, wrappedEndpointId, wrappedTicket, timeoutMs }) {
      const target = wrapTarget({
        peerId: wrappedPeerId,
        endpointId: wrappedEndpointId,
        ticket: wrappedTicket,
      });
      const reply = await forwardToWrapped(text, target, timeoutMs);
      if (!reply) throw new Error("wrapped agent returned no reply");
      return { reply };
    },
  });
}
