//! Idfon CLI: thin client over the idfond Unix-socket IPC. Argument parsing
//! is clap derive with noun-verb subcommands (`idfon peer add`,
//! `idfon live stop`, ...) that map onto daemon methods (`peer.add`,
//! `media.live.stop`, ...). One or more request/response exchanges per
//! connection, matching the daemon's `read_frame`/`write_frame` loop
//! (`crates/idfond/src/main.rs`).
//!
//! Output contracts the scripts rely on:
//! - `--json` prints the full `Response` envelope; default is human output.
//! - `put`/`stream`/`send-data` print a bare ticket; `get`/`listen` stream
//!   bytes; bare `wait` prints one JSON line per event.
//! - `--stdin-json` (hidden) replaces the request params wholesale from
//!   stdin, for RPC pass-through scripting.

use std::{
    env, io,
    path::{Path, PathBuf},
    process::{Command as StdCommand, Stdio},
    sync::OnceLock,
    time::Duration,
};

use clap::{Parser, Subcommand};
use idfon_client::{Client, ClientError};
use idfon_protocol::{encode_json, Request, Response, ResponseBody, PROTOCOL_VERSION};
use serde_json::{json, Value};

const DEFAULT_SOCKET: &str = "/tmp/idfon/idfond.sock";
const DAEMON_START_TIMEOUT: Duration = Duration::from_secs(5);
/// Auto-started daemons exit after this long with no connected clients.
const DAEMON_IDLE_EXIT_SECS: &str = "600";
/// `idfon --keep-alive`: spawned daemon never idles out.
static KEEP_ALIVE: OnceLock<bool> = OnceLock::new();

/// Locates idfond: next to the idfon binary first (cargo builds them
/// together), then PATH.
fn find_daemon_binary() -> Option<PathBuf> {
    let sibling = env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|dir| dir.join("idfond")));
    match sibling {
        Some(path) if path.is_file() => Some(path),
        _ => env::var_os("PATH").and_then(|paths| {
            env::split_paths(&paths)
                .map(|dir| dir.join("idfond"))
                .find(|path| path.is_file())
        }),
    }
}

#[derive(Parser)]
#[command(
    name = "idfon",
    version,
    about = "Control the idfond daemon: identity, peers, messaging, data transfer, live audio",
    after_help = "Data transfer:  cat FILE | idfon put  ->  ticket;  idfon get TICKET > copy\nSignaled:       idfon send PEER --file < FILE  |  idfon recv > copy\nLive broadcast: idfon send --stream --file FILE --loop  ->  ticket;  idfon get TICKET > copy.wav\n1:1 call:       idfon send PEER --stream --file FILE  |  idfon recv --stream --out copy.wav\n                (calls are session-scoped: they block until hangup and print no ticket)\nTickets:        get TICKET fetches blob tickets; iroh-live: tickets capture live audio"
)]
struct Cli {
    /// Daemon socket path
    #[arg(long, global = true, value_name = "PATH")]
    socket: Option<String>,
    /// Daemon identity to act as
    #[arg(long, global = true, value_name = "ID")]
    identity: Option<String>,
    /// Machine output: print the full Response envelope
    #[arg(long, global = true)]
    json: bool,
    /// Auto-started daemon: disable idle shutdown (stays running until `idfon shutdown`)
    #[arg(long, global = true)]
    keep_alive: bool,
    /// Replace request params with a JSON document read from stdin
    #[arg(long, global = true, hide = true)]
    stdin_json: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Show daemon status
    Status,
    /// Stop the background daemon
    Shutdown,
    /// Manage identities
    #[command(subcommand)]
    Identity(IdentityCmd),
    /// Manage peers
    #[command(subcommand)]
    Peer(PeerCmd),
    /// Send content: --text chat, --file blob, --stream live (PEER = 1:1, no PEER = broadcast)
    ///
    /// Ticket contract: --text returns an operation id (delivery via
    /// `operation wait`); --file prints the BlobTicket after delivery;
    /// --stream without PEER prints a live ticket; --stream with PEER is a
    /// 1:1 call that blocks until hangup and prints no ticket.
    Send(SendArgs),
    /// Receive a peer push: signaled blob (--file mode) or 1:1 stream (--stream)
    Recv(RecvArgs),
    /// Fetch daemon events (follow with --follow)
    Events(EventsArgs),
    /// Block until a matching event arrives (--json prints the Response envelope,
    /// like events without --follow)
    Wait(WaitArgs),
    /// Track async operations
    #[command(subcommand)]
    Operation(OperationCmd),
    /// Check and manage capabilities (grants gate YOUR side: message.send =
    /// you may send to the subject, message.receive = you may receive from them)
    #[command(subcommand)]
    Access(AccessCmd),
    /// Store stdin/FILE as a blob; prints the BlobTicket
    Put(PutArgs),
    /// Fetch a ticket to stdout or --out FILE (blob tickets fetch bytes,
    /// iroh-live: tickets capture live audio)
    Get(GetArgs),
}

#[derive(Subcommand)]
enum IdentityCmd {
    /// List identities
    List,
    /// Switch the active identity
    Use { name: String },
    /// Create an identity
    Create { name: String },
    /// Delete an identity
    Delete { name: String },
}

