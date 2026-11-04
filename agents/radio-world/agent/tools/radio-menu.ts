import { readFile } from "node:fs/promises";

import { defineTool } from "eve/tools";
import { z } from "zod";

import { emitEnvelope } from "eve-idfon/outbox";

// The station menu as a json-render block (docs/live-radio.md "The radio-world
// agent", docs/reply-blocks.md). Deterministic on purpose: the OPML catalogue
// is data, and the caller picks from the menu — the model never restates it.
//
// A pick dispatches `idfon.call` with the entry's `show=` path under `value`
// (the app dials the call that plays it; hanging up stops it). The inline
// `Input` under the menu sends typed requests back as a plain message.

const MENU_PATH = process.env.IDFON_RADIO_MENU ?? "shows.opml";

interface Item {
  title: string;
  source?: string;
  children: Item[];
}

/** The `show=` selection segment for `entry` among `siblings`. */
function segment(entry: Item, siblings: Item[], index: number): string {
  return entry.title.includes("/") ? String(index + 1) : entry.title;
}

/** Outline-only OPML parse: nested `<outline>` tags, everything else ignored. */
function parseOPML(xml: string): Item[] {
  const root: Item[] = [];
  const stack: Item[] = [];
  const attr = (attrs: string, name: string): string | undefined => {
    const m = new RegExp(`(?:^|\\s)${name}="([^"]*)"`).exec(attrs);
    return m ? m[1].trim() : undefined;
  };
  for (const match of xml.matchAll(/<outline\b([^>]*?)(\/?)>|<\/outline>/g)) {
    if (match[0] === "</outline>") {
      const done = stack.pop();
      const parent = stack[stack.length - 1];
      if (done) (parent ? parent.children : root).push(done);
      continue;
    }
    const attrs = match[1] ?? "";
    const item: Item = {
      title: attr(attrs, "text") ?? attr(attrs, "title") ?? "",
      source: attr(attrs, "url") ?? attr(attrs, "xmlUrl"),
      children: [],
    };
    if (match[2] === "/") {
      const parent = stack[stack.length - 1];
      (parent ? parent.children : root).push(item);
    } else {
      stack.push(item);
    }
  }
  // A dangling open element closes at the end, like the app's parser.
  const done = stack.pop();
  if (done) root.push(done);
  return root;
}

/** Flatten playable entries to (label, show path) leaves, depth-first. */
function leaves(items: Item[], prefix: string, out: [string, string][]) {
  items.forEach((entry, index) => {
    const segmentName = segment(entry, items, index);
    const pathSoFar = prefix ? `${prefix}/${segmentName}` : segmentName;
    if (entry.source) out.push([entry.title, pathSoFar]);
    if (entry.children.length) leaves(entry.children, pathSoFar, out);
  });
}

export default defineTool({
  description:
    "Show the caller the station menu: the OPML catalogue of radio stations " +
    "as an interactive json-render menu (each entry is a Play choice) with an " +
    "inline input for typed requests. Call it whenever the conversation has no " +
    "menu on screen yet, or the caller asks for stations/the menu. Do not " +
    "restate the entries in your reply; say briefly what the menu shows.",
  inputSchema: z.object({
    filter: z
      .string()
      .optional()
      .describe("Only show entries whose title or section matches this (case-insensitive)."),
  }),
  async execute(input, ctx) {
    const items = parseOPML(await readFile(MENU_PATH, "utf8"));
    const entries: [string, string][] = [];
    leaves(items, "", entries);
    const filtered = input.filter
      ? entries.filter(([label, show]) =>
          `${label} ${show}`.toLowerCase().includes(input.filter!.toLowerCase()))
      : entries;
    // Protocol bound: 200 elements per spec (blocks.rs) — headroom for the
    // card and input; a truncated menu still beats a wall of prose.
    const shown = filtered.slice(0, 100);
    const ids = {
      card: "menu-card",
      menu: "menu-list",
      input: "menu-input",
    };
    const elements: Record<string, unknown> = {
      [ids.card]: {
        type: "Card",
        props: { title: input.filter ? `Stations matching “${input.filter}”` : "Radio stations" },
        children: shown.length ? [ids.menu, ids.input] : [ids.input],
      },
      [ids.menu]: {
        type: "Menu",
        props: { action: "idfon.call" },
        children: shown.map((_, i) => `menu-item-${i}`),
      },
      [ids.input]: {
        type: "Input",
        props: {
          placeholder: "play something else…",
          action: "idfon.message.send",
          arg: "text",
        },
      },
    };
    shown.forEach(([label, show], i) => {
      elements[`menu-item-${i}`] = {
        type: "Text",
        props: { value: label, payload: show },
      };
    });
    if (filtered.length > shown.length) {
      elements[`menu-item-${shown.length}`] = {
        type: "Text",
        props: { value: `… ${filtered.length - shown.length} more — type to filter` },
      };
    }
    const spec = { id: "radio-menu", root: ids.card, elements };
    emitEnvelope(ctx.session.id, `IDFON-RENDER/1\n${JSON.stringify({ title: "Stations", spec })}`);
    return { menu: shown.length, of: entries.length };
  },
});
