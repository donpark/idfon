//! User-side ALPN relay for the MCP transport binding (milestone 2).
//!
//! The daemon stays generic: it knows "ALPN `idfon/mcp/1` → spawn a configured
//! local command" and "peer bi-stream ↔ local Unix socket", and nothing else.
//! It never parses MCP, and the only MCP-shaped token here is the ALPN itself.
//!
//! - Inbound: a peer dials this daemon; if the peer's endpoint has been granted
//!   `mcp.transport`, the bi-stream is spliced to `IDFON_MCP_COMMAND`'s stdio.
//! - Outbound: `mcp.listen` opens a per-peer Unix socket that a local process
//!   (the `idfon-mcp connect --uds` shim) connects to; the daemon dials the
//!   peer and splices, after checking this daemon's own `mcp.transport` grant.

use std::{
    process::Stdio,
    sync::{Arc, Mutex},
};

use anyhow::{Context, Result};
use idfon_core::transport::{pump, IrohTransport, TransportManager};
use idfon_protocol::{Capability, ErrorCode, Request, Response};
use iroh::EndpointAddr;
use tokio::process::Command;

use crate::{error_response, has_grant, request_text, resolved_identity_id, success, Store, TransportMode};

pub const MCP_ALPN: &[u8] = b"idfon/mcp/1";

/// Registers the inbound relay on one identity's transport. Called once per
/// identity at daemon startup; the served command is resolved per connection
/// so `mcp.configure` takes effect without re-registering the ALPN.
pub async fn spawn_inbound(
    manager: Arc<TransportManager>,
    store: Arc<Mutex<Store>>,
    identity: String,
) {
    let Some(transport) = manager.current(&identity).await else {
        return;
    };
    let (tx, mut rx) = tokio::sync::mpsc::channel(16);
    let side = transport.add_side_channel(MCP_ALPN, tx);
    tokio::spawn(async move {
        // Held for the task's lifetime: dropping it unregisters the ALPN.
        let _side = side;
        while let Some(connection) = rx.recv().await {
            let store = Arc::clone(&store);
            let identity = identity.clone();
            tokio::spawn(async move {
                if let Err(error) = inbound(connection, &store, &identity).await {
                    eprintln!("[idfond] mcp inbound ended: {error:#}");
                }
            });
        }
    });
}

