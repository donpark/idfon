#!/usr/bin/env node
// Runnable check for the radio-world agent's station menu (not part of the
// app targets): the OPML parse, the show= path building, and the json-render
// spec the radio-menu tool emits — through the tool's real `execute`, with
// the eve-idfon outbox drained like the channel does.
//
//   node scripts/radio-menu-check.mjs
//
// Prints "ALL OK" or the first failing assertion (exit 1).

import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const check = (cond, msg) => {
  if (!cond) {
    console.log("FAIL:", msg);
    process.exit(1);
  }
  console.log("ok:", msg);
};

const fixture = `<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head><title>Stations</title></head>
  <body>
    <outline text="World">
      <outline text="BBC" url="https://example.com/bbc.m3u8" />
      <outline text="Deutsche/Welle" url="https://example.com/dw.mp3" />
    </outline>
    <outline text="Talk" url="cache/talk.wav" />
  </body>
</opml>`;

const dir = await mkdtemp(path.join(tmpdir(), "radio-menu-check-"));
const menuPath = path.join(dir, "shows.opml");
await writeFile(menuPath, fixture);
process.env.IDFON_RADIO_MENU = menuPath;

const tool = (await import("../agents/radio-world/agent/tools/radio-menu.ts")).default;
// The same module instance the tool emits into (resolved through the agent's
// dependency, then real-pathed by node — one outbox, one Map).
const { drainEnvelopes } = await import(pathToFileURL(path.resolve(
  "agents/radio-world/node_modules/eve-idfon/dist/extension/outbox.mjs")));

const result = await tool.execute({ filter: undefined }, { session: { id: "check" } });
check(result.menu === 3 && result.of === 3, `three playable entries found: ${JSON.stringify(result)}`);

const envelopes = drainEnvelopes("check");
check(envelopes.length === 1, "exactly one envelope emitted");
check(envelopes[0].startsWith("IDFON-RENDER/1\n"), "the envelope is a render block");

const body = JSON.parse(envelopes[0].slice("IDFON-RENDER/1\n".length));
const elements = body.spec.elements;
check(body.spec.id === "radio-menu" && body.spec.root === "menu-card", "spec shape: id + root");

const items = elements["menu-list"].children.map((id) => elements[id].props);
check(items[0].value === "BBC" && items[0].payload === "World/BBC", `label vs payload: ${items[0].value} -> ${items[0].payload}`);
// A title carrying the path separator gets its index segment (the app's rule).
check(items[1].payload === "World/2", `separator in title → index segment: ${items[1].payload}`);
check(items[2].payload === "Talk", `top-level show path: ${items[2].payload}`);
check(elements["menu-list"].props.action === "idfon.call", "menu items dispatch idfon.call");
check(elements["menu-input"].props.action === "idfon.message.send" && elements["menu-input"].props.arg === "text", "input sends typed text");

const filtered = await tool.execute({ filter: "bbc" }, { session: { id: "check2" } });
const filteredBody = JSON.parse(drainEnvelopes("check2")[0].slice("IDFON-RENDER/1\n".length));
check(filtered.menu === 1 && filteredBody.spec.elements["menu-list"].children.length === 1, "filter narrows the menu");

console.log("ALL OK");
