import { defineAgent } from "eve";
import { mockModel } from "eve/evals";

// EVE_IDFON_MODEL selects a real AI Gateway model (e.g.
// "anthropic/claude-haiku-4.5") so the app is an actual agent to chat with.
// Unset keeps the deterministic mock the acceptance scripts assert on.
const selected = process.env.EVE_IDFON_MODEL;

export default defineAgent({
  model: selected || mockModel(({ lastUserMessage }) => `reply from eve: ${lastUserMessage}`),
  ...(selected ? {} : { modelContextWindowTokens: 4096 }),
});