#[derive(Subcommand)]
enum PeerCmd {
    /// List peers
    List,
    /// Add a peer
    Add {
        #[arg(value_name = "REF")]
        peer_ref: String,
        #[arg(long)]
        name: Option<String>,
        #[arg(long = "endpoint-id")]
        endpoint_id: Option<String>,
        #[arg(long = "endpoint-addr")]
        endpoint_addr: Option<String>,
        /// Incoming-call surface for this connection: bar | call_kit
        #[arg(long = "call-mode", value_name = "MODE")]
        call_mode: Option<String>,
    },
    /// Update a peer
    Update {
        #[arg(value_name = "REF")]
        peer_ref: String,
        #[arg(long)]
        name: Option<String>,
        #[arg(long = "endpoint-id")]
        endpoint_id: Option<String>,
        #[arg(long = "endpoint-addr")]
        endpoint_addr: Option<String>,
        /// Incoming-call surface for this connection: bar | call_kit
        #[arg(long = "call-mode", value_name = "MODE")]
        call_mode: Option<String>,
    },
    /// Remove a peer
    Remove {
        #[arg(value_name = "REF")]
        peer_ref: String,
    },
    /// Resolve a peer reference to live connection info
    Resolve {
        #[arg(value_name = "REF")]
        peer_ref: String,
    },
    /// Show peer details
    Show {
        #[arg(value_name = "REF")]
        peer_ref: String,
    },
    /// Show peer connectivity status
    Status {
        #[arg(value_name = "REF")]
        peer_ref: String,
    },
}

#[derive(clap::Args)]
struct SendArgs {
    /// Dial target. Present = 1:1 session-scoped stream / peer-directed push;
    /// absent = broadcast publish (only valid with --stream)
    #[arg(value_name = "PEER")]
    peer: Option<String>,
    /// Text to send (chat path; requires PEER; pass --idempotency-key to
    /// dedupe deliberate resends)
    #[arg(long)]
    text: Option<String>,
    /// Send FILE (or stdin) as a signaled blob transfer (requires PEER); prints the BlobTicket on delivery
    #[arg(long, value_name = "FILE", num_args = 0..=1, default_missing_value = "-")]
    file: Option<String>,
    /// Stream FILE (or stdin) as live audio: with PEER a 1:1 session (blocks
    /// until they hang up), without PEER a broadcast printing the live ticket
    #[arg(long)]
    stream: bool,
    /// Stream mode only (broadcast only): publish video with an adaptive
    /// rendition ladder instead of audio
    #[arg(long, conflicts_with_all = ["text", "loop_playback"])]
    video: bool,
    /// Stream mode only: list running live publishers
    #[arg(long, conflicts_with_all = ["peer", "text", "file", "stop", "name", "loop_playback"])]
    list: bool,
    /// Stream mode only: gracefully stop a live publisher by id
    #[arg(long, conflicts_with_all = ["peer", "text", "file", "list", "name", "loop_playback"])]
    stop: Option<String>,
    /// Stream mode only: give up if the peer never hangs up (seconds)
    #[arg(long)]
    seconds: Option<u64>,
    /// Stream mode only: repeat the source indefinitely (broadcast only)
    #[arg(long = "loop")]
    loop_playback: bool,
    /// Stream mode only: forbid relayed connections
    #[arg(long = "no-relay")]
    no_relay: bool,
    /// Stream mode only: stable broadcast name
    #[arg(long)]
    name: Option<String>,
    #[arg(long = "idempotency-key")]
    idempotency_key: Option<String>,
    #[arg(long = "capability-ticket")]
    capability_ticket: Option<Value>,
    #[arg(long)]
    retries: Option<u64>,
}

#[derive(clap::Args)]
struct RecvArgs {
    /// Receive a 1:1 live stream instead of a signaled data transfer
    #[arg(long)]
    stream: bool,
    #[arg(long)]
    from: Option<String>,
    #[arg(long)]
    out: Option<String>,
    #[arg(long = "timeout-ms")]
    timeout_ms: Option<u64>,
    /// Stream mode only: capture window (seconds)
    #[arg(long)]
    seconds: Option<u64>,
    /// Stream mode only: give up if no one calls within this many seconds
    #[arg(long)]
    wait: Option<u64>,
    /// Stream mode only: record encoded video (Annex B .h264) instead of audio
    #[arg(long)]
    video: bool,
    /// Stream mode only: rendition quality (low, mid, high, highest)
    #[arg(long)]
    quality: Option<String>,
    /// Stream mode only: forbid relayed connections
    #[arg(long = "no-relay")]
    no_relay: bool,
}

#[derive(clap::Args)]
struct EventsArgs {
    #[arg(long)]
    follow: bool,
    #[arg(long)]
    after: Option<String>,
    #[arg(long = "type")]
    event_type: Option<String>,
}

#[derive(clap::Args)]
struct WaitArgs {
    #[arg(long = "type")]
    event_type: Option<String>,
    #[arg(long)]
    after: Option<String>,
    #[arg(long = "timeout-ms")]
    timeout_ms: Option<u64>,
}

