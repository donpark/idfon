# crates/idfon-voice-agent

The voice-agent kit and the `eve-idfon-voice` binary: one config-driven runner
that gives a text-first agent a voice, with pluggable backends. This crate owns
what every voice agent shares — the holder handler, the live-media session, and
the turn bridge — and delegates the audio↔text work to a `VoiceBackend`
(`cascade` = STT → agent → TTS; `gpt_live`; local engines plug in the same way).

Adding a voice agent is a config plus an Eve agent dir; adding an engine is one
backend.

- **Kind:** library + binary (`eve-idfon-voice`)
- **Read more:** `docs/voice-agent.md`, `docs/voice-tyger.md`

```sh
cargo test -p idfon-voice-agent
```
