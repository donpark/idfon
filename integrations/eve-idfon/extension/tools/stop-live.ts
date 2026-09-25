import { defineTool } from "eve/tools";
import { z } from "zod";

import extension from "../extension";

export default defineTool({
  description: "Stop an idfon live stream publisher owned by this agent.",
  inputSchema: z.object({ id: z.string().min(1) }),
  async execute(input, ctx) {
    const capabilities = ctx.session.auth.current?.attributes?.capabilities;
    if (!capabilities?.includes("live.audio.publish")) {
      throw new Error("idfon grant live.audio.publish is required");
    }
    const response = await fetch(`${extension.config.bridgeUrl}/live/stop`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-idfon-channel-secret": extension.config.secret,
      },
      body: JSON.stringify({ id: input.id }),
    });
    if (!response.ok) {
      throw new Error(`idfon live stop returned HTTP ${response.status}`);
    }
    return response.json();
  },
});
