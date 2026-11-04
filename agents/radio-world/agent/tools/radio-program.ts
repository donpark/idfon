import { spawnSync } from "node:child_process";
import path from "node:path";

import { defineTool } from "eve/tools";
import { z } from "zod";

// The programming surface (scripts/radio-program.mjs) as an agent tool
// (docs/live-radio.md "The radio-world agent"): deterministic planning the
// caller would otherwise run as CLI scripts. One tool, CLI-shaped arguments —
// the commands are the planner's own vocabulary, not free-form shell.
export default defineTool({
  description:
    "Programme this station (what plays when). Commands: `fallback` (the clip " +
    "that loops when nothing is scheduled: a clip path or `--url <stream>`), " +
    "`submit` (air a clip in a slot: `<clip>|--url <u> --at HH:MM [--days mon,…] " +
    "[--note PITCH]`), `find` (search episodes for the brief), `compile` " +
    "(rewrite the schedule from submissions; `--fill` to generate a segment " +
    "when there is nothing to play), `brief` (gather sourced facts), `segment` " +
    "(speak words into a programme clip: `--say WORDS` or `--text FILE`). " +
    "`arguments` are the command's CLI arguments in order. All paths are " +
    "host filesystem paths.",
  inputSchema: z.object({
    command: z.enum(["fallback", "submit", "find", "compile", "brief", "segment"]),
    arguments: z
      .array(z.string())
      .default([])
      .describe("The command's CLI arguments, in order, e.g. [\"--url\", \"https://…\", \"--at\", \"07:00\"]."),
  }),
  async execute(input) {
    const root = process.env.IDFON_RADIO_ROOT ?? process.cwd();
    const instance = process.env.IDFON_RADIO_INSTANCE ?? "radio-world";
    const script = path.join(root, "scripts", "radio-program.mjs");
    // `--instance` is appended last so it always wins over a stray flag.
    const result = spawnSync(
      "node",
      [script, input.command, ...input.arguments, "--instance", instance],
      { cwd: root, encoding: "utf8", timeout: 120_000 },
    );
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
    if (result.error) return { ok: false, output: String(result.error) };
    return {
      ok: result.status === 0,
      output: output.length > 4000 ? `${output.slice(0, 4000)}…` : output,
    };
  },
});
