// Shared voice-agent toolkit.
//
// One place for the code and heuristics every idfon voice agent needs, so the
// diverse configurations (cloud/local engines, wrapping/injecting,
// self-answering) are **config + persona**, not copied tool implementations.
//
// - providers: STT/TTS seam (openai-compatible, command, module, kokoro)
// - audio: Ogg Opus → PCM, WAV wrap/parse
// - bridge: blob upload + agent→agent send/await
// - tools: voiceRelay / voiceTranscribe / voiceSpeak factories

export * from "./audio";
export * from "./bridge";
export * from "./providers";
export * from "./turn";
export * from "./tools";
