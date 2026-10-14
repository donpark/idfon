import { defineTool } from "eve/tools";
import { z } from "zod";
import { formatMatrix, runRtt } from "../../lib/matrix.ts";

// Timed message round trips through this host's daemon to one peer — the real
// send -> delivery-ack path a chat/voice turn rides on.

export default defineTool({
  description:
    "Measure message round-trip latency and blob-transfer throughput to one " +
    "peer through this host's daemon (send -> delivery ack, the per-turn " +
    "transport cost). The path taken (direct vs relay) follows this daemon's " +
    "and the peer's relay configuration. Use when asked how slow a specific " +
    "connection is.",
  inputSchema: z.object({
    peer: z.string().min(1).describe("Peer ref/name/id this daemon knows"),
    count: z.number().int().positive().max(100).optional().describe("Timed messages (default 10)"),
  }),
  async execute({ peer, count }) {
    const rows = await runRtt({ peer, count: count ?? 10 });
    return { table: formatMatrix(rows), rows };
  },
});
