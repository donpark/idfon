//! Durable files end to end through the real gateway: publish (verified),
//! serve by hash, the `/models` alias, idempotency, the upload token and the
//! quota.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use idfon_edge::FilesRoutes;
use idfon_gateway::{
    serve, Authorizer, Backend, Caller, Config, GatewayError, GatewayHandle, Resource,
};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct NoBackend;

impl Backend for NoBackend {
    async fn fetch(
        &self,
        _caller: &Caller,
        _account: &str,
        path: &str,
    ) -> Result<Resource, GatewayError> {
        Err(GatewayError::NotFound(path.to_owned()))
    }
}

struct AllowAll;

impl Authorizer for AllowAll {
    fn authorize(&self, _caller: &Caller, _account: &str, _path: &str) -> bool {
        true
    }
}

async fn start(root: &std::path::Path, quota: u64, token: Option<&str>) -> (Addr, GatewayHandle) {
    start_full(root, quota, token, None, 24).await
}

async fn start_full(
    root: &std::path::Path,
    quota: u64,
    token: Option<&str>,
    ops_token: Option<&str>,
    user_hours: u64,
) -> (Addr, GatewayHandle) {
    let routes = FilesRoutes::new(root, quota, token.map(str::to_owned))
        .expect("routes")
        .with_ops_token(ops_token.map(str::to_owned))
        .with_user_expiry_hours(user_hours);
    let handle = serve(
        Config {
            local_routes: vec![Arc::new(routes)],
            ..Config::default()
        },
        NoBackend,
        AllowAll,
    )
    .await
    .expect("gateway binds");
    (Addr(handle.local_addr()), handle)
}

#[derive(Clone, Copy)]
struct Addr(SocketAddr);

async fn request(
    addr: Addr,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: &[u8],
) -> (u16, Vec<u8>) {
    let (status, _, body) = request_with(addr, method, path, token, &[], body).await;
    (status, body)
}

async fn request_with(
    addr: Addr,
    method: &str,
    path: &str,
    token: Option<&str>,
    extra: &[(&str, &str)],
    body: &[u8],
) -> (u16, String, Vec<u8>) {
    let mut stream = tokio::net::TcpStream::connect(addr.0)
        .await
        .expect("connect");
    let mut head = format!(
        "{method} {path} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\nContent-Length: {}\r\n",
        addr.0,
        body.len()
    );
    if let Some(token) = token {
        head.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    for (name, value) in extra {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).await.unwrap();
    stream.write_all(body).await.unwrap();
    let mut raw = Vec::new();
    stream
        .read_to_end(&mut raw)
        .await
        .unwrap_or_else(|error| panic!("{method} {path}: {error}"));
    let split = raw
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .expect("headers");
    let head = String::from_utf8_lossy(&raw[..split]).into_owned();
    let status = head
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse().ok())
        .expect("status");
    let mut body = raw[split + 4..].to_vec();
    // A streamed body is chunked by hyper; assert on the decoded text instead.
    if head
        .to_ascii_lowercase()
        .contains("transfer-encoding: chunked")
    {
        body = dechunk(&body);
    }
    (status, head, body)
}

fn dechunk(raw: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut rest = raw;
    loop {
        let Some(end) = rest.windows(2).position(|window| window == b"\r\n") else {
            break;
        };
        let size =
            usize::from_str_radix(String::from_utf8_lossy(&rest[..end]).trim(), 16).unwrap_or(0);
        rest = &rest[end + 2..];
        if size == 0 || rest.len() < size {
            break;
        }
        out.extend_from_slice(&rest[..size]);
        rest = &rest[size + 2..];
    }
    out
}

