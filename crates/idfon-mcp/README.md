# crates/idfon-mcp

The `idfon-mcp` binary is a byte-pump MCP bridge over `idfon/mcp/1`. The library
also exposes the read-only folder provider (`fs::router`) so it can be served
over MCP stdio or over HTTP/3 (`idfon_h3::serve_router`).

- **Kind:** library + binary (`idfon-mcp`)
- **Read more:** `docs/mcp-transport.md`

```sh
cargo test -p idfon-mcp
```
