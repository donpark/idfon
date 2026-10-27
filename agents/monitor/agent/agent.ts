import { defineAgent } from "eve";
import { mockModel } from "eve/evals";

// A plain monitor (issue #63): no model, no tools. IDFON-DIAG/1 reports are
// filed by the file-diag hook and get no reply — the app sender is
// fire-and-forget. Any other message gets one line pointing at the files.
export default defineAgent({
  model: mockModel(({ lastUserMessage }) =>
    lastUserMessage.startsWith("IDFON-DIAG/1\n")
      ? "<eve-empty-delivery/>"
      : "diag monitor: device reports are filed under ~/.idfon/monitor/diag/<device>.jsonl",
  ),
  // The mock has no gateway metadata; compaction needs a window size.
  modelContextWindowTokens: 4096,
});
