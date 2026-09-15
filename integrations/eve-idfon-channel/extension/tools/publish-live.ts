import { defineTool } from "eve/tools";
import { z } from "zod";

import extension from "../extension";

export default defineTool({
  description: "Publish a local audio file as an idfon live stream ticket.",
  inputSchema: z.object({
    filePath: z.string().min(1),
    name: z.string().min(1).default("eve-live"),
    loop: z.boolean().default(false),
    relay: z.boolean().default(true),
  }),
  async execute(input, ctx) {
    const capabilities = ctx.session.auth.current?.attributes?.capabilities;
    if (!capabilities?.includes("live.audio.publish")) {
      throw new Error("idfon grant live.audio.publish is required");
    }
    const response = await fetch(`${extension.config.bridgeUrl}/live/publish`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-idfon-channel-secret": extension.config.secret,
      },
      body: JSON.stringify({
        path: input.filePath,
        name: input.name,
        loop_playback: input.loop,
        relay: input.relay,
      }),
    });
    if (!response.ok) {
      throw new Error(`idfon live publish returned HTTP ${response.status}`);
    }
    const result = (await response.json()) as { id: string; ticket: string };
    return {
      ...result,
      envelope: `IDFON-LIVE/1\naction=start\nticket=${result.ticket}`,
    };
  },
});
