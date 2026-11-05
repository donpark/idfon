# crates/idfon-h3

HTTP/3 over an existing idfon iroh endpoint: the "host HTTP endpoints over iroh"
seam. `serve_router` accepts inbound connections on a side-channel ALPN beside
the message ALPN — enabling it does not disturb chat — and `H3Client` issues
HTTP/3 requests to a peer by endpoint id.

- **Kind:** library
- **Read more:** `docs/idfon-gateway.md`, `docs/mcp-transport.md`

```sh
cargo test -p idfon-h3
```
