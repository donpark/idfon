import { defineAgent } from "eve";

// EVE_IDFON_MODEL overrides the model (same env var the other agents use).
// gpt-live-1 is not addressed here directly — the voice_reply tool owns the
// Live session; this model orchestrates turns and handles text.
const model = process.env.EVE_IDFON_MODEL || "openai/gpt-6-luna";

export default defineAgent({ model });
