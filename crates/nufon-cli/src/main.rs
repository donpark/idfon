use std::{env, io};

use nufon_client::{Client, ClientError};
use nufon_protocol::{encode_json, Request, Response, ResponseBody, PROTOCOL_VERSION};

const DEFAULT_SOCKET: &str = "/tmp/nufon/nufond.sock";

fn main() {
    if let Err(error) = run() {
        eprintln!("nufon: {error}");
        std::process::exit(1);
    }
}

fn run() -> io::Result<()> {
    let args: Vec<String> = env::args().collect();
    if let Some(topic) = ["help", "schema", "errors", "examples"]
        .iter()
        .find(|topic| args.iter().any(|arg| arg == **topic))
    {
        println!("{}", help_text(topic));
        return Ok(());
    }
    let json = args.iter().any(|arg| arg == "--json");
    let stdin_json = args.iter().any(|arg| arg == "--stdin-json");
    let socket = argument(&args, "--socket").unwrap_or_else(|| DEFAULT_SOCKET.into());
    let selected_identity = argument(&args, "--identity");
    let operation_wait = args
        .windows(2)
        .any(|pair| pair[0] == "operation" && pair[1] == "wait");
    let method = args
        .iter()
        .skip(1)
        .find_map(|arg| match arg.as_str() {
            "status" => Some("status"),
            "context" => Some("context"),
            "identities" => Some("identities"),
            "create" => Some("identity.create"),
            "delete" => Some("identity.delete"),
            "peers" => Some("peers"),
            "add" => Some("peer.add"),
            "update" => Some("peer.update"),
            "remove" => Some("peer.remove"),
            "resolve" => Some("peer.resolve"),
            "show" => Some("peer.show"),
            "peer-status" => Some("peer.status"),
            "operation" if !operation_wait => Some("operation.get"),
            "cancel" => Some("operation.cancel"),
            "events" => Some("events"),
            "access" => Some("access.check"),
            "wait" => Some(if operation_wait {
                "operation.wait"
            } else {
                "wait"
            }),
            "use" => Some("identity.use"),
            "send" => Some("message.send"),
            "send-data" => Some("message.send"),
            "recv" => Some("events"),
            "ticket" => Some("capability.ticket"),
            "grant" => Some("access.grant"),
            "put" => Some("media.resource.put"),
            "get" => Some("media.resource.fetch"),
            _ => None,
        })
        .ok_or_else(|| {
            print_usage();
            io::Error::new(io::ErrorKind::InvalidInput, "invalid command")
        })?;
    let reference = args
        .iter()
        .position(|arg| arg == "resolve")
        .or_else(|| args.iter().position(|arg| arg == "peer"))
        .and_then(|index| args.get(index + 1));
    let operation_id = if operation_wait {
        args.iter()
            .position(|arg| arg == "wait")
            .and_then(|index| args.get(index + 1))
    } else {
        args.iter()
            .position(|arg| arg == "operation" || arg == "cancel")
            .and_then(|index| args.get(index + 1))
    };
    let peer = args
        .iter()
        .position(|arg| arg == "send")
        .and_then(|index| args.get(index + 1));
    let text = args
        .iter()
        .position(|arg| arg == "--text")
        .and_then(|index| args.get(index + 1));
    let idempotency_key = args
        .iter()
        .position(|arg| arg == "--idempotency-key")
        .and_then(|index| args.get(index + 1));
    let capability_ticket = argument(&args, "--capability-ticket");
    let send_data_peer = args
        .iter()
        .position(|arg| arg == "send-data")
        .and_then(|index| {
            // First non-flag argument after "send-data", skipping flag values.
            let mut skip_next = false;
            args[index + 1..].iter().find_map(|arg| {
                if skip_next {
                    skip_next = false;
                    return None;
                }
                if arg == "--file" || arg == "--retries" {
                    skip_next = true;
                    return None;
                }
                (!arg.starts_with('-')).then(|| arg.clone())
            })
        });
    let from = argument(&args, "--from");
    let expires_at = argument(&args, "--expires-at");
    let resource_id = argument(&args, "--resource-id");
    let out = argument(&args, "--out");
    let data_file = argument(&args, "--file");
    let ticket_arg = args
        .iter()
        .position(|arg| arg == "get")
        .and_then(|index| args.get(index + 1));
    let retries = args
        .iter()
        .position(|arg| arg == "--retries")
        .and_then(|index| args.get(index + 1));
    let follow = args.iter().any(|arg| arg == "--follow");
    let after = argument(&args, "--after");
    let event_type = argument(&args, "--type");
    let subject = argument(&args, "--subject");
    let capability = argument(&args, "--capability");
    let identity = args
        .iter()
        .position(|arg| arg == "use" || arg == "create" || arg == "delete")
        .and_then(|index| args.get(index + 1));
    let peer_id = args
        .iter()
        .position(|arg| arg == "add" || arg == "update" || arg == "remove")
        .and_then(|index| args.get(index + 1));
    let peer_name = argument(&args, "--name");
    let endpoint_id = argument(&args, "--endpoint-id");
    let endpoint_addr = argument(&args, "--endpoint-addr");
    let wait = method == "wait";
    let timeout_ms = argument(&args, "--timeout-ms");
    if method == "media.resource.put" {
        return cmd_put(&socket, data_file.as_ref(), resource_id, json, selected_identity.as_deref());
    }
    if args.iter().any(|arg| arg == "send-data") {
        let Some(peer) = send_data_peer else {
            print_usage();
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "send-data requires a peer",
            ));
        };
        return cmd_send_data(&socket, &peer, data_file.as_ref(), retries.and_then(|value| value.parse::<u32>().ok()), json, selected_identity.as_deref());
    }
    if args.iter().any(|arg| arg == "recv") {
        return cmd_recv(&socket, out.as_ref(), from.as_deref(), timeout_ms.and_then(|value| value.parse().ok()), selected_identity.as_deref());
    }
    if method == "media.resource.fetch" {
        let Some(ticket) = ticket_arg else {
            print_usage();
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "get requires a blob ticket",
            ));
        };
        return cmd_get(&socket, &ticket, out.as_ref(), selected_identity.as_deref());
    }
    if method == "peer.resolve" && reference.is_none() {
        print_usage();
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "peer reference required",
        ));
    }

    let mut params = if stdin_json {
        serde_json::from_reader(std::io::stdin()).map_err(io::Error::other)?
    } else if method == "peer.resolve" || method == "peer.show" || method == "peer.status" {
        serde_json::json!({"ref": reference})
    } else if method == "operation.get"
        || method == "operation.cancel"
        || method == "operation.wait"
    {
        serde_json::json!({"operation_id": operation_id, "timeout_ms": timeout_ms})
    } else if method == "access.check" {
        serde_json::json!({"identity": identity, "subject": subject, "capability": capability})
    } else if method == "capability.ticket" {
        serde_json::json!({"subject": subject, "capabilities": [capability.clone().unwrap_or_else(|| "message.receive".into())], "expires_at": expires_at})
    } else if method == "access.grant" {
        serde_json::json!({"subject": subject, "capability": capability})
    } else if method == "identity.use" || method == "identity.create" || method == "identity.delete"
    {
        serde_json::json!({"name": identity})
    } else if method == "peer.add" || method == "peer.update" {
        serde_json::json!({"ref": peer_id, "id": peer_id, "name": peer_name, "endpoint_id": endpoint_id, "endpoint_addr": endpoint_addr, "aliases": []})
    } else if method == "peer.remove" {
        serde_json::json!({"ref": peer_id.or(reference)})
    } else if method == "message.send" {
        serde_json::json!({"to": peer, "text": text, "idempotency_key": idempotency_key, "capability_ticket": capability_ticket.and_then(|value| serde_json::from_str::<serde_json::Value>(&value).ok()), "retries": retries.and_then(|value| value.parse::<u64>().ok())})
    } else if method == "events" || method == "wait" {
        serde_json::json!({"follow": follow, "after": after, "type": event_type})
    } else {
        serde_json::json!({})
    };
    if let Some(identity) = selected_identity {
        if let Some(params) = params.as_object_mut() {
            params.entry("identity").or_insert(serde_json::Value::String(identity));
        }
    }
    if method == "message.send" && (peer.is_none() || text.is_none() || idempotency_key.is_none()) {
        print_usage();
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "send requires peer, text, and idempotency key",
        ));
    }
    if method == "capability.ticket" && subject.is_none() {
        print_usage();
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "ticket requires --subject PEER_ID",
        ));
    }
    if method == "access.grant" && (subject.is_none() || capability.is_none()) {
        print_usage();
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "grant requires --subject PEER_ID and --capability CAPABILITY",
        ));
    }
    let request = Request {
        version: PROTOCOL_VERSION,
        id: "cli-1".into(),
        method: method.into(),
        params,
    };
    let mut client = Client::connect(&socket).map_err(|error| match error {
        ClientError::Connect(source) => io::Error::new(
            source.kind(),
            format!("daemon unavailable; start nufond or check --socket: {source}"),
        ),
        other => io::Error::other(other.to_string()),
    })?;
    let payload = encode_json(&request).map_err(io::Error::other)?;
    let mut response = read_json(&mut client, &payload)?;

    if operation_wait {
        loop {
            let terminal = match &response.body {
                ResponseBody::Success { result, .. } => result
                    .get("operation")
                    .and_then(|value| value.get("status"))
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|status| {
                        matches!(status, "delivered" | "failed" | "expired" | "cancelled")
                    }),
                _ => true,
            };
            if terminal {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
            response = read_json(&mut client, &payload)?;
        }
    }
    if follow && method == "events" {
        loop {
            print_events(&response)?;
            response = client.next_response().map_err(io::Error::other)?.json().map_err(io::Error::other)?;
        }
    }
    if method == "capability.ticket" && !json {
        let ticket = match &response.body {
            ResponseBody::Success { result, .. } => result.get("ticket").cloned().unwrap_or_default(),
            _ => serde_json::Value::Null,
        };
        println!(
            "{}",
            serde_json::to_string(&ticket).map_err(io::Error::other)?
        );
        return Ok(());
    }
    if wait {
        print_events(&response)?;
    } else if json {
        println!(
            "{}",
            serde_json::to_string(&response).map_err(io::Error::other)?
        );
    } else {
        print_human(&response);
    }
    if response.ok {
        Ok(())
    } else {
        Err(io::Error::other("request failed"))
    }
}

