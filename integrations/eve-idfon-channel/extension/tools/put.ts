import { defineTool } from "eve/tools";
import { z } from "zod";

import extension from "../extension";

export default defineTool({
  description: "Store base64 data in the authenticated idfon blob store for peer delivery.",
  inputSchema: z.object({
    bytesBase64: z.string().min(1),
  }),
  async execute(input) {
    const response = await fetch(`${extension.config.bridgeUrl}/blob/put`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-idfon-channel-secret": extension.config.secret,
      },
      body: JSON.stringify({ bytes_base64: input.bytesBase64 }),
    });
    if (!response.ok) {
      throw new Error(`idfon blob put returned HTTP ${response.status}`);
    }
    const result = (await response.json()) as { ticket: string; size_bytes: number };
    return {
      ...result,
      envelope: `IDFON-DATA/1\nticket=${result.ticket}\nsize=${result.size_bytes}`,
    };
  },
});
