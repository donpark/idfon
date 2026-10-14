import { defineTool } from "eve/tools";
import { z } from "zod";
import { appendHistory, formatMatrix, runMatrix } from "../../lib/matrix.ts";

// The relay A/B matrix (docs/benchmarks.md): two short-lived daemons per relay
// config, real message round trips + blob transfer, honest forced-relay rows.

export default defineTool({
  description:
    "Run the relay latency/throughput matrix from this host: N0 public relays " +
    "vs the private relay (IDFON_RELAY_URLS default https://relay.idfon.net:8443), " +
    "each natural-path and forced-relay. Reports message round-trip percentiles " +
    "(send -> delivery ack, the per-turn transport cost) and blob Mbps. Takes " +
    "minutes; pass quick=true for a short run. Use when asked to compare relays " +
    "or measure how slow a network path is.",
  inputSchema: z.object({
    quick: z.boolean().optional().describe("Short run (3 samples, small blob)"),
    count: z.number().int().positive().max(100).optional().describe("Messages per config (default 10)"),
    relayUrl: z.string().optional().describe("Private relay URL to compare (default https://relay.idfon.net:8443)"),
  }),
  async execute({ quick, count, relayUrl }) {
    const rows = await runMatrix({
      relayUrl,
      count: count ?? (quick ? 3 : 10),
      blobBytes: quick ? 256 * 1024 : 1024 * 1024,
    });
    const resultsFile = appendHistory(rows);
    return { table: formatMatrix(rows), results_file: resultsFile, rows };
  },
});
