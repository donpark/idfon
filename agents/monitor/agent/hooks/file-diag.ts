import { defineHook } from "eve/hooks";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileReport } from "../lib/file-diag.ts";

// Where reports land (issue #63: ~/.idfon/<agent>/diag/). IDFON_DIAG_DIR
// overrides for EVE_INSTANCE homes and tests.
const dir =
  process.env.IDFON_DIAG_DIR ?? join(homedir(), ".idfon", "monitor", "diag");

export default defineHook({
  events: {
    async "delivery.consumed"(event) {
      // Fail-open: filing must never fail the turn.
      const text = event.data.parts
        .filter((part) => part.kind === "text")
        .map((part) => part.text)
        .join("\n");
      try {
        const filed = fileReport(dir, text);
        if (filed < 0) console.error("diag filing: bad IDFON-DIAG/1 report dropped");
      } catch (error) {
        console.error("diag filing failed", error);
      }
    },
  },
});
