# crates/idfon-live-media

Shared MoQ plumbing for live-call handlers: parse an `IDFON-LIVE/1` invite,
subscribe the caller's broadcast as 20 ms PCM frames, publish the return leg,
and sign the return-leg invite.

Extracted from the GPT-Live handler so a second handler can reuse the transport
instead of duplicating it. Deliberately provider-neutral: it knows nothing about
GPT-Live or any voice engine.

- **Kind:** library
- **Read more:** `docs/voice-agent.md`

```sh
cargo test -p idfon-live-media
```
