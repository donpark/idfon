//! `idfon-mcp-server` — M4: idfon as an MCP server.
//!
//! A separate adapter process over `idfon-client` (never inside `idfond`, which
//! must not learn MCP). It speaks MCP `2026-07-28` over stdio and maps idfon
//! capabilities to tools. The grant/consent decision stays with the daemon: a
//! denied call is surfaced to the MCP client as a tool error, not pre-empted.

use std::io::{BufRead, Write};

use anyhow::Result;
use clap::Parser;
use idfon_client::Client;
use idfon_protocol::{encode_json, Request, Response, ResponseBody, PROTOCOL_VERSION};
use serde_json::{json, Value};

const MCP_PROTOCOL: &str = "2026-07-28";
const FETCH_CHUNK: u64 = 64 * 1024;

// Reserved `_meta` keys (MCP 2026-07-28, basic/index#_meta).
const META_VERSION: &str = "io.modelcontextprotocol/protocolVersion";
const META_CLIENT_CAPABILITIES: &str = "io.modelcontextprotocol/clientCapabilities";
const META_SERVER_INFO: &str = "io.modelcontextprotocol/serverInfo";
const ERR_INVALID_PARAMS: i64 = -32602;
const ERR_UNSUPPORTED_VERSION: i64 = -32022;

#[derive(Parser)]
#[command(name = "idfon-mcp-server", about = "Expose idfon capabilities as MCP tools")]
struct Cli {
    /// Path to the idfond Unix socket.
    #[arg(long, default_value = "/tmp/idfon/idfond.sock")]
    socket: String,
    /// Session identity override.
    #[arg(long)]
    identity: Option<String>,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let request: Value = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(error) => {
                write_line(
                    &mut stdout,
                    &json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": error.to_string()}}),
                )?;
                continue;
            }
        };
        // Notifications (no id) get no response.
        if request.get("id").is_none() {
            continue;
        }
        let response = handle(&cli, &request);
        write_line(&mut stdout, &response)?;
    }
    Ok(())
}

fn write_line(stdout: &mut std::io::Stdout, value: &Value) -> Result<()> {
    stdout.write_all(serde_json::to_string(value)?.as_bytes())?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}

fn handle(cli: &Cli, request: &Value) -> Value {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let method = request.get("method").and_then(Value::as_str).unwrap_or_default();
    if let Some(error) = validate_request_meta(request) {
        return error;
    }
    match method {
        "server/discover" => json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "resultType": "complete",
                "supportedVersions": [MCP_PROTOCOL],
                "capabilities": {"tools": {}},
                "_meta": server_meta(),
            }
        }),
        "tools/list" => json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {"resultType": "complete", "tools": tools(), "_meta": server_meta()},
        }),
        "tools/call" => tool_call(cli, &id, request),
        other => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": {"code": -32601, "message": format!("Method not found: {other}")},
        }),
    }
}

/// Every request MUST carry `_meta` with the protocol version and client
/// capabilities (MCP 2026-07-28). Missing required fields are `-32602`; an
/// unsupported version is `-32022` with the versions this server does support.
fn validate_request_meta(request: &Value) -> Option<Value> {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let error = |code, message: &str, data: Option<Value>| {
        let mut error = json!({"code": code, "message": message});
        if let Some(data) = data {
            error["data"] = data;
        }
        json!({"jsonrpc": "2.0", "id": id, "error": error})
    };
    let Some(meta) = request.get("params").and_then(|params| params.get("_meta")) else {
        return Some(error(ERR_INVALID_PARAMS, "missing required _meta", None));
    };
    if meta.get(META_VERSION).is_none() || meta.get(META_CLIENT_CAPABILITIES).is_none() {
        return Some(error(
            ERR_INVALID_PARAMS,
            "missing required _meta fields (protocolVersion, clientCapabilities)",
            None,
        ));
    }
    let requested = meta.get(META_VERSION).and_then(Value::as_str).unwrap_or_default();
    if requested != MCP_PROTOCOL {
        return Some(error(
            ERR_UNSUPPORTED_VERSION,
            "Unsupported protocol version",
            Some(json!({"supported": [MCP_PROTOCOL], "requested": requested})),
        ));
    }
    None
}

/// Servers SHOULD identify themselves in every result's `_meta`.
fn server_meta() -> Value {
    json!({META_SERVER_INFO: {"name": "idfon-mcp-server", "version": env!("CARGO_PKG_VERSION")}})
}

