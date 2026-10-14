import { defineTool } from "eve/tools";
import { z } from "zod";
import { format, parse } from "../../lib/report.ts";

// Voice-turn stage report (docs/benchmarks.md): parses the `idfon-auto`
// markers VoiceAgentSession writes (turn=… asr_gap_ms=… listen_ms=… reply_ms=…
// speak_ms=… total_ms=…) into the per-stage table.

export default defineTool({
  description:
    "Turn a voice-call marker log into a per-turn stage report: turn-detection " +
    "gap, listening window, agent round trip (network + agent), TTS + playback, " +
    "and total — with p50/p95/max per stage. Pass the log inline (log_text) or " +
    "point at an attached file (path; defaults to the newest staged attachment). " +
    "Use when someone sends a call log or asks why a voice call felt slow.",
  inputSchema: z.object({
    log_text: z.string().optional().describe("Marker log contents (idfon-auto lines), when pasted in chat"),
    path: z.string().optional().describe("Sandbox path of an attached log file; omit to auto-detect the newest staged attachment"),
  }),
  async execute({ log_text, path }, ctx) {
    let text = log_text;
    if (!text) {
      const sandbox = await ctx.getSandbox();
      if (!path) {
        const found = await sandbox.run({
          command: "find /workspace/attachments -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -n 1",
        });
        path = found.stdout.trim();
      }
      if (!path) throw new Error("no log provided: pass log_text or attach a log file");
      const bytes = await sandbox.readBinaryFile({ path });
      if (!bytes || bytes.length < 1) throw new Error(`log not found at ${path}`);
      text = Buffer.from(bytes).toString("utf8");
    }
    return { report: format(parse(text)) };
  },
});
