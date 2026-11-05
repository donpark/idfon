# crates/idfon-channel

WebSocket-shaped message channels over an existing idfon iroh endpoint, with no
HTTP in the path. One channel owns one ordered, reliable bi-stream, so messages
keep the transport's ordering; the wire form is one frame per message
(`[kind: u8][len: u32 LE][payload]`). Deliberately *not* a WebSocket
implementation — there is no upgrade, no HTTP/1.1 framing, no RFC 6455 layer.

- **Kind:** library
- **Status:** library only; no consumer is wired to it yet
- **Read more:** `docs/idfon-channel.md`

```sh
cargo test -p idfon-channel
```
