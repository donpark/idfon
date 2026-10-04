import { defineAgent } from "eve";

// Demo agent for the **cascade** voice front-end (STT -> agent -> TTS).
//
// The caller's app owns all audio: on-device STT turns speech into text, this
// agent answers as text, and on-device TTS speaks the reply (the A1 cascade,
// `VoiceAgentSession`). It carries no full-duplex session and no voice tools.
// Its counterpart is `agents/live-voice`, the native-duplex GPT-Live demo.
//
// EVE_IDFON_MODEL selects the text model per serve instance, so the same demo
// can serve several models as separate contacts.
const model = process.env.EVE_IDFON_MODEL || "openai/gpt-6-luna";

export default defineAgent({ model });