fn read_json(client: &mut Client, payload: &[u8]) -> io::Result<Response> {
    client
        .request(payload)
        .map_err(io::Error::other)?
        .json()
        .map_err(io::Error::other)
}

fn print_events(response: &Response) -> io::Result<()> {
    if let nufon_protocol::ResponseBody::Success { result, .. } = &response.body {
        if let Some(events) = result.get("events").and_then(serde_json::Value::as_array) {
            for event in events {
                println!(
                    "{}",
                    serde_json::to_string(event).map_err(io::Error::other)?
                );
            }
        }
    }
    Ok(())
}

fn print_human(response: &Response) {
    match &response.body {
        nufon_protocol::ResponseBody::Success { result, .. } => {
            if response.id == "cli-1" {
                if let Some(ready) = result.get("ready").and_then(serde_json::Value::as_bool) {
                    println!(
                        "{}: {}",
                        response.id,
                        if ready { "ready" } else { "not ready" }
                    );
                } else {
                    println!("{}", result);
                }
            }
        }
        nufon_protocol::ResponseBody::Failure { error, .. } => {
            eprintln!("{:?}: {}", error.code, error.message);
        }
    }
}

fn argument(args: &[String], name: &str) -> Option<String> {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].clone())
}

/// Chunk size for CLI data transfer: bytes per `media.resource.put`/`fetch`
/// call. The JSON array encoding expands ~3-4x, so this stays safely inside
/// the 1 MB IPC frame limit.
const CHUNK: usize = 200_000;

