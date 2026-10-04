import { defineTool } from "eve/tools";
import { z } from "zod";

// The agency never mints the card itself. It asks the target agent (over
// idfon, A2A) to issue one, and relays the result back in this same turn so the
// caller — who only has the Agency contact — receives it.
const provisionerUrl = process.env.AGENCY_PROVISIONER_URL ?? "http://127.0.0.1:18777";
const provisionerSecret = process.env.AGENCY_PROVISIONER_SECRET ?? "m2-test-secret";
const bridgeUrl = process.env.IDFON_BRIDGE_URL ?? "";
const bridgeSecret = process.env.IDFON_BRIDGE_SECRET ?? "m2-test-secret";

const provisionerHeaders = {
  "content-type": "application/json",
  "x-idfon-provisioner-secret": provisionerSecret,
};

function field(text: string, key: string): string | undefined {
  const match = new RegExp(`(?:^|\\n)${key}=([^\\n]+)`).exec(text);
  return match?.[1];
}

export default defineTool({
  description:
    "List the agent catalog, or arrange an introduction so the caller can reach an agent. " +
    "Omit `model` to list.",
  inputSchema: z.object({
    model: z
      .string()
      .min(1)
      .optional()
      .describe("Model or contact name the caller asked for; omit to list the catalog."),
  }),
  async execute(input, ctx) {
    if (!input.model) {
      const response = await fetch(`${provisionerUrl}/catalog`, { headers: provisionerHeaders });
      if (!response.ok) throw new Error(`agency catalog returned HTTP ${response.status}`);
      return response.json();
    }

    const caller = ctx.session.auth.current?.attributes?.peer_id;
    if (!caller) throw new Error("turn has no authenticated peer id");
    if (!bridgeUrl) throw new Error("agency bridge is not configured");

    // Pre-pairing material so *we* (the agency) can send to the target; the
    // target's own holder signs the card the caller actually receives.
    const targetResponse = await fetch(`${provisionerUrl}/target`, {
      method: "POST",
      headers: provisionerHeaders,
      body: JSON.stringify({ model: input.model }),
    });
    const target = (await targetResponse.json()) as {
      error?: string;
      name?: string;
      model?: string;
      endpoint_addr?: { id?: string; endpoint_id?: string };
      capability_ticket?: unknown;
    };
    if (!targetResponse.ok) {
      // Unknown or not-currently-running model: hand the model the catalog so
      // it can offer alternatives. Throwing here (the previous behavior) left
      // the turn with a tool error and no spoken reply.
      if (targetResponse.status === 404) {
        const catalogResponse = await fetch(`${provisionerUrl}/catalog`, { headers: provisionerHeaders });
        const catalog = catalogResponse.ok ? await catalogResponse.json() : { contacts: [] };
        return { unavailable: input.model, catalog: catalog.contacts ?? [] };
      }
      throw new Error(target.error ?? `agency target returned HTTP ${targetResponse.status}`);
    }
    const endpointId = target.endpoint_addr?.id ?? target.endpoint_addr?.endpoint_id;
    if (!endpointId) throw new Error("registered target has no endpoint id");

    const replyTo = `intro-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    const request = [
      "IDFON-CARD-REQUEST/1",
      `peer=${caller}`,
      `model=${target.model ?? input.model}`,
      `reply_to=${replyTo}`,
    ].join("\n");

    const sendResponse = await fetch(`${bridgeUrl}/send`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-idfon-channel-secret": bridgeSecret },
      body: JSON.stringify({
        peer_id: endpointId,
        endpoint_id: endpointId,
        capability_ticket: target.capability_ticket,
        text: request,
        a2a_depth: 1,
        await_reply: true,
        reply_to: replyTo,
        reply_timeout_ms: 60_000,
      }),
    });
    const sent = (await sendResponse.json()) as { error?: string; reply?: { text?: string } };
    if (!sendResponse.ok) throw new Error(sent.error ?? `agency intro send returned HTTP ${sendResponse.status}`);

    const card = sent.reply?.text ?? "";
    if (!card.startsWith("IDFON-CARD/1")) {
      throw new Error(`target did not return a card (got: ${card.slice(0, 60) || "empty"})`);
    }
    const contact = field(card, "contact");
    const ticket = field(card, "ticket");
    if (!contact || !ticket) throw new Error("card is missing contact or ticket");

    const expiresAt = Math.floor(Date.now() / 1000) + 3600;
    const envelope = [
      "IDFON-INVITE/1",
      `name=${target.name ?? input.model}`,
      `model=${target.model ?? input.model}`,
      `expires_at=${expiresAt}`,
      `contact=${contact}`,
      `ticket=${ticket}`,
    ].join("\n");

    return { name: target.name ?? input.model, model: target.model ?? input.model, envelope };
  },
});