#[derive(Subcommand)]
enum OperationCmd {
    /// Fetch operation state
    Get {
        operation_id: String,
        #[arg(long = "timeout-ms")]
        timeout_ms: Option<u64>,
    },
    /// Poll an operation until it reaches a terminal state
    Wait {
        operation_id: String,
        #[arg(long = "timeout-ms")]
        timeout_ms: Option<u64>,
    },
    /// Cancel an operation
    Cancel { operation_id: String },
}

#[derive(Subcommand)]
enum AccessCmd {
    /// Check whether a capability is granted
    Check {
        #[arg(long)]
        subject: Option<String>,
        #[arg(long)]
        capability: Option<String>,
    },
    /// Allow yourself to exchange messages with a peer (stored on your
    /// daemon; gates your own send/receive, not the peer's)
    Allow {
        #[arg(long)]
        subject: String,
        #[arg(long)]
        capability: String,
    },
    /// Mint a capability ticket for a peer
    Ticket(TicketArgs),
}

#[derive(clap::Args)]
struct TicketArgs {
    #[arg(long)]
    subject: String,
    #[arg(long)]
    capability: Option<String>,
    #[arg(long = "expires-at")]
    expires_at: Option<String>,
}

#[derive(clap::Args)]
struct PutArgs {
    /// Read from FILE instead of stdin
    #[arg(long)]
    file: Option<String>,
    #[arg(long = "resource-id")]
    resource_id: Option<String>,
    /// Mime type to tag the resource with (inferred from the file extension
    /// when omitted, e.g. video/mp4 for .mp4)
    #[arg(long)]
    mime: Option<String>,
}

#[derive(clap::Args)]
struct GetArgs {
    ticket: String,
    #[arg(long)]
    out: Option<String>,
    /// Live tickets only: cap the capture window (seconds)
    #[arg(long)]
    seconds: Option<u64>,
    /// Live tickets only: record encoded video (Annex B .h264) instead of audio
    #[arg(long)]
    video: bool,
    /// Video only: rendition quality (low, mid, high, highest)
    #[arg(long)]
    quality: Option<String>,
    /// Live tickets only: forbid relayed connections
    #[arg(long = "no-relay")]
    no_relay: bool,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("idfon: {error}");
        std::process::exit(1);
    }
}

