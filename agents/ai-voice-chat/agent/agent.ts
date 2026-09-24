import { defineAgent } from "eve";

// EVE_IDFON_MODEL overrides the model (same env var the other agents use);
// default is the voice model this agent exists for.
const model = process.env.EVE_IDFON_MODEL || "openai/gpt-live-1";

export default defineAgent({
  model,
  // ponytail: gpt-live-1 has no gateway context-window metadata yet; pin it
  // (drop once the gateway catalog knows the model)
  modelContextWindowTokens: 128000,
});
