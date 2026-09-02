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
    } else if method == "identity.use" || method == "identity.create" || method == "identity.delete"
    {
        serde_json::json!({"name": identity})
    } else if method == "peer.add" || method == "peer.update" {
        serde_json::json!({"ref": peer_id, "id": peer_id, "name": peer_name, "endpoint_id": endpoint_id, "endpoint_addr": endpoint_addr, "aliases": []})
    } else if method == "peer.remove" {
        serde_json::json!({"ref": peer_id.or(reference)})
    } else if method == "message.send" {
        serde_json::json!({"to": peer, "text": text, "idempotency_key": idempotency_key, "capability_ticket": capability_ticket.and_then(|value| serde_json::from_str::<serde_json::Value>(&value).ok()), "retries": retries})
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
    eprintln!("       nufon [--socket PATH] [--identity ID] send --stdin-json < request.json [--json]");
}

fn help_text(topic: &str) -> &'static str {
    match topic {
        "schema" => r#"request: {version:number,id:string,method:string,params:object}; optional --identity selects the daemon identity"#,
        "errors" => "Stable errors: invalid_request, unauthorized, capability_denied, peer_offline, idempotency_key_conflict, cursor_too_old, timeout.",
        "examples" => "nufon status --json\nnufon --identity Bob send alice --text hello --idempotency-key hello-1 --json\nnufon --identity Alice events --follow --jsonl",
        _ => "nufon commands: status, context, identities, peers, resolve, show, peer-status, use, send, operation, cancel, events, wait\nUse --json for machine output and --stdin-json for request parameters.",
    }
}
