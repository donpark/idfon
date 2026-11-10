//! Minimal MCP 2026-07-28 resource server over a single filesystem root.
//!
//! Exposes files under `--root` as resources with `idfon://<account>/fs/<path>`
//! URIs. Run it under `idfon-mcp serve --command` to make a folder reachable
//! over `idfon/mcp/1`; a local MCP host can run it directly. Read-only,
//! traversal-safe, and returns text or base64 blob contents.

use std::{
    fs,
    io::{self, BufRead, Write},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use axum::response::IntoResponse;
use base64::{engine::general_purpose::STANDARD, Engine};
use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use serde_json::{json, Value};

const PROTOCOL: &str = "2026-07-28";
const META_VERSION: &str = "io.modelcontextprotocol/protocolVersion";
const ERR_INVALID_PARAMS: i64 = -32602;
const ERR_METHOD_NOT_FOUND: i64 = -32601;
const ERR_PARSE: i64 = -32700;
const ERR_UNSUPPORTED_VERSION: i64 = -32022;
const MAX_LISTED: usize = 500;
const MAX_DEPTH: usize = 8;
const MAX_READ_BYTES: u64 = 16 * 1024 * 1024;

/// Path-segment encoding: unreserved characters pass through, `/` is the caller's.
const SEGMENT: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

/// Serves newline-delimited MCP JSON-RPC over stdio.
pub fn serve(root: &Path, account: &str) -> Result<()> {
    FsServer::new(root, account)?.serve_stdio()
}

pub struct FsServer {
    root: PathBuf,
    account: String,
}

impl FsServer {
    pub fn new(root: &Path, account: &str) -> Result<Self> {
        let root =
            fs::canonicalize(root).with_context(|| format!("resource root {}", root.display()))?;
        anyhow::ensure!(root.is_dir(), "resource root is not a directory");
        Ok(Self {
            root,
            account: account.to_owned(),
        })
    }

    fn serve_stdio(&self) -> Result<()> {
        let stdin = io::stdin();
        let mut stdout = io::stdout();
        for line in stdin.lock().lines() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            let response = match serde_json::from_str::<Value>(&line) {
                Ok(request) => {
                    // Notifications carry no id and get no response.
                    if request.get("id").is_none() {
                        continue;
                    }
                    self.handle(&request)
                }
                Err(error) => failure(Value::Null, ERR_PARSE, &error.to_string()),
            };
            writeln!(stdout, "{}", serde_json::to_string(&response)?)?;
            stdout.flush()?;
        }
        Ok(())
    }

    fn handle(&self, request: &Value) -> Value {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let method = request
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if let Err((code, message)) = self.check_version(request) {
            return failure(id, code, &message);
        }
        match method {
            "server/discover" => success(id, self.discover()),
            "resources/list" => success(id, self.list()),
            "resources/templates/list" => success(id, self.templates()),
            "resources/read" => match request.pointer("/params/uri").and_then(Value::as_str) {
                Some(uri) => match self.read(uri) {
                    Ok(contents) => success(id, contents),
                    Err((code, message)) => failure(id, code, &message),
                },
                None => failure(id, ERR_INVALID_PARAMS, "uri is required"),
            },
            "tools/list" => success(id, self.tools()),
            "tools/call" => {
                let name = request.pointer("/params/name").and_then(Value::as_str);
                let args = request.pointer("/params/arguments").cloned().unwrap_or(json!({}));
                match (name, self.call_tool(name.unwrap_or(""), &args)) {
                    (Some(_), Ok(result)) => success(
                        id,
                        json!({"content": [{"type": "text", "text": result.to_string()}], "isError": false}),
                    ),
                    (Some(_), Err((code, message))) => failure(id, code, &message),
                    (None, _) => failure(id, ERR_INVALID_PARAMS, "name is required"),
                }
            },
            other => failure(id, ERR_METHOD_NOT_FOUND, &format!("method not found: {other}")),
        }
    }

    /// Every 2026-07-28 request carries its version in `_meta`.
    fn check_version(&self, request: &Value) -> Result<(), (i64, String)> {
        let version = request
            .pointer("/params/_meta")
            .and_then(|meta| meta.get(META_VERSION))
            .and_then(Value::as_str);
        match version {
            None => Err((
                ERR_INVALID_PARAMS,
                format!("missing {META_VERSION}"),
            )),
            Some(version) if version == PROTOCOL => Ok(()),
            Some(version) => Err((
                ERR_UNSUPPORTED_VERSION,
                format!("unsupported protocol version {version}"),
            )),
        }
    }

    /// The diagnostics tools (`docs/mcp-control.md`): read-only queries over
    /// the `<root>/diag/` views the daemon materializes from `IDFON-DIAG/1`
    /// envelopes. Read-only is load-bearing — no tool here mutates anything.
    fn tools(&self) -> Value {
        json!([
            {
                "name": "diag.tail",
                "description": "Recent Idfon diagnostic events across devices (wake outcomes, push registration, token lifecycle). Events are {ts_ms, kind, detail, device, build}.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "device": {"type": "string", "description": "only this device's events"},
                        "since": {"type": "integer", "description": "ts_ms lower bound"},
                        "limit": {"type": "integer", "description": "max events returned, newest last (default 200)"},
                    },
                },
            },
            {
                "name": "wake.trace",
                "description": "One call attempt's timeline as recorded by the device: registration -> ring -> push -> report -> answer -> media. Returns {call, device, build, stages}.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"call": {"type": "string", "description": "the call UUID"}},
                    "required": ["call"],
                },
            },
        ])
    }

    fn call_tool(&self, name: &str, args: &Value) -> Result<Value, (i64, String)> {
        match name {
            "diag.tail" => {
                let since = args.get("since").and_then(Value::as_u64).unwrap_or(0);
                let limit = args.get("limit").and_then(Value::as_u64).unwrap_or(200).min(2000) as usize;
                let device = args.get("device").and_then(Value::as_str);
                let mut events = Vec::new();
                let dir = self.root.join("diag");
                let entries = std::fs::read_dir(&dir).map_err(|error| {
                    (ERR_INVALID_PARAMS, format!("no diag views under {}: {error}", dir.display()))
                })?;
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                        continue;
                    }
                    if let Some(device) = device {
                        if path.file_stem().and_then(|s| s.to_str()) != Some(device) {
                            continue;
                        }
                    }
                    let Ok(text) = std::fs::read_to_string(&path) else { continue };
                    for line in text.lines() {
                        let Ok(event) = serde_json::from_str::<Value>(line) else { continue };
                        if event.get("ts_ms").and_then(Value::as_u64).unwrap_or(0) >= since {
                            events.push(event);
                        }
                    }
                }
                events.sort_by_key(|event| event.get("ts_ms").and_then(Value::as_u64).unwrap_or(0));
                let dropped = events.len().saturating_sub(limit);
                events = events.split_off(dropped);
                Ok(json!({"events": events, "dropped": dropped}))
            }
            "wake.trace" => {
                let call = args.get("call").and_then(Value::as_str).unwrap_or("");
                if call.is_empty()
                    || !call
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
                {
                    return Err((ERR_INVALID_PARAMS, "call must be an id (no path characters)".into()));
                }
                let path = self.root.join("diag").join(format!("wake-{call}.json"));
                let bytes = std::fs::read(&path).map_err(|_| {
                    (ERR_INVALID_PARAMS, format!("no wake trace for call {call}"))
                })?;
                serde_json::from_slice(&bytes)
                    .map_err(|error| (ERR_INVALID_PARAMS, format!("wake trace unreadable: {error}")))
            }
            other => Err((ERR_METHOD_NOT_FOUND, format!("tool not found: {other}"))),
        }
    }

    fn discover(&self) -> Value {
        json!({
            "resultType": "complete",
            "supportedVersions": [PROTOCOL],
            "capabilities": {"resources": {}, "tools": {}},
            "_meta": {
                "io.modelcontextprotocol/serverInfo": {
                    "name": "idfon-mcp-fs",
                    "version": env!("CARGO_PKG_VERSION"),
                }
            },
            "instructions": "Read-only files under the configured root.",
            "ttlMs": 3_600_000,
            "cacheScope": "private",
        })
    }

    fn list(&self) -> Value {
        let mut resources = Vec::new();
        self.collect(self.root.clone(), 0, &mut Vec::new(), &mut resources);
        json!({"resultType": "complete", "resources": resources})
    }

    fn collect(&self, dir: PathBuf, depth: usize, rel: &mut Vec<String>, out: &mut Vec<Value>) {
        if depth > MAX_DEPTH || out.len() >= MAX_LISTED {
            return;
        }
        let Ok(entries) = fs::read_dir(&dir) else {
            return;
        };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            if out.len() >= MAX_LISTED {
                return;
            }
            let Ok(name) = entry.file_name().into_string() else {
                continue;
            };
            if name.starts_with('.') {
                continue;
            }
            let path = entry.path();
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            rel.push(name);
            if meta.is_dir() {
                self.collect(path, depth + 1, rel, out);
            } else if meta.is_file() {
                let relpath = rel.join("/");
                out.push(json!({
                    "uri": self.uri(&encode_path(&relpath)),
                    "name": relpath,
                    "mimeType": idfon_core::path::mime_for(&path),
                }));
            }
            rel.pop();
        }
    }

    fn templates(&self) -> Value {
        json!({
            "resultType": "complete",
            "resourceTemplates": [{
                "uriTemplate": format!("idfon://{}/fs/{{path}}", self.account),
                "name": "Files",
                "description": "Read-only files under the configured root.",
                "mimeType": "application/octet-stream",
            }],
        })
    }

    fn read(&self, uri: &str) -> Result<Value, (i64, String)> {
        let prefix = format!("idfon://{}/fs/", self.account);
        let encoded = uri.strip_prefix(&prefix).ok_or((
            ERR_INVALID_PARAMS,
            "uri is not a resource of this account".to_owned(),
        ))?;
        let decoded = percent_decode_str(encoded).decode_utf8().map_err(|_| {
            (
                ERR_INVALID_PARAMS,
                "uri is not valid UTF-8".to_owned(),
            )
        })?;
        let (bytes, mime) = self.read_file(decoded.as_ref())?;
        let entry = match String::from_utf8(bytes) {
            Ok(text) => json!({"uri": uri, "mimeType": mime, "text": text}),
            Err(error) => json!({
                "uri": uri,
                "mimeType": mime,
                "blob": STANDARD.encode(error.into_bytes()),
            }),
        };
        Ok(json!({"resultType": "complete", "contents": [entry]}))
    }

    /// Traversal-safe read of a root-relative path, shared by the MCP and H3
    /// surfaces. Rejects absolute paths, `..`, and symlinks that escape the
    /// root; returns the bytes and a mime type.
    pub fn read_file(&self, rel_path: &str) -> Result<(Vec<u8>, String), (i64, String)> {
        let Some(rel) = idfon_core::path::safe_relative_path(rel_path) else {
            return Err((ERR_INVALID_PARAMS, "invalid path".to_owned()));
        };
        let target = fs::canonicalize(self.root.join(rel))
            .map_err(|_| (ERR_INVALID_PARAMS, format!("not found: {rel_path}")))?;
        if !target.starts_with(&self.root) || !target.is_file() {
            return Err((ERR_INVALID_PARAMS, format!("not found: {rel_path}")));
        }
        let meta = fs::metadata(&target)
            .map_err(|_| (ERR_INVALID_PARAMS, format!("not found: {rel_path}")))?;
        if meta.len() > MAX_READ_BYTES {
            return Err((ERR_INVALID_PARAMS, "resource too large".to_owned()));
        }
        let bytes = fs::read(&target)
            .map_err(|_| (ERR_INVALID_PARAMS, format!("not found: {rel_path}")))?;
        Ok((bytes, idfon_core::path::mime_for(&target)))
    }

    fn uri(&self, encoded_path: &str) -> String {
        format!("idfon://{}/fs/{}", self.account, encoded_path)
    }
}

