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
// GPT-Live-1 DEPRECATED, and a known trap here: this text-only agent has no
// `live.json`, yet a *call* to it is still answered by openai/gpt-live-1
// because `eve-idfon-gpt` registers GptLiveHandler unconditionally — so the
// configured EVE_IDFON_MODEL only answers text, not calls. Live calls must move
// to the idfon-voice cascade (STT -> agent -> TTS); see
// docs/voice-side-channel.md and docs/live-voice.md.
const model = process.env.EVE_IDFON_MODEL || "openai/gpt-6-luna";

export default defineAgent({ model });