fn run() -> io::Result<()> {
    let cli = Cli::parse();
    KEEP_ALIVE.set(cli.keep_alive).expect("run called once");
    let socket: &str = cli.socket.as_deref().unwrap_or(DEFAULT_SOCKET);
    let identity = cli.identity.as_deref();
    let json = cli.json;

    match cli.command {
        Command::Shutdown => {
            // No auto-start here: shutting down a daemon we just spawned is a no-op.
            let mut client = Client::connect(socket).map_err(|_| {
                io::Error::new(io::ErrorKind::NotFound, "daemon is not running")
            })?;
            let request = Request {
                version: PROTOCOL_VERSION,
                id: "cli-shutdown".into(),
                method: "daemon.shutdown".into(),
                params: json!({}),
            };
            let response = client
                .request(&encode_json(&request).map_err(io::Error::other)?)
                .map_err(io::Error::other)?
                .json()
                .map_err(io::Error::other)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&response).map_err(io::Error::other)?);
            } else {
                println!("daemon stopped");
            }
            Ok(())
        }
        Command::Put(args) => cmd_put(
            socket,
            args.file.as_ref(),
            args.resource_id,
            args.mime.as_ref(),
            json,
            identity,
        ),
        Command::Get(args) => {
            // Tickets are self-describing: live tickets carry an "iroh-live:"
            // scheme prefix, blob tickets start with "blob".
            if args.ticket.starts_with("iroh-live:") {
                cmd_listen(
                    socket,
                    &args.ticket,
                    args.out.as_ref(),
                    args.seconds,
                    args.video,
                    args.quality.as_deref(),
                    !args.no_relay,
                    json,
                    identity,
                )
            } else {
                cmd_get(socket, &args.ticket, args.out.as_ref(), identity)
            }
        }
        Command::Recv(args) => {
            if args.stream {
                cmd_answer(
                    socket,
                    args.out.as_ref(),
                    args.seconds,
                    args.wait,
                    args.from.as_deref(),
                    args.video,
                    args.quality.as_deref(),
                    !args.no_relay,
                    json,
                    identity,
                )
            } else {
                cmd_recv(
                    socket,
                    args.out.as_ref(),
                    args.from.as_deref(),
                    args.timeout_ms,
                    identity,
                )
            }
        }
        Command::Events(args) => {
            cmd_events(socket, args.follow, args.after, args.event_type, json, identity)
        }
        Command::Wait(args) => {
            let response = send_rpc(
                socket,
                "wait",
                json!({"follow": false, "after": args.after, "type": args.event_type, "timeout_ms": args.timeout_ms}),
                identity,
                cli.stdin_json,
            )?;
            finish(response, json)
        }
        Command::Operation(OperationCmd::Wait {
            operation_id,
            timeout_ms,
        }) => {
            let mut params =
                json!({"operation_id": operation_id, "timeout_ms": timeout_ms});
            inject_identity(&mut params, identity);
            let request = Request {
                version: PROTOCOL_VERSION,
                id: "cli-1".into(),
                method: "operation.wait".into(),
                params,
            };
            let mut client = connect_or_start_daemon(socket)?;
            let payload = encode_json(&request).map_err(io::Error::other)?;
            let mut response = read_json(&mut client, &payload)?;
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
            finish(response, json)
        }
        Command::Status => {
            finish(send_rpc(socket, "status", json!({}), identity, cli.stdin_json)?, json)
        }
        Command::Identity(IdentityCmd::List) => {
            finish(send_rpc(socket, "identities", json!({}), identity, cli.stdin_json)?, json)
        }
        Command::Identity(IdentityCmd::Use { name }) => finish(
            send_rpc(socket, "identity.use", json!({"name": name}), identity, cli.stdin_json)?,
            json,
        ),
        Command::Identity(IdentityCmd::Create { name }) => finish(
            send_rpc(socket, "identity.create", json!({"name": name}), identity, cli.stdin_json)?,
            json,
        ),
        Command::Identity(IdentityCmd::Delete { name }) => finish(
            send_rpc(socket, "identity.delete", json!({"name": name}), identity, cli.stdin_json)?,
            json,
        ),
        Command::Peer(PeerCmd::List) => {
            finish(send_rpc(socket, "peers", json!({}), identity, cli.stdin_json)?, json)
        }
        Command::Peer(PeerCmd::Add {
            peer_ref,
            name,
            endpoint_id,
            endpoint_addr,
            call_mode,
        }) => finish(
            send_rpc(
                socket,
                "peer.add",
                json!({"ref": peer_ref, "id": peer_ref, "name": name, "endpoint_id": endpoint_id, "endpoint_addr": endpoint_addr, "aliases": [], "call_mode": call_mode}),
                identity,
                cli.stdin_json,
            )?,
            json,
        ),
        Command::Peer(PeerCmd::Update {
            peer_ref,
            name,
            endpoint_id,
            endpoint_addr,
            call_mode,
        }) => finish(
            send_rpc(
                socket,
                "peer.update",
                json!({"ref": peer_ref, "id": peer_ref, "name": name, "endpoint_id": endpoint_id, "endpoint_addr": endpoint_addr, "aliases": [], "call_mode": call_mode}),
                identity,
                cli.stdin_json,
            )?,
            json,
        ),
        Command::Peer(PeerCmd::Remove { peer_ref }) => finish(
            send_rpc(socket, "peer.remove", json!({"ref": peer_ref}), identity, cli.stdin_json)?,
            json,
        ),
        Command::Peer(PeerCmd::Resolve { peer_ref }) => finish(
            send_rpc(socket, "peer.resolve", json!({"ref": peer_ref}), identity, cli.stdin_json)?,
            json,
        ),
        Command::Peer(PeerCmd::Show { peer_ref }) => finish(
            send_rpc(socket, "peer.show", json!({"ref": peer_ref}), identity, cli.stdin_json)?,
            json,
        ),
        Command::Peer(PeerCmd::Status { peer_ref }) => finish(
            send_rpc(socket, "peer.status", json!({"ref": peer_ref}), identity, cli.stdin_json)?,
            json,
        ),
        Command::Send(args) => {
            if args.stream {
                match (args.peer.as_deref(), args.list, args.stop.as_deref()) {
                    (Some(peer), false, None) => {
                        // 1:1 session-scoped stream to the peer; blocks until
                        // they hang up (or --seconds). No ticket exists.
                        let file = resolve_stream_file(args.file.as_ref())?;
                        let mut params = json!({"to": peer, "file": file, "video": args.video, "relay": !args.no_relay});
                        if let Some(seconds) = args.seconds {
                            params["seconds"] = seconds.into();
                        }
                        let response = ipc(socket, "media.live.dial", params, identity)?;
                        if !response.ok {
                            return Err(io::Error::other(request_error(&response)));
                        }
                        if json {
                            println!(
                                "{}",
                                serde_json::to_string(&response).map_err(io::Error::other)?
                            );
                        } else {
                            let held = result_str(&response, "held_ms");
                            println!("streamed to {peer} for {held} ms");
                        }
                        Ok(())
                    }
                    (None, true, _) => finish(
                        send_rpc(
                            socket,
                            "media.live.publishers",
                            json!({}),
                            identity,
                            cli.stdin_json,
                        )?,
                        json,
                    ),
                    (None, false, Some(id)) => {
                        let response = ipc(socket, "media.live.stop", json!({"id": id}), identity)?;
                        if !response.ok {
                            return Err(io::Error::other(request_error(&response)));
                        }
                        if json {
                            println!(
                                "{}",
                                serde_json::to_string(&response).map_err(io::Error::other)?
                            );
                        } else {
                            println!("stopped {}", result_str(&response, "id"));
                        }
                        Ok(())
                    }
                    (None, false, None) => {
                        // Broadcast publish: prints the live ticket.
                        if args.video {
                            let file = resolve_stream_file(args.file.as_ref())?;
                            let mut params = json!({"file": file, "video": true, "relay": !args.no_relay});
                            if let Some(name) = args.name.as_deref() {
                                params["name"] = name.into();
                            }
                            let response = ipc(socket, "media.live.publish", params, identity)?;
                            if !response.ok {
                                return Err(io::Error::other(request_error(&response)));
                            }
                            if json {
                                println!("{}", serde_json::to_string(&response).map_err(io::Error::other)?);
                                return Ok(());
                            }
                            println!("{}", result_str(&response, "ticket"));
                            return Ok(());
                        }
                        let file = resolve_stream_file(args.file.as_ref())?;
                        let mut params =
                            json!({"file": file, "loop": args.loop_playback, "relay": !args.no_relay});
                        if let Some(name) = args.name.as_deref() {
                            params["name"] = name.into();
                        }
                        let response = ipc(socket, "media.live.publish", params, identity)?;
                        if !response.ok {
                            return Err(io::Error::other(request_error(&response)));
                        }
                        if json {
                            println!(
                                "{}",
                                serde_json::to_string(&response).map_err(io::Error::other)?
                            );
                            return Ok(());
                        }
                        println!("{}", result_str(&response, "ticket"));
                        Ok(())
                    }
                    _ => Err(io::Error::other(
                        "--list/--stop cannot be combined with a PEER",
                    )),
                }
            } else {
                let Some(peer) = args.peer.as_deref() else {
                    return Err(io::Error::other(
                        "PEER required without --stream (broadcast publish is send --stream)",
                    ));
                };
                send_payload(socket, cli.stdin_json, &args, peer, json, identity)
            }
        }
        Command::Operation(OperationCmd::Get {
            operation_id,
            timeout_ms,
        }) => finish(
            send_rpc(
                socket,
                "operation.get",
                json!({"operation_id": operation_id, "timeout_ms": timeout_ms}),
                identity,
                cli.stdin_json,
            )?,
            json,
        ),
        Command::Operation(OperationCmd::Cancel { operation_id }) => finish(
            send_rpc(
                socket,
                "operation.cancel",
                json!({"operation_id": operation_id}),
                identity,
                cli.stdin_json,
            )?,
            json,
        ),
        Command::Access(AccessCmd::Check { subject, capability }) => finish(
            send_rpc(
                socket,
                "access.check",
                json!({"subject": subject, "capability": capability}),
                identity,
                cli.stdin_json,
            )?,
            json,
        ),
        Command::Access(AccessCmd::Allow { subject, capability }) => finish(
            send_rpc(
                socket,
                "access.grant",
                json!({"subject": subject, "capability": capability}),
                identity,
                cli.stdin_json,
            )?,
            json,
        ),
        Command::Access(AccessCmd::Ticket(args)) => {
            let params = json!({
                "subject": args.subject,
                "capabilities": [args.capability.clone().unwrap_or_else(|| "message.receive".into())],
                "expires_at": args.expires_at,
            });
            let response = send_rpc(socket, "capability.ticket", params, identity, cli.stdin_json)?;
            if !json {
                let ticket = match &response.body {
                    ResponseBody::Success { result, .. } => {
                        result.get("ticket").cloned().unwrap_or_default()
                    }
                    _ => Value::Null,
                };
                println!(
                    "{}",
                    serde_json::to_string(&ticket).map_err(io::Error::other)?
                );
                return Ok(());
            }
            finish(response, json)
        }
    }
}