/// Read-only HTTP/3 view of a folder root for `idfon_h3::serve_router`.
///
/// `GET /fs/<path>` returns the raw bytes with a mime type; the same traversal
/// and size checks as the MCP resource surface apply. This is the provider that
/// `idfon://<account>/fs/<path>` resolves to.
pub fn router(root: &Path, account: &str) -> Result<axum::Router> {
    let server = std::sync::Arc::new(FsServer::new(root, account)?);
    Ok(axum::Router::new().route(
        "/fs/{*path}",
        axum::routing::get(
            move |axum::extract::Path(path): axum::extract::Path<String>| {
                let server = std::sync::Arc::clone(&server);
                async move {
                    match server.read_file(&path) {
                        Ok((bytes, mime)) => {
                            ([(axum::http::header::CONTENT_TYPE, mime)], bytes).into_response()
                        }
                        Err((_, message)) => {
                            (axum::http::StatusCode::NOT_FOUND, message).into_response()
                        }
                    }
                }
            },
        ),
    ))
}

fn encode_path(rel: &str) -> String {
    rel.split('/')
        .map(|segment| utf8_percent_encode(segment, SEGMENT).to_string())
        .collect::<Vec<_>>()
        .join("/")
}

fn success(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn failure(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "idfon-mcp-fs-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn lists_and_reads_text_files() {
        let dir = temp_dir("list");
        fs::write(dir.join("readme.md"), "# hi").unwrap();
        fs::create_dir_all(dir.join("sub")).unwrap();
        fs::write(dir.join("sub").join("note.txt"), "note").unwrap();
        let server = FsServer::new(&dir, "acct").unwrap();

        let resources = server.list()["resources"].as_array().unwrap().clone();
        let find = |uri: &str| {
            resources
                .iter()
                .find(|resource| resource["uri"] == uri)
                .cloned()
                .unwrap_or_else(|| panic!("missing {uri}"))
        };
        assert_eq!(find("idfon://acct/fs/readme.md")["mimeType"], "text/markdown");
        assert_eq!(
            find("idfon://acct/fs/sub/note.txt")["mimeType"],
            "text/plain"
        );

        let read = server.read("idfon://acct/fs/sub/note.txt").unwrap();
        assert_eq!(read["contents"][0]["text"], "note");

        let template = server.templates()["resourceTemplates"][0]["uriTemplate"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(template, "idfon://acct/fs/{path}");

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn rejects_traversal_foreign_accounts_and_missing_files() {
        let dir = temp_dir("traversal");
        fs::write(dir.join("ok.txt"), "ok").unwrap();
        let server = FsServer::new(&dir, "acct").unwrap();

        assert!(server.read("idfon://acct/fs/../secret").is_err());
        assert!(server.read("idfon://acct/fs/ok.txt").is_ok());
        assert!(server.read("idfon://other/fs/ok.txt").is_err());
        assert!(server.read("idfon://acct/fs/missing.txt").is_err());
        assert!(server.read("file:///etc/passwd").is_err());

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn returns_binary_contents_as_base64() {
        let dir = temp_dir("binary");
        fs::write(dir.join("image.png"), [0xff, 0x00, 0x01, 0xfe]).unwrap();
        let server = FsServer::new(&dir, "acct").unwrap();

        let read = server.read("idfon://acct/fs/image.png").unwrap();
        assert_eq!(read["contents"][0]["mimeType"], "image/png");
        assert_eq!(STANDARD.decode(
            read["contents"][0]["blob"].as_str().unwrap()
        ).unwrap(), vec![0xff, 0x00, 0x01, 0xfe]);

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn diagnostic_tools_tail_and_trace() {
        let dir = temp_dir("tools");
        std::fs::create_dir_all(dir.join("diag")).unwrap();
        std::fs::write(
            dir.join("diag/iphone.jsonl"),
            "{\"ts_ms\":1,\"kind\":\"push.received\",\"detail\":{\"call\":\"C1\"},\"device\":\"iphone\",\"build\":\"b1\"}\n{\"ts_ms\":2,\"kind\":\"wake\",\"detail\":{\"call\":\"C1\"},\"device\":\"iphone\",\"build\":\"b1\"}\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("diag/wake-C1.json"),
            "{\"call\":\"C1\",\"stages\":[{\"ts_ms\":1}]}",
        )
        .unwrap();
        let server = FsServer::new(&dir, "acct").unwrap();

        let tools = server.tools();
        assert_eq!(tools.as_array().unwrap().len(), 2, "two read-only diagnostics tools");

        let tail = server.call_tool("diag.tail", &json!({"limit": 1})).expect("tail");
        assert_eq!(tail["events"].as_array().unwrap().len(), 1, "limit applies");
        assert_eq!(tail["dropped"], 1, "older events are counted as dropped");
        assert_eq!(tail["events"][0]["ts_ms"], 2, "newest survives the tail");

        let filtered = server
            .call_tool("diag.tail", &json!({"device": "iphone", "since": 2}))
            .expect("filtered");
        assert_eq!(filtered["events"].as_array().unwrap().len(), 1, "device+since filter");

        let trace = server.call_tool("wake.trace", &json!({"call": "C1"})).expect("trace");
        assert_eq!(trace["call"], "C1");
        let missing = server.call_tool("wake.trace", &json!({"call": "NOPE"}));
        assert!(missing.is_err(), "a missing trace is an error, not a hang");
        let traversal = server.call_tool("wake.trace", &json!({"call": "../etc/passwd"}));
        assert!(traversal.is_err(), "path characters are refused");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn discovers_resources_and_enforces_the_protocol_version() {
        let dir = temp_dir("discover");
        let server = FsServer::new(&dir, "acct").unwrap();

        let discover = server.handle(&json!({
            "jsonrpc": "2.0", "id": 1, "method": "server/discover",
            "params": {"_meta": {META_VERSION: PROTOCOL}},
        }));
        assert_eq!(discover["result"]["capabilities"]["resources"], json!({}));

        let missing = server.handle(&json!({
            "jsonrpc": "2.0", "id": 2, "method": "resources/list", "params": {},
        }));
        assert_eq!(missing["error"]["code"], ERR_INVALID_PARAMS);

        let unsupported = server.handle(&json!({
            "jsonrpc": "2.0", "id": 3, "method": "resources/list",
            "params": {"_meta": {META_VERSION: "2025-03-26"}},
        }));
        assert_eq!(unsupported["error"]["code"], ERR_UNSUPPORTED_VERSION);

        fs::remove_dir_all(dir).unwrap();
    }
}
