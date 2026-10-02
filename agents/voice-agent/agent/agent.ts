import { defineAgent } from "eve";

// Text-only agent for the A1 voice cascade (#17). The client app owns all
// audio (on-device STT/TTS); this agent only handles plain text turns, so it
// carries no GPT-Live session and no voice tools.
const model = process.env.EVE_IDFON_MODEL || "openai/gpt-6-luna";

export default defineAgent({ model });