fn sha256(body: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(body);
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn temp_root(tag: &str) -> std::path::PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root =
        std::env::temp_dir().join(format!("idfon-files-{tag}-{}-{nanos}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    root
}

#[tokio::test]
async fn publishes_and_serves_content_by_hash() {
    let root = temp_root("content");
    let (addr, handle) = start(&root, 0, Some("secret")).await;
    let body = b"durable model bytes".to_vec();
    let hash = sha256(&body);

    let (status, _) = request(
        addr,
        "PUT",
        &format!("/files/sha256/{hash}"),
        Some("secret"),
        &body,
    )
    .await;
    assert_eq!(status, 201);

    // Same object under a pack prefix (what a bundle lists) and at the root.
    for path in [
        format!("/files/sha256/{hash}"),
        format!("/models/phonon-31m/sha256/{hash}"),
    ] {
        let (status, got) = request(addr, "GET", &path, None, b"").await;
        assert_eq!(status, 200, "{path}");
        assert_eq!(got, body, "{path}");
    }

    // A republish is idempotent, and a mismatched hash is refused.
    let (status, _) = request(
        addr,
        "PUT",
        &format!("/files/sha256/{hash}"),
        Some("secret"),
        &body,
    )
    .await;
    assert_eq!(status, 200);
    let wrong = "0".repeat(64);
    let (status, _) = request(
        addr,
        "PUT",
        &format!("/files/sha256/{wrong}"),
        Some("secret"),
        &body,
    )
    .await;
    assert_eq!(status, 400);
    let (status, _) = request(addr, "GET", &format!("/files/sha256/{wrong}"), None, b"").await;
    assert_eq!(status, 404);

    // An upload without the token is refused.
    let (status, _) = request(addr, "PUT", &format!("/files/sha256/{hash}"), None, b"").await;
    assert_eq!(status, 401);

    handle.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn named_files_are_mutable_and_guarded() {
    let root = temp_root("names");
    let (addr, handle) = start(&root, 0, Some("secret")).await;

    let (status, _) = request(
        addr,
        "PUT",
        "/models/phonon-31m/bundle.json",
        Some("secret"),
        b"{\"built\":1}",
    )
    .await;
    assert_eq!(status, 201);
    let (status, body) = request(addr, "GET", "/models/phonon-31m/bundle.json", None, b"").await;
    assert_eq!(status, 200);
    assert_eq!(body, b"{\"built\":1}");
    assert!(root.join("phonon-31m/bundle.json").is_file());

    // Overwrite in place (a new export under the same stable name).
    let (status, _) = request(
        addr,
        "PUT",
        "/files/phonon-31m/bundle.json",
        Some("secret"),
        b"{\"built\":2}",
    )
    .await;
    assert_eq!(status, 201);
    let (_, body) = request(addr, "GET", "/models/phonon-31m/bundle.json", None, b"").await;
    assert_eq!(body, b"{\"built\":2}");

    // Traversal never reaches the route (and never touches disk).
    let (status, _) = request(addr, "PUT", "/files/../escape", Some("secret"), b"").await;
    assert_ne!(status, 201);
    assert!(!root.parent().unwrap().join("escape").exists());

    handle.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn quota_stops_new_pins() {
    let root = temp_root("quota");
    let (addr, handle) = start(&root, 16, Some("secret")).await;
    let body = vec![7u8; 32];
    let hash = sha256(&body);
    let (status, _) = request(
        addr,
        "PUT",
        &format!("/files/sha256/{hash}"),
        Some("secret"),
        &body,
    )
    .await;
    assert_eq!(status, 507);
    let (status, _) = request(addr, "GET", &format!("/files/sha256/{hash}"), None, b"").await;
    assert_eq!(status, 404);
    handle.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn expires_pins_and_bounds_the_cache_ttl() {
    let root = temp_root("expiry");
    let (addr, handle) = start(&root, 0, Some("secret")).await;
    let body = b"rental".to_vec();
    let hash = sha256(&body);
    let path = format!("/files/sha256/{hash}");

    let (status, _, _) = request_with(
        addr,
        "PUT",
        &path,
        Some("secret"),
        &[("x-idfon-expires-in", "1")],
        &body,
    )
    .await;
    assert_eq!(status, 201);

    let (status, head, _) = request_with(addr, "GET", &path, None, &[], b"").await;
    assert_eq!(status, 200);
    assert!(
        head.to_ascii_lowercase()
            .contains("cache-control: public, max-age="),
        "{head}"
    );

    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    let (status, head, _) = request_with(addr, "GET", &path, None, &[], b"").await;
    assert_eq!(status, 410);
    assert!(head.to_ascii_lowercase().contains("cache-control: no-store"));

    handle.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

#[tokio::test]
async fn user_pins_default_to_24h_and_cannot_exceed_it() {
    let root = temp_root("user-term");
    let (addr, handle) = start(&root, 0, Some("secret")).await;
    let body = b"user file".to_vec();
    let hash = sha256(&body);
    let path = format!("/files/sha256/{hash}");

    let (status, _, created) = request_with(addr, "PUT", &path, Some("secret"), &[], &body).await;
    assert_eq!(status, 201);
    let created: serde_json::Value = serde_json::from_slice(&created).unwrap();
    let expires = created["expires_at"].as_u64().expect("default term");
    let expected = now_secs() + 24 * 60 * 60;
    assert!(
        expires.abs_diff(expected) < 90,
        "24h default, got {expires} (now+24h {expected})"
    );

    // A longer request is clamped, not rejected.
    let body = b"longer file".to_vec();
    let hash2 = sha256(&body);
    let (status, _, created) = request_with(
        addr,
        "PUT",
        &format!("/files/sha256/{hash2}"),
        Some("secret"),
        &[("x-idfon-expires-in", "2592000")],
        &body,
    )
    .await;
    assert_eq!(status, 201);
    let created: serde_json::Value = serde_json::from_slice(&created).unwrap();
    let expires = created["expires_at"].as_u64().unwrap();
    assert!(
        expires.abs_diff(now_secs() + 24 * 60 * 60) < 90,
        "30d request clamped to 24h"
    );

    // A permanent pin is an operations privilege.
    let (status, _, _) = request_with(
        addr,
        "PUT",
        &format!("/files/sha256/{}", sha256(b"perm")),
        Some("secret"),
        &[("x-idfon-pin", "permanent")],
        b"",
    )
    .await;
    assert_eq!(status, 403);

    handle.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn ops_pins_are_permanent_unless_a_term_is_asked() {
    let root = temp_root("ops-term");
    let (addr, handle) = start_full(&root, 0, Some("secret"), Some("ops"), 24).await;

    let body = b"operational".to_vec();
    let hash = sha256(&body);
    let path = format!("/files/sha256/{hash}");
    let (status, _, created) = request_with(addr, "PUT", &path, Some("ops"), &[], &body).await;
    assert_eq!(status, 201);
    let created: serde_json::Value = serde_json::from_slice(&created).unwrap();
    assert!(created["expires_at"].is_null(), "ops default is permanent");
    let (status, head, _) = request_with(addr, "GET", &path, None, &[], b"").await;
    assert_eq!(status, 200);
    assert!(head.contains("cache-control: public, max-age=31536000, immutable"));

    // Ops may still set a temporary term.
    let body = b"ops temporary".to_vec();
    let hash = sha256(&body);
    let (status, _, created) = request_with(
        addr,
        "PUT",
        &format!("/files/sha256/{hash}"),
        Some("ops"),
        &[("x-idfon-expires-in", "60")],
        &body,
    )
    .await;
    assert_eq!(status, 201);
    let created: serde_json::Value = serde_json::from_slice(&created).unwrap();
    assert!(created["expires_at"].as_u64().unwrap().abs_diff(now_secs() + 60) < 5);

    // `permanent` wins over a term, and only for the ops token.
    let body = b"ops permanent".to_vec();
    let hash = sha256(&body);
    let (status, _, created) = request_with(
        addr,
        "PUT",
        &format!("/files/sha256/{hash}"),
        Some("ops"),
        &[("x-idfon-pin", "permanent"), ("x-idfon-expires-in", "60")],
        &body,
    )
    .await;
    assert_eq!(status, 201);
    let created: serde_json::Value = serde_json::from_slice(&created).unwrap();
    assert!(created["expires_at"].is_null());

    handle.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}
