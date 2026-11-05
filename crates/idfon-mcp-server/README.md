# crates/idfon-mcp-server

MCP *server* adapter: idfon as a tool provider. A separate process over
`idfon-client` — never inside `idfond`, which must not learn MCP. Speaks MCP
over stdio and maps idfon capabilities to tools.

The grant/consent decision stays with the daemon: a denied call surfaces to the
MCP client as a tool error rather than being pre-empted here.

- **Kind:** binary (`idfon-mcp-server`)
- **Read more:** `docs/mcp-transport.md`

```sh
cargo test -p idfon-mcp-server
```
