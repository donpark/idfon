# crates/idfon-core

Domain security helpers kept independent of transport details: identities and
signing, capability tickets and peer auth, signed paths, relay selection, and
the transport seams the daemon builds on. The gossip/tokio parts are gated so
the same code compiles to wasm for the Cloudflare Worker.

- **Kind:** library (native + wasm)
- **Modules:** `lib` (identity/capabilities), `path`, `relay`, `transport`
- **Read more:** `docs/communication-model.md`, `docs/relay-config.md`,
  `docs/relay-auth.md`

```sh
cargo test -p idfon-core
```
