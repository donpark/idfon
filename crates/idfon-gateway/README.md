# crates/idfon-gateway

A reusable loopback HTTP gateway for `idfon://` resources, embeddable in an app
so a WebView, an MCP facade, or a local tool can reach account resources over
HTTP. It owns **HTTP mechanics and address mapping** — not identity,
authorization policy, resource providers, or MCP semantics; those arrive as a
`Backend` and an `Authorizer`.

- **Kind:** library
- **Read more:** `docs/idfon-gateway.md`

```sh
cargo test -p idfon-gateway
```