fn generated_resource_id() -> String {
    format!(
        "data-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock before epoch")
            .as_nanos()
    )
}

fn ipc(
    socket: &str,
    method: &str,
    mut params: serde_json::Value,
    identity: Option<&str>,
) -> io::Result<Response> {
    if let Some(identity) = identity {
        params["identity"] = identity.into();
    }
    let request = Request {
        version: PROTOCOL_VERSION,
        id: "cli-1".into(),
        method: method.into(),
        params,
    };
    let mut client = Client::connect(socket).map_err(|error| match error {
        ClientError::Connect(source) => io::Error::new(
            source.kind(),
            format!("daemon unavailable; start nufond or check --socket: {source}"),
        ),
        other => io::Error::other(other.to_string()),
    })?;
    client
        .request(&encode_json(&request).map_err(io::Error::other)?)
        .map_err(io::Error::other)?
        .json()
        .map_err(io::Error::other)
}

fn response_bytes(result: &serde_json::Value) -> io::Result<Vec<u8>> {
    result
        .get("bytes")
        .and_then(serde_json::Value::as_array)
        .map(|values| {
            values
                .iter()
                .map(|value| value.as_u64().unwrap_or(0) as u8)
                .collect::<Vec<u8>>()
        })
        .ok_or_else(|| io::Error::other("response missing bytes"))
}

