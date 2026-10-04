import { defineAgent } from "eve";

// EVE_IDFON_MODEL overrides the model (same env var the other agents use).
// gpt-live-1 is not addressed here directly — the voice_reply tool owns the
// Live session; this model orchestrates turns and handles text.
//
// Demo voice agent for the GPT-Live-1 full-duplex model — one backend among
// several a voice agent can run (docs/voice-agent.md). The generic
// server-cascade capability is `agents/voice-agent`.
const model = process.env.EVE_IDFON_MODEL || "openai/gpt-6-luna";

export default defineAgent({ model });
