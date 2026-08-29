use std::{env, io, os::unix::net::UnixStream, path::PathBuf};

use nufon_protocol::{encode_json, Request, Response, PROTOCOL_VERSION};

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
            "peers" => Some("peers"),
            "resolve" => Some("peer.resolve"),
            "show" => Some("peer.show"),
            "peer-status" => Some("peer.status"),
            "operation" if !operation_wait => Some("operation.get"),
            "cancel" => Some("operation.cancel"),
            "events" => Some("events"),
            "wait" => Some(if operation_wait {
                "operation.wait"
            } else {
                "wait"
            }),
            "use" => Some("identity.use"),
            "send" => Some("message.send"),
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
    let retries = args
        .iter()
        .position(|arg| arg == "--retries")
        .and_then(|index| args.get(index + 1));
    let follow = args.iter().any(|arg| arg == "--follow");
    let after = argument(&args, "--after");
    let event_type = argument(&args, "--type");
    let identity = args
        .iter()
        .position(|arg| arg == "use")
        .and_then(|index| args.get(index + 1));
    let wait = method == "wait";
    let timeout_ms = argument(&args, "--timeout-ms");
    if method == "peer.resolve" && reference.is_none() {
        print_usage();
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "peer reference required",
        ));
    }

    let params = if stdin_json {
        serde_json::from_reader(std::io::stdin()).map_err(io::Error::other)?
    } else if method == "peer.resolve" || method == "peer.show" || method == "peer.status" {
        serde_json::json!({"ref": reference})
    } else if method == "operation.get"
        || method == "operation.cancel"
        || method == "operation.wait"
    {
        serde_json::json!({"operation_id": operation_id, "timeout_ms": timeout_ms})
    } else if method == "identity.use" {
        serde_json::json!({"name": identity})
    } else if method == "message.send" {
        serde_json::json!({"to": peer, "text": text, "idempotency_key": idempotency_key, "retries": retries})
    } else if method == "events" || method == "wait" {
        serde_json::json!({"follow": follow, "after": after, "type": event_type})
    } else {
        serde_json::json!({})
    };
    if method == "message.send" && (peer.is_none() || text.is_none() || idempotency_key.is_none()) {
        print_usage();
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "send requires peer, text, and idempotency key",
        ));
    }
    let request = Request {
        version: PROTOCOL_VERSION,
        id: "cli-1".into(),
        method: method.into(),
        params,
    };
    let mut stream = UnixStream::connect(PathBuf::from(socket)).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("daemon unavailable; start nufond or check --socket: {error}"),
        )
    })?;
    let payload = encode_json(&request).map_err(io::Error::other)?;
    std::io::Write::write_all(&mut stream, &(payload.len() as u32).to_be_bytes())?;
    std::io::Write::write_all(&mut stream, &payload)?;

    let mut header = [0; 4];
    std::io::Read::read_exact(&mut stream, &mut header)?;
    let length = u32::from_be_bytes(header) as usize;
    if length > nufon_protocol::MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "response frame too large",
        ));
    }
    let mut response = vec![0; length];
    std::io::Read::read_exact(&mut stream, &mut response)?;
    let mut response: Response = serde_json::from_slice(&response).map_err(io::Error::other)?;

    if operation_wait {
        loop {
            let terminal = match &response.body {
                nufon_protocol::ResponseBody::Success { result, .. } => result
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
            std::io::Write::write_all(&mut stream, &(payload.len() as u32).to_be_bytes())?;
            std::io::Write::write_all(&mut stream, &payload)?;
            std::io::Read::read_exact(&mut stream, &mut header)?;
            let length = u32::from_be_bytes(header) as usize;
            let mut bytes = vec![0; length];
            std::io::Read::read_exact(&mut stream, &mut bytes)?;
            response = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        }
    }
    if follow && method == "events" {
        loop {
            print_events(&response)?;
            let mut header = [0; 4];
            std::io::Read::read_exact(&mut stream, &mut header)?;
            let length = u32::from_be_bytes(header) as usize;
            if length > nufon_protocol::MAX_FRAME_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "response frame too large",
                ));
            }
            let mut bytes = vec![0; length];
            std::io::Read::read_exact(&mut stream, &mut bytes)?;
            response = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        }
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

fn print_usage() {
    eprintln!("usage: nufon [--socket PATH] <status|context|identities|peers>");
    eprintln!("       nufon [--socket PATH] resolve PEER [--json]");
    eprintln!("       nufon [--socket PATH] show PEER [--json]");
    eprintln!("       nufon [--socket PATH] peer-status PEER [--json]");
    eprintln!("       nufon [--socket PATH] use IDENTITY [--json]");
    eprintln!("       nufon [--socket PATH] send PEER --text TEXT --idempotency-key KEY [--retries N] [--json]");
    eprintln!("       nufon [--socket PATH] cancel OPERATION_ID [--json]");
    eprintln!(
        "       nufon [--socket PATH] events [--follow] [--after CURSOR] [--type TYPE] [--jsonl]"
    );
    eprintln!("       nufon [--socket PATH] wait --type TYPE [--after CURSOR] [--timeout-ms MS]");
    eprintln!("       nufon [--socket PATH] operation wait OPERATION_ID [--timeout-ms MS]");
    eprintln!("       nufon [--socket PATH] send --stdin-json < request.json [--json]");
}

fn help_text(topic: &str) -> &'static str {
    match topic {
        "schema" => r#"request: {version:number,id:string,method:string,params:object}"#,
        "errors" => "Stable errors: invalid_request, unauthorized, capability_denied, peer_offline, idempotency_key_conflict, cursor_too_old, timeout.",
        "examples" => "nufon status --json\nnufon send alice --text hello --idempotency-key hello-1 --json\nnufon events --follow --jsonl",
        _ => "nufon commands: status, context, identities, peers, resolve, show, peer-status, use, send, operation, cancel, events, wait\nUse --json for machine output and --stdin-json for request parameters.",
    }
}