/// `nufon put`: reads FILE or stdin, stores it with the daemon (chunked when
/// larger than one frame). Returns the final daemon response (finish/one-shot),
/// whose result carries `blob_ticket`, `size_bytes`, and `content_hash`.
fn put_data(
    socket: &str,
    file: Option<&String>,
    resource_id: Option<String>,
    identity: Option<&str>,
) -> io::Result<Response> {
    let data = match file {
        Some(path) => std::fs::read(path)
            .map_err(|error| io::Error::new(error.kind(), format!("cannot read {path}: {error}")))?,
        None => {
            let mut data = Vec::new();
            std::io::Read::read_to_end(&mut std::io::stdin(), &mut data)?;
            data
        }
    };
    let resource_id = resource_id.unwrap_or_else(generated_resource_id);
    let put = |chunk: &[u8], append: bool, finish: bool| {
        ipc(
            socket,
            "media.resource.put",
            serde_json::json!({"resource_id": resource_id, "bytes": chunk, "append": append, "finish": finish}),
            identity,
        )
    };
    let mut response = None;
    let mut offset = 0;
    while offset < data.len() || response.is_none() {
        let end = (offset + CHUNK).min(data.len());
        response = Some(put(&data[offset..end], offset > 0, false)?);
        offset = end;
        if offset >= data.len() {
            break;
        }
    }
    if offset > CHUNK {
        response = Some(put(&[], false, true)?);
    }
    let response = response.expect("at least one request");
    if !response.ok {
        return Err(io::Error::other(request_error(&response)));
    }
    Ok(response)
}

fn result_str(response: &Response, key: &str) -> String {
    match &response.body {
        ResponseBody::Success { result, .. } => result
            .get(key)
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_string(),
        _ => String::new(),
    }
}

fn result_usize(response: &Response, key: &str) -> usize {
    match &response.body {
        ResponseBody::Success { result, .. } => result
            .get(key)
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(0) as usize,
        _ => 0,
    }
}

fn request_error(response: &Response) -> String {
    match &response.body {
        ResponseBody::Failure { error, .. } => format!("{:?}: {}", error.code, error.message),
        _ => "request failed".into(),
    }
}

fn cmd_put(
    socket: &str,
    file: Option<&String>,
    resource_id: Option<String>,
    json: bool,
    identity: Option<&str>,
) -> io::Result<()> {
    let response = put_data(socket, file, resource_id, identity)?;
    if json {
        println!(
            "{}",
            serde_json::to_string(&response).map_err(io::Error::other)?
        );
        return Ok(());
    }
    println!("{}", result_str(&response, "blob_ticket"));
    Ok(())
}

/// `nufon get TICKET`: streams the blob to stdout (or --out FILE) in chunks.
fn cmd_get(
    socket: &str,
    ticket: &str,
    out: Option<&String>,
    identity: Option<&str>,
) -> io::Result<()> {
    fetch_to(socket, ticket, out, identity).map(|_| ())
}

/// Streams the blob to stdout or a file in slices; returns bytes written.
fn fetch_to(
    socket: &str,
    ticket: &str,
    out: Option<&String>,
    identity: Option<&str>,
) -> io::Result<usize> {
    let resource_id = generated_resource_id();
    let mut writer: Box<dyn std::io::Write> = match out {
        Some(path) => Box::new(std::io::BufWriter::new(std::fs::File::create(path)?)),
        None => Box::new(std::io::stdout().lock()),
    };
    let mut offset = 0usize;
    loop {
        let response = ipc(
            socket,
            "media.resource.fetch",
            serde_json::json!({"resource_id": resource_id, "blob_ticket": ticket, "offset": offset, "length": CHUNK}),
            identity,
        )?;
        if !response.ok {
            return Err(io::Error::other(request_error(&response)));
        }
        let (bytes, total_size) = match &response.body {
            ResponseBody::Success { result, .. } => (
                response_bytes(result)?,
                result
                    .get("total_size")
                    .and_then(serde_json::Value::as_u64)
                    .unwrap_or(0) as usize,
            ),
            _ => return Err(io::Error::other("unexpected response")),
        };
        writer.write_all(&bytes)?;
        offset += bytes.len();
        if offset >= total_size {
            break;
        }
        if bytes.is_empty() {
            return Err(io::Error::other("fetch stalled: empty chunk"));
        }
    }
    writer.flush()?;
    Ok(offset)
}

