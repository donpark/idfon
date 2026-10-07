//! `idfon-edge` binary: run the public gateway ingress.
//!
//! ```text
//! idfon-edge [--bind HOST:PORT] [--token VALUE] [--key-file PATH] [--allow ID]...
//!            [--require-ticket CAP] [--domain DOMAIN] [--tls-cert PATH] [--tls-key PATH]
//!            [--health-path PATH] [--rate-limit N]
//! ```
//!
//! Env fallbacks: `IDFON_EDGE_TOKEN`, `IDFON_EDGE_KEY_FILE`, `IDFON_EDGE_DOMAIN`.
//! The key file holds 64 hex characters; a missing file is generated (0600).

use std::collections::HashSet;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context};
use idfon_core::{decode_signing_key, encode_signing_key, generate_identity, signing_key_bytes};
use idfon_edge::{run, EdgeAuth, EdgeConfig};
use idfon_gateway::TlsConfig;

const DEFAULT_BIND: &str = "127.0.0.1:8080";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "idfon_edge=info".into()),
        )
        .init();

    let mut bind: SocketAddr = DEFAULT_BIND.parse().expect("default bind parses");
    let mut auth = std::env::var("IDFON_EDGE_TOKEN")
        .ok()
        .map(EdgeAuth::Token)
        .unwrap_or(EdgeAuth::Open);
    let mut key_file = std::env::var("IDFON_EDGE_KEY_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home_dir().join(".idfon/edge.key"));
    let mut allow = HashSet::new();
    let mut domain = std::env::var("IDFON_EDGE_DOMAIN").ok();
    let mut tls_cert: Option<PathBuf> = None;
    let mut tls_key: Option<PathBuf> = None;
    let mut health_path: Option<String> = Some("/healthz".to_owned());
    let mut rate_limit_per_minute: u32 = 0;

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--bind" => {
                bind = args[i + 1].parse().context("--bind must be HOST:PORT")?;
                i += 2;
            }
            "--token" => {
                auth = EdgeAuth::Token(args[i + 1].clone());
                i += 2;
            }
            "--require-ticket" => {
                auth = EdgeAuth::Ticket {
                    capability: args[i + 1].clone(),
                };
                i += 2;
            }
            "--domain" => {
                domain = Some(args[i + 1].clone());
                i += 2;
            }
            "--tls-cert" => {
                tls_cert = Some(PathBuf::from(&args[i + 1]));
                i += 2;
            }
            "--tls-key" => {
                tls_key = Some(PathBuf::from(&args[i + 1]));
                i += 2;
            }
            "--health-path" => {
                health_path = Some(args[i + 1].clone());
                i += 2;
            }
            "--rate-limit" => {
                rate_limit_per_minute = args[i + 1].parse().context("--rate-limit is a number")?;
                i += 2;
            }
            "--key-file" => {
                key_file = PathBuf::from(&args[i + 1]);
                i += 2;
            }
            "--allow" => {
                allow.insert(args[i + 1].clone());
                i += 2;
            }
            other => return Err(anyhow!("unknown argument {other}")),
        }
    }
    if !bind.ip().is_loopback() && matches!(auth, EdgeAuth::Open) {
        return Err(anyhow!(
            "a non-loopback edge needs requester auth (--token, --require-ticket, or IDFON_EDGE_TOKEN)"
        ));
    }
    let tls = match (tls_cert, tls_key) {
        (Some(cert), Some(key)) => Some(TlsConfig { cert, key }),
        (None, None) => None,
        _ => return Err(anyhow!("--tls-cert and --tls-key must be given together")),
    };
    let tls_enabled = tls.is_some();
    let domain_for_print = domain.clone();

    let key = load_or_create_key(&key_file)?;
    let handle = run(EdgeConfig {
        bind,
        key,
        allow,
        pins: Default::default(),
        domain,
        auth,
        tls,
        health_path: health_path.clone(),
        rate_limit_per_minute,
    })
    .await?;

    let scheme = if tls_enabled { "https" } else { "http" };
    println!(
        "idfon-edge {} listening on {scheme}://{}",
        handle.endpoint_id, handle.addr
    );
    if let Some(path) = &health_path {
        println!("health: {scheme}://{}{path}", handle.addr);
    }
    println!();
    println!("owner pairing (run on the resource owner's machine):");
    println!(
        "  idfon peer add {} --name idfon.net --endpoint-id {} --endpoint-addr '{}'",
        handle.endpoint_id, handle.endpoint_id, handle.addr_ticket
    );
    println!(
        "  idfon access allow --subject {} --capability resource.read",
        handle.endpoint_id
    );
    match &domain_for_print {
        Some(domain) => println!(
            "\nfetch:  {scheme}://<peer-endpoint-id>.{domain}/fs/<path>  (needs wildcard DNS + TLS)"
        ),
        None => println!(
            "\nfetch:  {scheme}://{}/<peer-endpoint-id>/fs/<path>",
            handle.addr
        ),
    }

    tokio::signal::ctrl_c().await.ok();
    handle.shutdown().await;
    Ok(())
}

fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn load_or_create_key(path: &Path) -> anyhow::Result<[u8; 32]> {
    if let Ok(text) = std::fs::read_to_string(path) {
        let key = decode_signing_key(text.trim()).ok_or_else(|| {
            anyhow!(
                "invalid key file {}: expected 64 hex characters",
                path.display()
            )
        })?;
        return Ok(signing_key_bytes(&key));
    }
    let key = generate_identity();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, encode_signing_key(&key))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    eprintln!("generated a new edge identity at {}", path.display());
    Ok(signing_key_bytes(&key))
}
