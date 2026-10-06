import { defineTool } from "eve/tools";
import { z } from "zod";

import {
  contextClear,
  contextCompact,
  contextDelete,
  contextEntries,
  contextGet,
  contextSet,
} from "../context-store";

// Edit the virtual context this host owns for the session
// (docs/session-context.md). Only the owning agent has this tool; other agents
// influence this context only through their responses. Bounded and compacted by
// the host.
export default defineTool({
  description:
    "Read or edit the virtual context you own for this session. Use it to " +
    "remember durable facts, decisions, and results across turns. " +
    "Actions: get/set/delete/list/compact/clear.",
  inputSchema: z.object({
    action: z.enum(["get", "set", "delete", "list", "compact", "clear"]),
    key: z.string().min(1).optional().describe("Entry key (get/set/delete)."),
    value: z.string().optional().describe("Entry value (set)."),
    keep: z.number().int().nonnegative().optional().describe("Entries to keep (compact)."),
  }),
  async execute({ action, key, value, keep }, ctx) {
    const sessionId = ctx.session.id;
    switch (action) {
      case "list":
        return { entries: contextEntries(sessionId) };
      case "get":
        if (!key) throw new Error("key is required for get");
        return { key, value: contextGet(sessionId, key) ?? null };
      case "set":
        if (!key) throw new Error("key is required for set");
        if (value === undefined) throw new Error("value is required for set");
        contextSet(sessionId, key, value);
        return { key, stored: true };
      case "delete":
        if (!key) throw new Error("key is required for delete");
        return { key, deleted: contextDelete(sessionId, key) };
      case "compact":
        return { dropped: contextCompact(sessionId, keep) };
      case "clear":
        contextClear(sessionId);
        return { cleared: true };
    }
  },
});