async fn inbound(
    connection: iroh::endpoint::Connection,
    store: &Arc<Mutex<Store>>,
    identity: &str,
) -> Result<()> {
    let remote = connection.remote_id().to_string();
    if !inbound_allowed(store, identity, &remote) {
        connection.close(1u32.into(), b"mcp.transport not granted");
        return Ok(());
    }
    let command = store.lock().expect("store mutex poisoned").configured_mcp_command();
    let Some(command) = command else {
        connection.close(2u32.into(), b"mcp server not configured");
        return Ok(());
    };
    let (send, recv) = connection.accept_bi().await.context("accept bi-stream")?;
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(&command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .with_context(|| format!("spawn local MCP server: {command}"))?;
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

/// Inbound authorization: map the remote endpoint id to a known peer's subject
/// (public key) and require `mcp.transport` for this identity.
fn inbound_allowed(store: &Arc<Mutex<Store>>, identity: &str, remote_endpoint_id: &str) -> bool {
    let state = store.lock().expect("store mutex poisoned");
    let subject = state
        .peers
        .iter()
        .find(|peer| peer.identity == identity && peer.knows_endpoint(remote_endpoint_id))
        .map(|peer| peer.id.clone());
    subject.is_some_and(|subject| has_grant(&state, identity, &subject, &Capability::McpTransport))
}

/// `mcp.listen` — opens `<data_dir>/mcp/<peer>.sock`, waiting for one local
/// connection. Outbound authorization checks this daemon's own grant.
pub fn listen(
    request: &Request,
    store: &Arc<Mutex<Store>>,
    transport: &Arc<TransportMode>,
) -> Response {
    let method = &request.method;
    let identity = resolved_identity_id(request, store);
    let Some(reference) = request_text(&request.params, "to") else {
        return error_response(
            request.id.clone(),
            method,
            ErrorCode::InvalidRequest,
            "to is required".into(),
            false,
        );
    };
    let (peer_id, endpoint_addr, data_dir) = {
        let state = store.lock().expect("store mutex poisoned");
        let Some(peer) = state.peers.iter().find(|peer| {
            peer.identity == identity
                && (peer.id == reference
                    || peer.name == reference
                    || peer.knows_endpoint(&reference)
                    || peer.aliases.iter().any(|alias| alias == &reference))
        }) else {
            return error_response(
                request.id.clone(),
                method,
                ErrorCode::InvalidRequest,
                "peer not found".into(),
                false,
            );
        };
        let Some(address) = peer.endpoint_addr.clone() else {
            return error_response(
                request.id.clone(),
                method,
                ErrorCode::InvalidRequest,
                "peer has no endpoint address".into(),
                false,
            );
        };
        if !has_grant(&state, &identity, &peer.id, &Capability::McpTransport) {
            return error_response(
                request.id.clone(),
                method,
                ErrorCode::CapabilityDenied,
                "mcp.transport not granted for peer".into(),
                false,
            );
        }
        (peer.id.clone(), address, state.data_dir.clone())
    };
    let target: EndpointAddr = match serde_json::from_str(&endpoint_addr) {
        Ok(target) => target,
        Err(error) => {
            return error_response(
                request.id.clone(),
                method,
                ErrorCode::InvalidRequest,
                format!("invalid peer endpoint address: {error}"),
                false,
            )
        }
    };
    let TransportMode::Iroh(manager) = transport.as_ref() else {
        return error_response(
            request.id.clone(),
            method,
            ErrorCode::InvalidRequest,
            "mcp relay requires the iroh transport".into(),
            false,
        );
    };
    let directory = data_dir.join("mcp");
    if let Err(error) = std::fs::create_dir_all(&directory) {
        return error_response(request.id.clone(), method, ErrorCode::Internal, error.to_string(), true);
    }
    let path = directory.join(format!("{}.sock", peer_socket_name(&peer_id)));
    let _ = std::fs::remove_file(&path);
    let listener = match tokio::net::UnixListener::bind(&path) {
        Ok(listener) => listener,
        Err(error) => {
            return error_response(request.id.clone(), method, ErrorCode::Internal, error.to_string(), true)
        }
    };
    let manager = Arc::clone(manager);
    let identity = identity.clone();
    let cleanup = path.clone();
    tokio::spawn(async move {
        match listener.accept().await {
            Ok((stream, _)) => {
                if let Err(error) = outbound(manager, identity, target, stream).await {
                    eprintln!("[idfond] mcp outbound ended: {error:#}");
                }
            }
            Err(error) => eprintln!("[idfond] mcp accept failed: {error}"),
        }
        let _ = std::fs::remove_file(&cleanup);
    });
    success(
        request,
        serde_json::json!({"socket": path, "peer": peer_id, "direction": "outbound"}),
    )
}

/// Short, stable socket filename: a full public key plus the data dir
/// overflows `SUN_LEN` (104 bytes) in real sandbox paths.
fn peer_socket_name(peer_id: &str) -> String {
    let digest = blake3::hash(peer_id.as_bytes()).to_hex();
    digest[..16].to_owned()
}

async fn outbound(
    manager: Arc<TransportManager>,
    identity: String,
    target: EndpointAddr,
    stream: tokio::net::UnixStream,
) -> Result<()> {
    let Some(transport): Option<Arc<IrohTransport>> = manager.current(&identity).await else {
        anyhow::bail!("no transport for identity {identity}");
    };
    let (connection, send, recv) = transport
        .open_bi_stream(&target, MCP_ALPN)
        .await
        .context("dial peer on idfon/mcp/1")?;
    let (uds_read, uds_write) = stream.into_split();
    let _ = tokio::join!(pump(recv, uds_write), pump(uds_read, send));
    connection.close(0u32.into(), b"mcp session closed");
    Ok(())
}
