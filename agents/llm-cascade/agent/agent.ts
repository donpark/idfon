import { defineAgent } from "eve";

// Text-only agent for the A1 voice cascade (#17). The client app owns all
// audio (on-device STT/TTS); this agent only handles plain text turns, so it
// carries no GPT-Live session and no voice tools.
//
// EVE_IDFON_MODEL selects the model per serve instance, so the same agent can
// be run several times (each with its own identity/ticket) and added as
// separate contacts — e.g. one serving openai/gpt-6.1-sol, another a
// different model.
//
// Text-only by default. A holder routes a live call to a voice backend only
// when its ticket advertises native-duplex/server-cascade, so a text agent with
// no live.json is driven by the caller's on-device cascade rather than any
// full-duplex model. To give it a voice, point it at a voice agent
// (docs/voice-agent.md).
const model = process.env.EVE_IDFON_MODEL || "openai/gpt-6-luna";

export default defineAgent({ model });
