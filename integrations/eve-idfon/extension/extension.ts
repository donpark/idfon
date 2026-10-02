import { defineExtension } from "eve/extension";
import { z } from "zod";

export default defineExtension({
  config: z.object({
    bridgeUrl: z.string().url().refine((value) => {
      const host = new URL(value).hostname;
      return host === "localhost" || host === "127.0.0.1" || host === "[::1]" || host === "::1";
    }, "bridgeUrl must point to the local managed bridge"),
    secret: z.string().min(1),
    // Agent-specific live-call metadata. Opaque to the platform: the holder's
    // registered live-call handler receives it verbatim (serve --live-config),
    // so no vendor/model value is baked into the channel or holder code.
    live: z.record(z.string(), z.unknown()).optional(),
  }),
});