/// Each tool maps to an idfon capability; the required grant is stated in the
/// description, and the daemon makes the actual consent decision.
fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": "idfon.list_peers",
            "description": "List idfon peers. Local read; no grant required.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
        }),
        json!({
            "name": "idfon.send_message",
            "description": "Send a text message to a peer. Requires the daemon's message.send grant for that peer.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "to": {"type": "string"},
                    "text": {"type": "string"},
                    "idempotency_key": {"type": "string"},
                },
                "required": ["to", "text"],
            },
        }),
        json!({
            "name": "idfon.put_blob",
            "description": "Store UTF-8 text as a blob and return a bearer BlobTicket. Local; no grant required.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "resource_id": {"type": "string"},
                },
                "required": ["text"],
            },
        }),
        json!({
            "name": "idfon.get_blob",
            "description": "Fetch a blob by BlobTicket (a bearer capability) and return it as text.",
            "inputSchema": {
                "type": "object",
                "properties": {"blob_ticket": {"type": "string"}},
                "required": ["blob_ticket"],
            },
        }),
    ]
}

fn tool_call(cli: &Cli, id: &Value, request: &Value) -> Value {
    let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
    let name = params.get("name").and_then(Value::as_str).unwrap_or_default();
    let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    let argument = |key: &str| args.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();

    let outcome: Result<Value, String> = match name {
        "idfon.list_peers" => daemon_call(cli, "peers", json!({})),
        "idfon.send_message" => {
            let to = argument("to");
            let text = argument("text");
            if to.is_empty() || text.is_empty() {
                Err("to and text are required".into())
            } else {
                let key = match args.get("idempotency_key").and_then(Value::as_str) {
                    Some(key) => key.to_owned(),
                    None => format!("mcp-{to}-{}", now_millis()),
                };
                daemon_call(
                    cli,
                    "message.send",
                    json!({"to": to, "text": text, "idempotency_key": key}),
                )
            }
        }
        "idfon.put_blob" => {
            let text = argument("text");
            if text.is_empty() {
                Err("text is required".into())
            } else {
                let resource_id = match args.get("resource_id").and_then(Value::as_str) {
                    Some(id) => id.to_owned(),
                    None => format!("mcp-{}", now_millis()),
                };
                daemon_call(
                    cli,
                    "media.resource.put",
                    json!({
                        "resource_id": resource_id,
                        "bytes": text.as_bytes(),
                        "append": false,
                        "finish": false,
                    }),
                )
            }
        }
        "idfon.get_blob" => {
            let ticket = argument("blob_ticket");
            if ticket.is_empty() {
                Err("blob_ticket is required".into())
            } else {
                fetch_blob(cli, &ticket).map(|bytes| json!({"text": String::from_utf8_lossy(&bytes)}))
            }
        }
        other => {
            return json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {"code": -32602, "message": format!("Unknown tool: {other}")},
            })
        }
    };

    let (text, is_error) = match outcome {
        Ok(result) => (result.to_string(), false),
        Err(message) => (message, true),
    };
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "resultType": "complete",
            "content": [{"type": "text", "text": text}],
            "isError": is_error,
            "_meta": server_meta(),
        }
    })
}

/// One idfon IPC round trip. A daemon failure (including capability_denied) is
/// returned as an error string for the tool result, not a JSON-RPC error.
fn daemon_call(cli: &Cli, method: &str, mut params: Value) -> Result<Value, String> {
    if let Some(identity) = &cli.identity {
        params["identity"] = Value::String(identity.clone());
    }
    let request = Request {
        version: PROTOCOL_VERSION,
        id: "mcp-1".into(),
        method: method.into(),
        params,
    };
    let mut client = Client::connect(&cli.socket).map_err(|error| error.to_string())?;
    let encoded = encode_json(&request).map_err(|error| error.to_string())?;
    let response: Response = client
        .request(&encoded)
        .map_err(|error| error.to_string())?
        .json()
        .map_err(|error| error.to_string())?;
    match response.body {
        ResponseBody::Success { result, .. } => Ok(result),
        ResponseBody::Failure { error, .. } => Err(format!("{:?}: {}", error.code, error.message)),
    }
}

fn fetch_blob(cli: &Cli, ticket: &str) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    let mut offset = 0u64;
    loop {
        let result = daemon_call(
            cli,
            "media.resource.fetch",
            json!({
                "resource_id": "mcp-fetch",
                "blob_ticket": ticket,
                "offset": offset,
                "length": FETCH_CHUNK,
            }),
        )?;
        let chunk: Vec<u8> = result
            .get("bytes")
            .and_then(Value::as_array)
            .map(|values| values.iter().filter_map(Value::as_u64).map(|byte| byte as u8).collect())
            .unwrap_or_default();
        let total = result
            .get("total_size")
            .and_then(Value::as_u64)
            .unwrap_or(chunk.len() as u64);
        bytes.extend_from_slice(&chunk);
        offset += chunk.len() as u64;
        if offset >= total || chunk.is_empty() {
            break;
        }
    }
    Ok(bytes)
}

fn now_millis() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or(0)
}