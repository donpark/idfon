import { defineAgent } from "eve";
import { mockModel } from "eve/evals";

// The bench peer is a measurement service, not a chat companion. With no
// EVE_IDFON_MODEL it runs a deterministic mock that answers BENCH-PING with an
// immediate BENCH-PONG — so timed request/reply pairs measure the transport
// and holder, never model latency. A real model (EVE_IDFON_MODEL) just runs
// the tools and formats the reports.
const selected = process.env.EVE_IDFON_MODEL;

export default defineAgent({
  model:
    selected ||
    mockModel(({ lastUserMessage }) => {
      const ping = /BENCH-PING\s+(\S+)/.exec(lastUserMessage);
      return ping ? `BENCH-PONG ${ping[1]}` : `bench peer ready: ${lastUserMessage}`;
    }),
  ...(selected ? {} : { modelContextWindowTokens: 4096 }),
});
