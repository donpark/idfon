import { defineExtension } from "eve/extension";
import { z } from "zod";

export default defineExtension({
  config: z.object({
    bridgeUrl: z.string().url(),
    secret: z.string().min(1),
  }),
});
