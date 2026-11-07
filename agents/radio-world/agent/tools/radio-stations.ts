import { spawnSync } from "node:child_process";
import path from "node:path";

import { defineTool } from "eve/tools";
import { z } from "zod";

// Search the Radio Browser directory for live stations (docs/live-radio.md
// "Searching the directory"): `scripts/radio-stations-opml.mjs --json`,
// liveness-checked, so every result actually serves audio now. With `add`, the
// matches are appended to this contact's OPML menu (deduped by stream URL);
// call `radio-menu` afterwards so the caller can pick one and keep listening.
export default defineTool({
  description:
    "Search live internet radio stations (Radio Browser) when the caller " +
    "names a station, country, or genre the menu does not have. Results are " +
    "liveness-checked. Set `add` to append the matches to this contact's " +
    "station menu, then call `radio-menu` so the caller can play one.",
  inputSchema: z.object({
    query: z.string().optional().describe("Station name words, e.g. \"bbc radio\"."),
    country: z.string().optional().describe("Country name, e.g. \"Germany\"."),
    tag: z.string().optional().describe("Genre/tag, e.g. \"jazz\" or \"news\"."),
    limit: z.number().int().min(1).max(20).default(6),
    add: z
      .boolean()
      .default(false)
      .describe("Append the matches to the menu so a Play pick can start them."),
  }),
  async execute(input) {
    const root = process.env.IDFON_RADIO_ROOT ?? process.cwd();
    const menu = process.env.IDFON_RADIO_MENU ?? path.join(process.cwd(), "shows.opml");
    const args = [
      path.join(root, "scripts", "radio-stations-opml.mjs"),
      "--json",
      "--limit",
      String(input.limit),
    ];
    if (input.query) args.push("--query", input.query);
    if (input.country) args.push("--country", input.country);
    if (input.tag) args.push("--tag", input.tag);
    if (input.add) args.push("--append", menu);
    const result = spawnSync("node", args, { cwd: root, encoding: "utf8", timeout: 60_000 });
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
    if (result.error) return { ok: false, output: String(result.error) };
    return {
      ok: result.status === 0,
      output: output.length > 4000 ? `${output.slice(0, 4000)}…` : output,
    };
  },
});
