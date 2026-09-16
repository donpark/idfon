//! `idfon-mcp` — milestone-1 MCP transport bridge.
//!
//! Splices newline-delimited JSON-RPC between a local stdio MCP peer and an
//! iroh bi-stream speaking `idfon/mcp/1`. The stream profile is a pure byte
//! pump: it never parses MCP, never re-frames, and never rewrites JSON.

use std::{path::Path, process::Stdio};

use anyhow::{anyhow, Context, Result};
use clap::{Parser, Subcommand};
use idfon_core::transport::{pump, IrohTransport, TransportError};
use idfon_protocol::{McpContactTicket, McpDiscover, McpPeer};
use iroh::{endpoint::Connection, EndpointAddr, EndpointId};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Command,
};

const MCP_ALPN: &[u8] = b"idfon/mcp/1";

#[derive(Parser)]
#[command(
    name = "idfon-mcp",
    about = "MCP over iroh transport bridge (idfon/mcp/1)"
)]
struct Cli {
    /// Hex Ed25519 key (64 hex chars). `IDFON_MCP_KEY` is used if unset.
    #[arg(long, global = true, value_name = "FILE")]
    key_file: Option<std::path::PathBuf>,
    #[command(subcommand)]
    mode: Mode,
}

#[derive(Subcommand)]
enum Mode {
    /// Accept inbound `idfon/mcp/1` streams, splicing each to a local MCP server.
    Serve {
        /// Local MCP server command line (run through `sh -c`).
        #[arg(long = "command", value_name = "CMD")]
        mcp_command: String,
        /// Print an M3 contact ticket (transport + peer + a probed
        /// server/discover cache) instead of the bare endpoint ticket.
        #[arg(long)]
        contact: bool,
        /// Stable account/virtual ID to include in the contact ticket.
        #[arg(long = "account-id")]
        account_id: String,
    },
    /// Dial a peer and splice the bi-stream to this process's stdio.
    Connect {
        /// Peer ticket (JSON `EndpointAddr`) or bare endpoint id.
        #[arg(long, value_name = "TICKET|ID", conflicts_with = "uds")]
        peer: Option<String>,
        /// Local socket opened by `idfon mcp listen` (stdio ↔ daemon shim).
        #[arg(long, value_name = "PATH")]
        uds: Option<std::path::PathBuf>,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let key = load_key(cli.key_file.as_deref())?;
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("build tokio runtime")?
        .block_on(async {
            match cli.mode {
                Mode::Serve {
                    mcp_command,
                    contact,
                    account_id,
                } => serve(key, mcp_command, contact, account_id).await,
                Mode::Connect { peer, uds } => connect(key, peer, uds).await,
            }
        })
}

/// Loads a stable key from `--key-file` or `IDFON_MCP_KEY`; generates an
/// ephemeral identity only when neither is set, and says so. The key is
/// provisioned into the sandbox, not daemon-owned, so a stable key is the
/// caller's responsibility.
fn load_key(key_file: Option<&Path>) -> Result<[u8; 32]> {
    let value = match key_file {
        Some(path) => Some(
            std::fs::read_to_string(path)
                .with_context(|| format!("read key file {}", path.display()))?,
        ),
        None => std::env::var("IDFON_MCP_KEY").ok(),
    };
    match value.filter(|value| !value.trim().is_empty()) {
        Some(value) => {
            let key = idfon_core::decode_signing_key(value.trim())
                .ok_or_else(|| anyhow!("invalid key: expected 64 hex characters"))?;
            Ok(idfon_core::signing_key_bytes(&key))
        }
        None => {
            eprintln!(
                "[idfon-mcp] WARNING: no --key-file or IDFON_MCP_KEY; using an ephemeral \
                 identity (grants will not survive a restart)"
            );
            Ok(idfon_core::signing_key_bytes(
                &idfon_core::generate_identity(),
            ))
        }
    }
}

async fn serve(
    key: [u8; 32],
    mcp_command: String,
    contact: bool,
    account_id: String,
) -> Result<()> {
    let transport = std::sync::Arc::new(
        IrohTransport::bind_with_key(Some(key))
            .await
            .context("bind iroh endpoint")?,
    );

    let (tx, mut rx) = tokio::sync::mpsc::channel(16);
    // Held for the process lifetime: dropping the guard unregisters the ALPN.
    let _side = transport.add_side_channel(MCP_ALPN, tx);

    // `add_side_channel` routes inbound connections only while the transport's
    // accept loop runs. M1 carries no idfon messages, so reject any that arrive.
    let accept_loop = std::sync::Arc::clone(&transport);
    tokio::spawn(async move {
        let result = accept_loop
            .serve(|_| async {
                Err::<_, TransportError>(TransportError::Failed(
                    "idfon-mcp carries only idfon/mcp/1".into(),
                ))
            })
            .await;
        if let Err(error) = result {
            eprintln!("[idfon-mcp] accept loop ended: {error}");
        }
    });

    // Give the endpoint a moment to publish relay/direct addresses so the
    // printed ticket is dialable; offline runs proceed with direct addrs.
    let _ = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        transport.endpoint().online(),
    )
    .await;
    let address = transport.endpoint().addr();
    // The bridge is the only place that parses JSON-RPC, and only for the
    // optional M3 discovery cache; everything else is a byte pump.
    let ticket = if contact {
        match probe_discover(&mcp_command).await {
            Ok(discover) => serde_json::to_string(&McpContactTicket {
                transport: serde_json::to_string(&address).unwrap_or_default(),
                peer: McpPeer {
                    account_id: account_id.clone(),
                    endpoint_id: address.id.to_string(),
                    name: None,
                },
                discover: Some(discover),
            })
            .context("serialize contact ticket")?,
            Err(error) => {
                eprintln!("[idfon-mcp] server/discover probe failed: {error:#}");
                serde_json::to_string(&address).context("serialize endpoint ticket")?
            }
        }
    } else {
        serde_json::to_string(&address).context("serialize endpoint ticket")?
    };
    println!("{ticket}");
    eprintln!("[idfon-mcp] serving as {}", transport.endpoint().id());

