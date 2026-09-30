//! `idfon-mcp` library surface.
//!
//! The binary is a byte-pump MCP bridge over `idfon/mcp/1`. This library also
//! exposes the read-only folder provider so it can be served over MCP (stdio)
//! or HTTP/3: [`fs::router`] plus `idfon_h3::serve_router`.
pub mod fs;
