import { defineAgent } from "eve";

// EVE_IDFON_MODEL overrides the model (same env var the other agents use).
// gpt-live-1 is not addressed here directly — the voice_reply tool owns the
// Live session; this model orchestrates turns and handles text.
//
// GPT-Live-1 DEPRECATED (migration target). This demo agent is the only
// sanctioned GPT-Live user; do not clone it for other models. Live calls move
// to the idfon-voice cascade (STT -> agent -> TTS) — see
// docs/voice-side-channel.md and docs/live-voice.md.
const model = process.env.EVE_IDFON_MODEL || "openai/gpt-6-luna";

export default defineAgent({ model });
