import { defineTool } from "eve/tools";
import { z } from "zod";

// The provisioner is the chokepoint: it owns the catalog and mints the
// subject-bound capability tickets. The agent only relays the caller's request
// and returns the invite envelope.
const provisionerUrl = process.env.DIRECTORY_PROVISIONER_URL ?? "http://127.0.0.1:18777";
const provisionerSecret = process.env.DIRECTORY_PROVISIONER_SECRET ?? "m2-test-secret";

const headers = {
  "content-type": "application/json",
  "x-idfon-provisioner-secret": provisionerSecret,
};

export default defineTool({
  description:
    "List the agent catalog, or issue a contact invite for a requested model. Omit `model` to list.",
  inputSchema: z.object({
    model: z
      .string()
      .min(1)
      .optional()
      .describe("Model or contact name the caller asked for; omit to list the catalog."),
  }),
  async execute(input, ctx) {
    if (!input.model) {
      const response = await fetch(`${provisionerUrl}/catalog`, { headers });
      if (!response.ok) throw new Error(`directory catalog returned HTTP ${response.status}`);
      return response.json();
    }

    // The channel authenticated the caller; the ticket must be bound to that
    // endpoint id or the holder rejects it.
    const peerId = ctx.session.auth.current?.attributes?.peer_id;
    if (!peerId) throw new Error("turn has no authenticated peer id");

    const response = await fetch(`${provisionerUrl}/invite`, {
      method: "POST",
      headers,
      body: JSON.stringify({ peer_id: peerId, model: input.model }),
    });
    const result = (await response.json()) as { error?: string };
    if (!response.ok) {
      throw new Error(result.error ?? `directory invite returned HTTP ${response.status}`);
    }
    return result;
  },
});
