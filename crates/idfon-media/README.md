# crates/idfon-media

The media plane: live-call sessions and their service loop, MoQ video
integration, the platform adapter seam for capture and rendering, headless
publish/subscribe (no capture device), and connection-health tracing.

The `seam` module is deliberate — idfon code depends on those traits, and only
this module and the concrete adapters reference upstream `moq_media`/`moq_audio`
types, so an upstream churn lands in one place.

- **Kind:** library
- **Modules:** `live`, `service`, `video`, `seam`, `health`
- **Read more:** `docs/media-adaptation.md` (§B2.2 for the health verdict)

```sh
cargo test -p idfon-media
```