/// `nufon send-data PEER`: stores stdin/FILE as a blob, then signals the
/// ticket to the peer through the message path (NUFON-DATA/1 envelope).
/// Prints the bare BlobTicket once delivery is acknowledged.
fn cmd_send_data(
    socket: &str,
    peer: &str,
    file: Option<&String>,
    retries: Option<u32>,
    json: bool,
    identity: Option<&str>,
) -> io::Result<()> {
    let response = put_data(socket, file, None, identity)?;
    let ticket = result_str(&response, "blob_ticket");
    let size = result_usize(&response, "size_bytes");
    let text = format!("NUFON-DATA/1\nticket={ticket}\nsize={size}");
    // The ticket is content-addressed, so this key is stable across retries
    // with the same content and unique across different content.
    let idempotency_key = format!("nufon-data-{ticket}");
    let response = ipc(
        socket,
        "message.send",
        serde_json::json!({"to": peer, "text": text, "idempotency_key": idempotency_key, "retries": retries}),
        identity,
    )?;
    if !response.ok {
        return Err(io::Error::other(request_error(&response)));
    }
    let operation_id = result_str(&response, "operation_id");
    loop {
        let response = ipc(
            socket,
            "operation.wait",
            serde_json::json!({"operation_id": operation_id}),
            identity,
        )?;
        let status = match &response.body {
            ResponseBody::Success { result, .. } => result
                .get("operation")
                .and_then(|operation| operation.get("status"))
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_string(),
            _ => String::new(),
        };
        match status.as_str() {
            "delivered" => break,
            "failed" | "expired" | "cancelled" => {
                return Err(io::Error::other(format!("send-data {status}")));
            }
            _ => std::thread::sleep(std::time::Duration::from_millis(200)),
        }
    }
    if json {
        println!(
            "{{\"blob_ticket\":\"{ticket}\",\"operation_id\":\"{operation_id}\",\"status\":\"delivered\"}}"
        );
    } else {
        println!("{ticket}");
    }
    Ok(())
}

/// Parses a NUFON-DATA/1 envelope into (blob ticket, declared size).
fn parse_data_envelope(text: &str) -> Option<(String, Option<usize>)> {
    let mut ticket = None;
    let mut size = None;
    for line in text.strip_prefix("NUFON-DATA/1\n")?.lines() {
        let (key, value) = line.split_once('=')?;
        match key {
            "ticket" => ticket = Some(value.to_string()),
            "size" => size = value.parse().ok(),
            _ => {}
        }
    }
    Some((ticket?, size))
}

/// `nufon recv`: waits for a NUFON-DATA/1 message through the daemon's event
/// stream, then streams the referenced blob to stdout (or --out FILE).
fn cmd_recv(
    socket: &str,
    out: Option<&String>,
    from: Option<&str>,
    timeout_ms: Option<u64>,
    identity: Option<&str>,
) -> io::Result<()> {
    let deadline = std::time::Instant::now()
        + std::time::Duration::from_millis(timeout_ms.unwrap_or(60_000));
    // Baseline: only wait for messages that arrive after recv started. No
    // retained events means no `after` filter (a "cur_0" sentinel would be
    // rejected as CursorTooOld — it sorts below the first cursor).
    let mut cursor: Option<String> = None;
    if let Ok(response) = ipc(
        socket,
        "events",
        serde_json::json!({"type": "message.received"}),
        identity,
    ) {
        if let ResponseBody::Success { result, .. } = &response.body {
            cursor = result
                .get("events")
                .and_then(serde_json::Value::as_array)
                .and_then(|events| events.last())
                .and_then(|event| event.get("cursor"))
                .and_then(serde_json::Value::as_str)
                .map(str::to_string);
        }
    }
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::other("recv timed out: no data message arrived"));
        }
        let wait_ms = remaining.as_millis().min(30_000) as u64;
        let response = ipc(
            socket,
            "wait",
            serde_json::json!({"type": "message.received", "after": cursor, "timeout_ms": wait_ms}),
            identity,
        )?;
        if !response.ok {
            return Err(io::Error::other(request_error(&response)));
        }
        let events = match &response.body {
            ResponseBody::Success { result, .. } => result
                .get("events")
                .and_then(serde_json::Value::as_array)
                .cloned()
                .unwrap_or_default(),
            _ => Vec::new(),
        };
        if let Some(next) = events
            .last()
            .and_then(|event| event.get("cursor"))
            .and_then(serde_json::Value::as_str)
        {
            cursor = Some(next.to_string());
        }
        for event in &events {
            let data = &event["data"];
            if let Some(sender) = from {
                if data.get("peer_id").and_then(serde_json::Value::as_str) != Some(sender) {
                    continue;
                }
            }
            let text = data
                .get("text")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("");
            let Some((ticket, declared_size)) = parse_data_envelope(text) else {
                continue;
            };
            let written = fetch_to(socket, &ticket, out, identity)?;
            if let Some(size) = declared_size {
                if written != size {
                    return Err(io::Error::other(format!(
                        "received {written} bytes but envelope declared {size}"
                    )));
                }
            }
            eprintln!(
                "recv: wrote {written} bytes from {}",
                data.get("peer_id").and_then(serde_json::Value::as_str).unwrap_or("?")
            );
            return Ok(());
        }
    }
}

