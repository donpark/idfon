import { defineAgent } from "eve";

// Generic voice agent. It does not implement audio: the holder's live config
// selects a voice backend (see live.json / providers/*.json) that carries
// STT/TTS or a full-duplex model, and this agent answers the resulting text
// turn — or relays it to a wrapped agent. Reached by endpoint id + ticket.
const model = process.env.EVE_IDFON_MODEL || "openai/gpt-6-luna";

export default defineAgent({ model });