/// Prints the response (JSON envelope with `--json`, human text otherwise)
/// and maps `ok: false` onto a non-zero exit.
fn finish(response: Response, json: bool) -> io::Result<()> {
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

fn inject_identity(params: &mut Value, identity: Option<&str>) {
    if let Some(identity) = identity {
        if let Some(params) = params.as_object_mut() {
            params.entry("identity").or_insert(Value::String(identity.into()));
        }
    }
}

/// One generic RPC round trip with identity injection and the `--stdin-json`
/// params escape hatch. Returns the validated protocol `Response`.
fn send_rpc(
    socket: &str,
    method: &str,
    mut params: Value,
    identity: Option<&str>,
    stdin_json: bool,
) -> io::Result<Response> {
    if stdin_json {
        params = serde_json::from_reader(std::io::stdin()).map_err(io::Error::other)?;
    }
    inject_identity(&mut params, identity);
    let request = Request {
        version: PROTOCOL_VERSION,
        id: "cli-1".into(),
        method: method.into(),
        params,
    };
    let mut client = connect_or_start_daemon(socket)?;
    read_json(&mut client, &encode_json(&request).map_err(io::Error::other)?)
}

fn cmd_events(
    socket: &str,
    follow: bool,
    after: Option<String>,
    event_type: Option<String>,
    json: bool,
    identity: Option<&str>,
) -> io::Result<()> {
    let mut params = json!({"follow": follow, "after": after, "type": event_type});
    inject_identity(&mut params, identity);
    let request = Request {
        version: PROTOCOL_VERSION,
        id: "cli-1".into(),
        method: "events".into(),
        params,
    };
    let mut client = connect_or_start_daemon(socket)?;
    let payload = encode_json(&request).map_err(io::Error::other)?;
    let mut response = read_json(&mut client, &payload)?;
    if follow {
        loop {
            print_events(&response)?;
            response = client
                .next_response()
                .map_err(io::Error::other)?
                .json()
                .map_err(io::Error::other)?;
        }
    }
    finish(response, json)
}

fn read_json(client: &mut Client, payload: &[u8]) -> io::Result<Response> {
    client
        .request(payload)
        .map_err(io::Error::other)?
        .json()
        .map_err(io::Error::other)
}

fn print_events(response: &Response) -> io::Result<()> {
    if let idfon_protocol::ResponseBody::Success { result, .. } = &response.body {
        if let Some(events) = result.get("events").and_then(Value::as_array) {
            for event in events {
                println!("{}", serde_json::to_string(event).map_err(io::Error::other)?);
            }
        }
    }
    Ok(())
}

fn print_human(response: &Response) {
    match &response.body {
        idfon_protocol::ResponseBody::Success { result, .. } => {
            if response.id == "cli-1" {
                if let Some(ready) = result.get("ready").and_then(serde_json::Value::as_bool) {
                    let identity = result
                        .get("identity")
                        .and_then(|identity| identity.get("name"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("none");
                    println!(
                        "{}: {}, identity: {}",
                        response.id,
                        if ready { "ready" } else { "not ready" },
                        identity
                    );
                } else {
                    println!("{}", result);
                }
            }
        }
        idfon_protocol::ResponseBody::Failure { error, .. } => {
            eprintln!("{:?}: {}", error.code, error.message);
        }
    }
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

/// Connects to the daemon, auto-starting idfond if nothing is listening.
/// The daemon is left running after the CLI exits (dockerd-style shared
/// daemon, not one daemon per command), but shuts itself down after
/// DAEMON_IDLE_EXIT_SECS with no connected clients; the next command
/// restarts it. IDFON_IDLE_EXIT_SECS=0 disables the idle exit.
fn connect_or_start_daemon(socket: &str) -> io::Result<Client> {
    match Client::connect(socket) {
        Ok(client) => Ok(client),
        Err(ClientError::Connect(_)) => {
            match find_daemon_binary() {
                Some(daemon) => {
                    let data_dir = Path::new(socket)
                        .parent()
                        .map(|dir| dir.to_path_buf())
                        .unwrap_or_default();
                    // Two attempts: a just-killed daemon may still be dying
                    // (lock/socket still held), so the first spawn can lose.
                    let mut last_error = None;
                    for _ in 0..2 {
                        let spawned = StdCommand::new(&daemon)
                            .args([
                                "--socket",
                                socket,
                                "--data-dir",
                                &data_dir.to_string_lossy(),
                            ])
                            .env(
                                "IDFON_IDLE_EXIT_SECS",
                                if *KEEP_ALIVE.get().unwrap_or(&false) {
                                    "0".to_string()
                                } else {
                                    std::env::var("IDFON_IDLE_EXIT_SECS")
                                        .unwrap_or_else(|_| DAEMON_IDLE_EXIT_SECS.into())
                                },
                            )
                            .stdin(Stdio::null())
                            .stdout(Stdio::null())
                            .stderr(Stdio::null())
                            .spawn();
                        match spawned {
                            Err(error) => {
                                return Err(io::Error::other(format!(
                                    "failed to start daemon at {}: {error}",
                                    daemon.display()
                                )));
                            }
                            Ok(_) => match Client::connect_with_retry(socket, DAEMON_START_TIMEOUT)
                            {
                                Ok(client) => return Ok(client),
                                Err(error) => last_error = Some(error),
                            },
                        }
                    }
                    Err(io::Error::other(format!(
                        "daemon unavailable; tried to start idfond automatically: {}",
                        last_error.expect("at least one connect attempt")
                    )))
                }
                None => Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "daemon unavailable and idfond not found (install it or add it to PATH)",
                )),
            }
        }
        other => other.map_err(|error| io::Error::other(error.to_string())),
    }
}

fn ipc(
    socket: &str,
    method: &str,
    mut params: Value,
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
    let mut client = connect_or_start_daemon(socket)?;
    client
        .request(&encode_json(&request).map_err(io::Error::other)?)
        .map_err(io::Error::other)?
        .json()
        .map_err(io::Error::other)
}

/// Infers a mime type from the file extension for common audio/video types.
fn guess_mime(path: &str) -> Option<String> {
    let ext = std::path::Path::new(path)
        .extension()?
        .to_str()?
        .to_ascii_lowercase();
    Some(match ext.as_str() {
        "mp4" | "m4v" | "cmfv" => "video/mp4",
        "webm" => "video/webm",
        "mkv" => "video/x-matroska",
        "mov" => "video/quicktime",
        "ts" | "m2ts" | "mts" => "video/mp2t",
        "avi" => "video/x-msvideo",
        "opus" => "audio/opus",
        "ogg" => "audio/ogg",
        "wav" => "audio/wav",
        "mp3" => "audio/mpeg",
        _ => return None,
    }
    .to_string())
}

fn response_bytes(result: &Value) -> io::Result<Vec<u8>> {
    result
        .get("bytes")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .map(|value| value.as_u64().unwrap_or(0) as u8)
                .collect::<Vec<u8>>()
        })
        .ok_or_else(|| io::Error::other("response missing bytes"))
}