fn print_usage() {
    eprintln!("usage: nufon [--socket PATH] [--identity ID] <status|context|identities|peers>");
    eprintln!("       nufon [--socket PATH] resolve PEER [--json]");
    eprintln!("       nufon [--socket PATH] show PEER [--json]");
    eprintln!("       nufon [--socket PATH] peer-status PEER [--json]");
    eprintln!(
        "       nufon [--socket PATH] access --subject PEER --capability CAPABILITY [--json]"
    );
    eprintln!("       nufon [--socket PATH] use IDENTITY [--json]");
    eprintln!("       nufon [--socket PATH] create IDENTITY [--json]");
    eprintln!("       nufon [--socket PATH] delete IDENTITY [--json]");
    eprintln!("       nufon [--socket PATH] add PEER --name NAME [--endpoint-id ID] [--endpoint-addr JSON]");
    eprintln!("       nufon [--socket PATH] update PEER [--name NAME] [--endpoint-id ID] [--endpoint-addr JSON]");
    eprintln!("       nufon [--socket PATH] remove PEER [--json]");
    eprintln!("       nufon [--socket PATH] send PEER --text TEXT --idempotency-key KEY [--capability-ticket JSON] [--retries N] [--json]");
    eprintln!("       nufon [--socket PATH] cancel OPERATION_ID [--json]");
    eprintln!(
        "       nufon [--socket PATH] events [--follow] [--after CURSOR] [--type TYPE] [--jsonl]"
    );
    eprintln!("       nufon [--socket PATH] wait --type TYPE [--after CURSOR] [--timeout-ms MS]");
    eprintln!("       nufon [--socket PATH] operation wait OPERATION_ID [--timeout-ms MS]");
    eprintln!("       nufon [--socket PATH] put [--file FILE] [--resource-id ID] [--json]   # data from FILE or stdin; prints blob ticket");
    eprintln!("       nufon [--socket PATH] get TICKET [--out FILE]                            # streams blob to stdout or FILE");
    eprintln!("       nufon [--socket PATH] send-data PEER [--file FILE] [--json]              # put + signal ticket via message path");
    eprintln!("       nufon [--socket PATH] recv [--from PEER_ID] [--out FILE] [--timeout-ms MS]");
    eprintln!("       nufon [--socket PATH] ticket --subject PEER_ID [--capability CAP] [--expires-at RFC3339] [--json]");
    eprintln!("       nufon [--socket PATH] grant --subject PEER_ID --capability CAPABILITY [--json]");
    eprintln!("       nufon [--socket PATH] [--identity ID] send --stdin-json < request.json [--json]");
}

fn help_text(topic: &str) -> &'static str {
    match topic {
        "schema" => r#"request: {version:number,id:string,method:string,params:object}; optional --identity selects the daemon identity"#,
        "errors" => "Stable errors: invalid_request, unauthorized, capability_denied, peer_offline, idempotency_key_conflict, cursor_too_old, timeout.",
        "examples" => "nufon status --json\nnufon --identity Bob send alice --text hello --idempotency-key hello-1 --json\nnufon --identity Alice events --follow --jsonl",
        _ => "nufon commands: status, context, identities, peers, resolve, show, peer-status, use, send, send-data, recv, ticket, grant, operation, cancel, events, wait, put, get\nUse --json for machine output and --stdin-json for request parameters.\nData transfer: cat FILE | nufon put  ->  ticket;  nufon get TICKET > copy\nSignaled:      nufon send-data PEER < FILE   |   nufon recv > copy",
    }
}
