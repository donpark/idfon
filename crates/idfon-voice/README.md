# crates/idfon-voice

The provider seam behind the voice side-channel: STT, TTS, and endpointing are
interchangeable engines (`apple_ffi`, `deepgram`, `cartesia`, `elevenlabs`,
`gateway`, plus local/stream/stub), and this crate also holds the voice-service
pieces around them — barge-in, echo suppression, speaker arbitration, turns, and
the listen/speak adapters.

The service boundary is **text**: the voice service never owns content, so
engines can be swapped without touching the channel or any agent.

- **Kind:** library
- **Read more:** `docs/voice-side-channel.md`, `docs/voice-decisions.md`

```sh
cargo test -p idfon-voice
```
