# crates/idfon-h1

HTTP/1.1 over an existing idfon iroh endpoint — the streaming sibling of
`idfon-h3`. An embedder supplies an `axum::Router` and `serve_router` serves it
to dialing peers on the daemon's own endpoint, so `WebSocketUpgrade`, SSE, and
chunked bodies all work **unmodified**. `H1Client` is the other half: dial a
peer by address and issue requests.

- **Kind:** library
- **Read more:** `docs/idfon-h1.md`

```sh
cargo test -p idfon-h1
```