/// Reads stdin/FILE and stores it with the daemon (chunked when larger than
/// one frame). Returns the final daemon response (finish/one-shot), whose
/// result carries `blob_ticket`, `size_bytes`, and `content_hash`.
fn put_data(
    socket: &str,
    file: Option<&String>,
    resource_id: Option<String>,
    mime: Option<&String>,
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
    let mime = mime
        .cloned()
        .or_else(|| file.and_then(|path| guess_mime(path)));
    let put = |chunk: &[u8], append: bool, finish: bool| {
        let mut params = json!({"resource_id": resource_id, "bytes": chunk, "append": append, "finish": finish});
        if let Some(ref mime) = mime {
            params["mime"] = mime.clone().into();
        }
        ipc(socket, "media.resource.put", params, identity)
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
    mime: Option<&String>,
    json: bool,
    identity: Option<&str>,
) -> io::Result<()> {
    let response = put_data(socket, file, resource_id, mime, identity)?;
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

/// `idfon get TICKET`: streams the blob to stdout (or --out FILE) in chunks.
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
            json!({"resource_id": resource_id, "blob_ticket": ticket, "offset": offset, "length": CHUNK}),
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

/// `idfon send-data PEER`: stores stdin/FILE as a blob, then signals the
/// ticket to the peer through the message path (IDFON-DATA/1 envelope).
/// Prints the bare BlobTicket once delivery is acknowledged.
/// Text and signaled-blob modes of `send` (PEER required).
fn send_payload(
    socket: &str,
    stdin_json: bool,
    args: &SendArgs,
    peer: &str,
    json: bool,
    identity: Option<&str>,
) -> io::Result<()> {
    if let Some(file) = &args.file {
        let file = if file == "-" { None } else { Some(file) };
        cmd_send_data(socket, peer, file, args.retries, json, identity)
    } else {
        // Per-invocation key by default: unique across the daemon's
        // persisted operations, so retries (handled within one
        // operation) stay exactly-once. Pass --idempotency-key only
        // for deliberate cross-invocation dedup of the same message.
        let key = args.idempotency_key.clone().unwrap_or_else(|| {
            format!(
                "idfon-text-{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .expect("clock before epoch")
                    .as_nanos()
            )
        });
        finish(
            send_rpc(
                socket,
                "message.send",
                json!({"to": peer, "text": args.text, "idempotency_key": key, "capability_ticket": args.capability_ticket, "retries": args.retries}),
                identity,
                stdin_json,
            )?,
            json,
        )
    }
}

fn cmd_send_data(
    socket: &str,
    peer: &str,
    file: Option<&String>,
    retries: Option<u64>,
    json: bool,
    identity: Option<&str>,
) -> io::Result<()> {
    let response = put_data(socket, file, None, None, identity)?;
    let ticket = result_str(&response, "blob_ticket");
    let size = result_usize(&response, "size_bytes");
    let text = format!("IDFON-DATA/1\nticket={ticket}\nsize={size}");
    // The ticket is content-addressed, so this key is stable across retries
    // with the same content and unique across different content.
    let idempotency_key = format!("idfon-data-{ticket}");
    let response = ipc(
        socket,
        "message.send",
        json!({"to": peer, "text": text, "idempotency_key": idempotency_key, "retries": retries}),
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
            json!({"operation_id": operation_id}),
            identity,
        )?;
        let status = match &response.body {
            ResponseBody::Success { result, .. } => result
                .get("operation")
                .and_then(|operation| operation.get("status"))
                .and_then(Value::as_str)
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

/// Parses a IDFON-DATA/1 envelope into (blob ticket, declared size).
fn parse_data_envelope(text: &str) -> Option<(String, Option<usize>)> {
    let mut ticket = None;
    let mut size = None;
    for line in text.strip_prefix("IDFON-DATA/1\n")?.lines() {
        let (key, value) = line.split_once('=')?;
        match key {
            "ticket" => ticket = Some(value.to_string()),
            "size" => size = value.parse().ok(),
            _ => {}
        }
    }
    Some((ticket?, size))
}

/// `idfon recv`: waits for a IDFON-DATA/1 message through the daemon's event
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
        json!({"type": "message.received"}),
        identity,
    ) {
        if let ResponseBody::Success { result, .. } = &response.body {
            cursor = result
                .get("events")
                .and_then(Value::as_array)
                .and_then(|events| events.last())
                .and_then(|event| event.get("cursor"))
                .and_then(Value::as_str)
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
            json!({"type": "message.received", "after": cursor, "timeout_ms": wait_ms}),
            identity,
        )?;
        if !response.ok {
            return Err(io::Error::other(request_error(&response)));
        }
        let events = match &response.body {
            ResponseBody::Success { result, .. } => result
                .get("events")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
            _ => Vec::new(),
        };
        if let Some(next) = events
            .last()
            .and_then(|event| event.get("cursor"))
            .and_then(Value::as_str)
        {
            cursor = Some(next.to_string());
        }
        for event in &events {
            let data = &event["data"];
            if let Some(sender) = from {
                if data.get("peer_id").and_then(Value::as_str) != Some(sender) {
                    continue;
                }
            }
            let text = data
                .get("text")
                .and_then(Value::as_str)
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
                data.get("peer_id").and_then(Value::as_str).unwrap_or("?")
            );
            return Ok(());
        }
    }
}

/// `idfon stream`: publishes FILE (or stdin, spooled to a temp file) as a
/// live iroh broadcast through the daemon. Prints the bare live ticket.
/// Resolves --file to a daemon-readable path; stdin (None or "-") is spooled
/// to a temp file because the daemon opens the path itself. Returns the path
/// string and the temp path to keep alive for the call.
fn spool_stdin() -> io::Result<std::path::PathBuf> {
    let path = std::env::temp_dir().join(format!(
        "idfon-stream-{}.wav",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock before epoch")
            .as_nanos()
    ));
    let mut data = Vec::new();
    std::io::Read::read_to_end(&mut std::io::stdin(), &mut data)?;
    std::fs::write(&path, data)?;
    Ok(path)
}

/// Resolves --file to a daemon-readable path; stdin (None or "-") is spooled
/// to a temp file because the daemon opens the path itself.
fn resolve_stream_file(file: Option<&String>) -> io::Result<String> {
    match file {
        None => {
            let path = spool_stdin()?;
            path.to_str()
                .map(str::to_string)
                .ok_or_else(|| io::Error::other("temp path not utf-8"))
        }
        Some(path) if path == "-" => {
            let path = spool_stdin()?;
            path.to_str()
                .map(str::to_string)
                .ok_or_else(|| io::Error::other("temp path not utf-8"))
        }
        Some(path) => Ok(path.clone()),
    }
}

/// `idfon listen TICKET`: records a remote live broadcast for --seconds
/// (default 15) into --out (default: a temp file copied to stdout). With
/// --video, records the selected rendition's encoded H.264 (Annex B).
#[allow(clippy::too_many_arguments)]
fn cmd_listen(
    socket: &str,
    ticket: &str,
    out: Option<&String>,
    seconds: Option<u64>,
    video: bool,
    quality: Option<&str>,
    relay: bool,
    json: bool,
    identity: Option<&str>,
) -> io::Result<()> {
    let ext = if video { "h264" } else { "wav" };
    let mut params = json!({"ticket": ticket, "relay": relay, "video": video});
    if let Some(seconds) = seconds {
        params["seconds"] = seconds.into();
    }
    if let Some(quality) = quality {
        params["quality"] = quality.into();
    }
    let temp;
    if let Some(path) = out {
        params["out"] = path.clone().into();
    } else {
        temp = std::env::temp_dir().join(format!(
            "idfon-listen-{}.{ext}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock before epoch")
                .as_nanos()
        ));
        params["out"] = temp.display().to_string().into();
    }
    let response = ipc(socket, "media.live.subscribe", params, identity)?;
    if !response.ok {
        return Err(io::Error::other(request_error(&response)));
    }
    let written_path = match &response.body {
        ResponseBody::Success { result, .. } => result
            .get("out")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        _ => return Err(io::Error::other("unexpected response")),
    };
    if out.is_none() {
        std::io::copy(
            &mut std::fs::File::open(&written_path)?,
            &mut std::io::stdout().lock(),
        )?;
        let _ = std::fs::remove_file(&written_path);
    }
    if json {
        println!(
            "{}",
            serde_json::to_string(&response).map_err(io::Error::other)?
        );
    } else if video {
        eprintln!(
            "listen: wrote {} ({} frames, {} ms)",
            written_path,
            result_str(&response, "frames"),
            result_str(&response, "duration_ms"),
        );
    } else {
        eprintln!("listen: wrote {} ({})", written_path, result_str(&response, "duration_ms") + " ms audio");
    }
    Ok(())
}