    while let Some(connection) = rx.recv().await {
        let command = mcp_command.clone();
        tokio::spawn(async move {
            if let Err(error) = serve_connection(connection, command).await {
                eprintln!("[idfon-mcp] connection ended: {error:#}");
            }
        });
    }
    Ok(())
}

/// One inbound bi-stream ↔ one freshly spawned MCP server. Stream-scoped
/// lifecycle: closing the stream terminates and reaps the child.
async fn serve_connection(connection: Connection, mcp_command: String) -> Result<()> {
    let (send, recv) = connection.accept_bi().await.context("accept bi-stream")?;
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(&mcp_command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .with_context(|| format!("spawn mcp command: {mcp_command}"))?;
    let child_stdin = child.stdin.take().expect("piped stdin");
    let child_stdout = child.stdout.take().expect("piped stdout");

    let mut up = tokio::spawn(pump(recv, child_stdin));
    let mut down = tokio::spawn(pump(child_stdout, send));
    tokio::select! {
        _ = &mut up => down.abort(),
        _ = &mut down => up.abort(),
    }
    let _ = child.start_kill();
    let _ = child.wait().await;
    connection.close(0u32.into(), b"mcp session closed");
    Ok(())
}

async fn connect(
    key: [u8; 32],
    peer: Option<String>,
    uds: Option<std::path::PathBuf>,
) -> Result<()> {
    // Daemon-relay shim: the daemon owns the peer stream and exposes a local
    // socket; this process only bridges stdio to it.
    if let Some(path) = uds {
        let stream = tokio::net::UnixStream::connect(&path)
            .await
            .with_context(|| format!("connect {}", path.display()))?;
        let (read, write) = stream.into_split();
        let (up, down) = tokio::join!(
            pump(tokio::io::stdin(), write),
            pump(read, tokio::io::stdout()),
        );
        up.context("stdin -> daemon")?;
        down.context("daemon -> stdout")?;
        return Ok(());
    }
    let peer = peer.ok_or_else(|| anyhow!("--peer or --uds is required"))?;
    let target = parse_peer(&peer)?;
    let transport = IrohTransport::bind_with_key(Some(key))
        .await
        .context("bind iroh endpoint")?;
    let (connection, send, recv) = transport
        .open_bi_stream(&target, MCP_ALPN)
        .await
        .with_context(|| format!("dial {} on idfon/mcp/1", target.id))?;

    // Both directions run until EOF; the MCP host closes stdin when done.
    let (up, down) = tokio::join!(
        pump(tokio::io::stdin(), send),
        pump(recv, tokio::io::stdout()),
    );
    up.context("stdin -> peer")?;
    down.context("peer -> stdout")?;
    connection.close(0u32.into(), b"client done");
    Ok(())
}

/// Spawns the local MCP server once and asks it for `server/discover`. This is
/// the one JSON-RPC message the bridge understands, and only to fill the M3
/// ticket cache; a failure just omits the cache.
async fn probe_discover(mcp_command: &str) -> Result<McpDiscover> {
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(mcp_command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("spawn mcp command: {mcp_command}"))?;
    let mut stdin = child.stdin.take().context("piped stdin")?;
    let stdout = child.stdout.take().context("piped stdout")?;
    // Every MCP 2026-07-28 request carries its version and client
    // capabilities in `_meta`; a strict server rejects a bare request.
    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "server/discover",
        "params": {"_meta": {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": {
                "name": "idfon-bridge",
                "version": env!("CARGO_PKG_VERSION"),
            },
            "io.modelcontextprotocol/clientCapabilities": {},
        }},
    });
    stdin.write_all(format!("{request}\n").as_bytes()).await?;
    stdin.flush().await?;
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    let read = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        reader.read_line(&mut line),
    )
    .await;
    let _ = child.start_kill();
    let _ = child.wait().await;
    read.map_err(|_| anyhow!("server/discover timed out"))??;
    let value: serde_json::Value =
        serde_json::from_str(line.trim()).context("parse server/discover")?;
    let result = value
        .get("result")
        .cloned()
        .unwrap_or(serde_json::Value::Null);
    let cached_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs().to_string())
        .unwrap_or_default();
    Ok(McpDiscover {
        supported_versions: result
            .get("supportedVersions")
            .and_then(|versions| versions.as_array())
            .map(|versions| {
                versions
                    .iter()
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default(),
        capabilities: result
            .get("capabilities")
            .cloned()
            .unwrap_or(serde_json::Value::Null),
        server_info: result
            .get("_meta")
            .and_then(|meta| meta.get("io.modelcontextprotocol/serverInfo"))
            .cloned()
            .unwrap_or(serde_json::Value::Null),
        ttl_ms: result.get("ttlMs").and_then(serde_json::Value::as_u64),
        cache_scope: result
            .get("cacheScope")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        cached_at,
    })
}

fn parse_peer(peer: &str) -> Result<EndpointAddr> {
    let peer = peer.trim();
    if peer.starts_with('{') {
        return serde_json::from_str(peer).context("parse peer ticket JSON");
    }
    let id: EndpointId = peer.parse().context("parse endpoint id")?;
    Ok(EndpointAddr::new(id))
}
