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
    let json = args.iter().any(|arg| arg == "--json");
    let socket = argument(&args, "--socket").unwrap_or_else(|| DEFAULT_SOCKET.into());
    let method = args
        .iter()
        .skip(1)
        .find_map(|arg| match arg.as_str() {
            "status" => Some("status"),
            "context" => Some("context"),
            "identities" => Some("identities"),
            "peers" => Some("peers"),
            "resolve" => Some("peer.resolve"),
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
    if method == "peer.resolve" && reference.is_none() {
        print_usage();
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "peer reference required",
        ));
    }

    let params = if method == "peer.resolve" {
        serde_json::json!({"ref": reference})
    } else {
        serde_json::json!({})
    };
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
    let response: Response = serde_json::from_slice(&response).map_err(io::Error::other)?;

    if json {
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
}