/// `idfon answer`: waits for an inbound 1:1 call and records it to --out
/// (default: a temp file copied to stdout). With --video, records the
/// selected rendition's encoded H.264 (Annex B).
fn cmd_answer(
    socket: &str,
    out: Option<&String>,
    seconds: Option<u64>,
    wait: Option<u64>,
    from: Option<&str>,
    video: bool,
    quality: Option<&str>,
    relay: bool,
    json: bool,
    identity: Option<&str>,
) -> io::Result<()> {
    let ext = if video { "h264" } else { "wav" };
    let mut params = json!({"relay": relay, "video": video});
    if let Some(quality) = quality {
        params["quality"] = quality.into();
    }
    if let Some(seconds) = seconds {
        params["seconds"] = seconds.into();
    }
    if let Some(wait) = wait {
        params["wait"] = wait.into();
    }
    if let Some(from) = from {
        params["from"] = from.into();
    }
    let temp;
    if let Some(path) = out {
        params["out"] = path.clone().into();
    } else {
        temp = std::env::temp_dir().join(format!(
            "idfon-answer-{}.{ext}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock before epoch")
                .as_nanos()
        ));
        params["out"] = temp.display().to_string().into();
    }
    let response = ipc(socket, "media.live.answer", params, identity)?;
    if !response.ok {
        return Err(io::Error::other(request_error(&response)));
    }
    let written_path = match &response.body {
        ResponseBody::Success { result, .. } => result
            .get("out")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        _ => return Err(io::Error::other("unexpected response")),
    };
    if out.is_none() {
        std::io::copy(
            &mut std::fs::File::open(&written_path)?,
            &mut std::io::stdout().lock(),
        )?;
        let _ = std::fs::remove_file(&written_path);
    }
    if json {
        println!(
            "{}",
            serde_json::to_string(&response).map_err(io::Error::other)?
        );
    } else {
        eprintln!(
            "answer: wrote {} ({})",
            written_path,
            result_str(&response, "duration_ms") + " ms audio"
        );
    }
    Ok(())
}

