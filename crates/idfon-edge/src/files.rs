//! Durable files (`docs/durable-files.md`): content-addressed objects and
//! mutable named files served by the edge itself, so downloads outlive chat
//! sessions and agent life cycles.
//!
//! Routes (served before requester auth, like `/_push/*`):
//!
//! ```text
//! GET/HEAD /files/<name...>               mutable file, `cache-control: no-store`
//! GET/HEAD /files/<prefix...>/sha256/<h>  content object, immutable
//! GET/HEAD /models/<name...>              alias used by the model packs
//! PUT      <either form>                  publish (needs the upload token)
//! ```
//!
//! Content objects live at `<root>/sha256/<hash>` whatever prefix the request
//! used, so a `bundle.json` can list relative `sha256/<hash>` paths and the CDN
//! can pull the bare `/sha256/<hash>` path. Named files live at
//! `<root>/<name...>`. The hash in the URL is verified against the body before
//! the object is kept; publishing the same content twice is a no-op.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use futures_util::{StreamExt, TryStreamExt};
use http::{HeaderMap, Method, Response, StatusCode};
use http_body_util::{BodyExt, StreamBody};
use hyper::body::Incoming;
use idfon_gateway::{LocalRoute, ResponseBody};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tokio_util::io::ReaderStream;

/// Prefixes that address named files. Content paths only need the trailing
/// `sha256/<hash>`, so `/models/<pack>/sha256/<hash>` works with a bundle's
/// relative paths.
const NAME_PREFIXES: [&str; 2] = ["/files/", "/models/"];

/// Immutable: the URL is the hash. Mutable names are never cached (there is no
/// conditional-request support, so `no-store` is the honest header and keeps a
/// CDN from serving a stale manifest).
const IMMUTABLE: &str = "public, max-age=31536000, immutable";
const MUTABLE: &str = "no-store";

/// Rental pins: expiry by object (`sha256/<hash>`) or name (`name/<segments>`),
/// so every URL form of an object shares one term.
const PINS_FILE: &str = "pins.json";
const DAY_SECONDS: u64 = 24 * 60 * 60;
/// `x-idfon-pin: permanent` — operational pins never expire. Only the
/// operations token may ask for it.
const PIN_HEADER: &str = "x-idfon-pin";
/// Default per-file cap for user uploads (operational uploads are trusted and
/// bound by the store quota instead). 2 MiB is about four minutes of 32–48 kbps
/// Opus speech (32 kbps ≈ 1.4 MB, 48 kbps ≈ 1.9 MB; 64 kbps exceeds it).
const DEFAULT_MAX_UPLOAD_BYTES: u64 = 2 * 1024 * 1024;

/// A token bucket over the store's total read egress. Reads are public and
/// unauthenticated, so without this the only bound is the NIC: an object the
/// CDN has not cached can be looped at line rate. One global bucket (not
/// per-IP) is deliberate — the edge cannot see client IPs behind the CDN.
struct ReadLimiter {
    bytes_per_second: f64,
    /// One second of tokens: enough to start a single file immediately.
    burst: f64,
    bucket: Mutex<ReadBucket>,
}

struct ReadBucket {
    tokens: f64,
    last: Instant,
}

impl ReadLimiter {
    fn new(bytes_per_second: u64) -> Self {
        let rate = bytes_per_second as f64;
        Self {
            bytes_per_second: rate,
            burst: rate,
            bucket: Mutex::new(ReadBucket {
                tokens: rate,
                last: Instant::now(),
            }),
        }
    }

    /// Reserve `bytes`; returns how long the sender must wait to stay at the
    /// cap. Tokens may go negative — concurrent readers then split the refill
    /// instead of all bursting.
    fn reserve(&self, bytes: u64) -> Duration {
        let mut bucket = self.bucket.lock().unwrap_or_else(|error| error.into_inner());
        let now = Instant::now();
        let elapsed = now.saturating_duration_since(bucket.last).as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * self.bytes_per_second).min(self.burst);
        bucket.last = now;
        bucket.tokens -= bytes as f64;
        if bucket.tokens < 0.0 {
            Duration::from_secs_f64(-bucket.tokens / self.bytes_per_second)
        } else {
            Duration::ZERO
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Role {
    User,
    Ops,
}

#[derive(Default, Deserialize, Serialize)]
struct Pins {
    /// Expiry (unix seconds) per pin key; the latest grant wins.
    pins: BTreeMap<String, u64>,
    /// Taken-down keys: cannot be re-published or served.
    #[serde(default)]
    blocked: BTreeSet<String>,
}

/// Routes backed by a directory of pinned bytes. `quota_bytes == 0` is
/// unlimited; `token == None` makes the store read-only (no HTTP publishing).
pub struct FilesRoutes {
    root: PathBuf,
    quota_bytes: u64,
    /// User publishes: default and cap for their pin term.
    token: Option<String>,
    /// Operational publishes: permanent unless a term is requested.
    ops_token: Option<String>,
    /// User pin term (`0` = no default, i.e. permanent). Default 24 hours.
    user_expiry_secs: u64,
    /// Per-file cap for user publishes (`0` = unlimited). Default 2 MB.
    max_upload_bytes: u64,
    pins: Mutex<Pins>,
    /// Cap on a requested expiry (`0` = no cap). The control plane sets the
    /// term; this stops a client from minting an unbounded one.
    max_expiry_days: u64,
    /// Keep expired bytes this long before deleting them (`0` = delete now).
    grace_days: u64,
    /// Write requests per minute per role (`0` = unlimited). Local routes do
    /// not pass through the gateway's rate limiter, so the store owns this.
    write_limit: u32,
    writes: Mutex<HashMap<String, (Instant, u32)>>,
    /// Global read-egress cap; `None` = unlimited.
    read_limit: Option<Arc<ReadLimiter>>,
    /// Mount points for named files: `/files/` and `/models/` always, plus any
    /// deployment-declared top-level name (e.g. `talk-radio/`), so a CDN that
    /// passes paths through unchanged reaches the store without a rewrite.
    prefixes: Vec<String>,
}

impl FilesRoutes {
    pub fn new(
        root: impl Into<PathBuf>,
        quota_bytes: u64,
        token: Option<String>,
    ) -> std::io::Result<Self> {
        let root = root.into();
        let content = root.join("sha256");
        std::fs::create_dir_all(&content)?;
        // A crashed upload leaves a temp file behind; it is never content.
        if let Ok(entries) = std::fs::read_dir(&content) {
            for entry in entries.flatten() {
                if entry.file_name().to_string_lossy().starts_with(".incoming-") {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
        let pins = std::fs::read(root.join(PINS_FILE))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        let routes = Self {
            root,
            quota_bytes,
            token,
            ops_token: None,
            user_expiry_secs: DAY_SECONDS,
            max_upload_bytes: DEFAULT_MAX_UPLOAD_BYTES,
            pins: Mutex::new(pins),
            max_expiry_days: 0,
            grace_days: 30,
            write_limit: 0,
            writes: Mutex::new(HashMap::new()),
            read_limit: None,
            prefixes: NAME_PREFIXES.iter().map(|prefix| (*prefix).to_owned()).collect(),
        };
        routes.sweep(now_secs());
        Ok(routes)
    }

    /// Mount an extra top-level name as a files namespace (`talk-radio` →
    /// `/talk-radio/...`). The name must be a handle; a reserved or malformed
    /// one is ignored (`false`).
    pub fn with_alias(mut self, name: &str) -> (Self, bool) {
        let name = name.trim().trim_matches('/');
        if name.is_empty() {
            return (self, true);
        }
        if !valid_name(name) {
            return (self, false);
        }
        self.prefixes.push(format!("/{name}/"));
        (self, true)
    }

    /// Expiry policy: `max_expiry_days == 0` accepts any term.
    pub fn with_expiry(mut self, max_expiry_days: u64, grace_days: u64) -> Self {
        self.max_expiry_days = max_expiry_days;
        self.grace_days = grace_days;
        self
    }

    /// The operations token: publishes are permanent unless a term is asked for.
    pub fn with_ops_token(mut self, token: Option<String>) -> Self {
        self.ops_token = token;
        self
    }

    /// Default (and cap) for user pins, in hours. `0` = no default.
    pub fn with_user_expiry_hours(mut self, hours: u64) -> Self {
        self.user_expiry_secs = hours.saturating_mul(60 * 60);
        self
    }

    /// Per-file cap for user uploads, in bytes (`0` = unlimited).
    pub fn with_max_upload_bytes(mut self, bytes: u64) -> Self {
        self.max_upload_bytes = bytes;
        self
    }

    /// PUT/DELETE requests per minute per role (`0` = unlimited).
    pub fn with_write_limit(mut self, per_minute: u32) -> Self {
        self.write_limit = per_minute;
        self
    }

    /// Total bytes the store may serve per second (`0` = unlimited).
    pub fn with_read_limit(mut self, bytes_per_second: u64) -> Self {
        self.read_limit = (bytes_per_second > 0).then(|| Arc::new(ReadLimiter::new(bytes_per_second)));
        self
    }

    fn write_allowed(&self, role: Role) -> bool {
        if self.write_limit == 0 {
            return true;
        }
        let key = match role {
            Role::User => "user",
            Role::Ops => "ops",
        };
        let now = Instant::now();
        let mut writes = self
            .writes
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let entry = writes.entry(key.to_owned()).or_insert((now, 0));
        if now.duration_since(entry.0) >= Duration::from_secs(60) {
            *entry = (now, 0);
        }
        entry.1 += 1;
        entry.1 <= self.write_limit
    }

    fn is_blocked(&self, key: &str) -> bool {
        self.pins
            .lock()
            .map(|pins| pins.blocked.contains(key))
            .unwrap_or(false)
    }

    fn role(&self, headers: &HeaderMap) -> Option<Role> {
        let presented = bearer(headers)?;
        if self
            .ops_token
            .as_deref()
            .is_some_and(|token| constant_time_eq(presented, token))
        {
            return Some(Role::Ops);
        }
        if self
            .token
            .as_deref()
            .is_some_and(|token| constant_time_eq(presented, token))
        {
            return Some(Role::User);
        }
        None
    }

    /// Deletes expired pins' bytes after the grace period, hourly (also at
    /// startup and before each upload).
    pub fn spawn_sweeper(self: &std::sync::Arc<Self>) {
        let routes = std::sync::Arc::clone(self);
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(std::time::Duration::from_secs(60 * 60));
            loop {
                ticker.tick().await;
                routes.sweep(now_secs());
            }
        });
    }

    fn expires_at(&self, key: &str) -> Option<u64> {
        self.pins
            .lock()
            .ok()
            .and_then(|pins| pins.pins.get(key).copied())
    }

    /// The latest expiry wins: a renewal extends a pin, and a re-upload without
    /// a TTL never shortens a paid term.
    fn grant(&self, key: &str, expires_at: u64) {
        let Ok(mut pins) = self.pins.lock() else {
            return;
        };
        let entry = pins.pins.entry(key.to_owned()).or_insert(0);
        if *entry >= expires_at {
            return;
        }
        *entry = expires_at;
        self.persist_pins(&pins);
    }

    fn persist_pins(&self, pins: &Pins) {
        let path = self.root.join(PINS_FILE);
        let temp = path.with_extension("json.tmp");
        if let Ok(bytes) = serde_json::to_vec_pretty(pins) {
            if std::fs::write(&temp, bytes).is_ok() {
                let _ = std::fs::rename(&temp, &path);
            }
        }
    }

    /// Deletes expired pins' bytes once the grace period has passed. Run at
    /// startup and before each upload; reads never write.
    fn sweep(&self, now: u64) {
        let grace = self.grace_days.saturating_mul(DAY_SECONDS);
        let due: Vec<String> = {
            let Ok(pins) = self.pins.lock() else {
                return;
            };
            pins.pins
                .iter()
                .filter(|(_, at)| now >= at.saturating_add(grace))
                .map(|(key, _)| key.clone())
                .collect()
        };
        if due.is_empty() {
            return;
        }
        for key in &due {
            if let Some(hash) = key.strip_prefix("sha256/") {
                let _ = std::fs::remove_file(self.root.join("sha256").join(hash));
            } else if let Some(name) = key.strip_prefix("name/") {
                let _ = std::fs::remove_file(self.root.join(name));
            }
        }
        if let Ok(mut pins) = self.pins.lock() {
            for key in due {
                pins.pins.remove(&key);
            }
            self.persist_pins(&pins);
        }
    }

    async fn serve(&self, method: &Method, path: &str) -> Response<ResponseBody> {
        let head = method == Method::HEAD;
        let now = now_secs();
        if let Some(hash) = content_hash(path) {
            let key = format!("sha256/{hash}");
            if self.is_blocked(&key) {
                return blocked();
            }
            let expires_at = self.expires_at(&key);
            if expires_at.is_some_and(|at| now >= at) {
                return expired();
            }
            // The CDN may not outlive the rental: its TTL is what is left.
            let cache = match expires_at {
                Some(at) => format!("public, max-age={}", at - now),
                None => IMMUTABLE.to_owned(),
            };
            return static_file(
                self.root.join("sha256").join(hash),
                "application/octet-stream",
                &cache,
                head,
                self.read_limit.clone(),
            )
            .await;
        }
        let prefixes: Vec<&str> = self.prefixes.iter().map(String::as_str).collect();
        let Some(name) = name_path_in(&prefixes, path) else {
            return not_found();
        };
        let key = format!("name/{}", name.join("/"));
        if self.is_blocked(&key) {
            return blocked();
        }
        let expires_at = self.expires_at(&key);
        if expires_at.is_some_and(|at| now >= at) {
            return expired();
        }
        let file = self.root.join(name.join("/"));
        let content_type = content_type(name.last().copied().unwrap_or_default());
        static_file(file, content_type, MUTABLE, head, self.read_limit.clone()).await
    }

    async fn publish(
        &self,
        headers: &HeaderMap,
        path: &str,
        body: &mut Incoming,
    ) -> Response<ResponseBody> {
        let role = match self.role(headers) {
            Some(role) => role,
            None if self.token.is_none() && self.ops_token.is_none() => {
                return text(StatusCode::FORBIDDEN, "publishing is disabled")
            }
            None => return text(StatusCode::UNAUTHORIZED, "missing or invalid upload token"),
        };
        if !self.write_allowed(role) {
            return text(StatusCode::TOO_MANY_REQUESTS, "too many writes; retry shortly");
        }
        let now = now_secs();
        self.sweep(now);
        // The size cap applies to user publishes; operational uploads are
        // trusted and bound by the store quota.
        let limit = if role == Role::User {
            self.max_upload_bytes
        } else {
            0
        };
        let declared = headers
            .get(http::header::CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok());
        if limit > 0 && declared.is_some_and(|size| size > limit) {
            // Answer before reading the body: the client must not upload a
            // 5 GB file only to be told it is too large.
            return too_large(limit);
        }
        let prefixes: Vec<&str> = self.prefixes.iter().map(String::as_str).collect();
        let (dest, expected_hash, pin_key) =
            match (content_hash(path), name_path_in(&prefixes, path)) {
            (Some(hash), _) => (
                self.root.join("sha256").join(hash),
                Some(hash.to_owned()),
                format!("sha256/{hash}"),
            ),
            (None, Some(name)) => (
                self.root.join(name.join("/")),
                None,
                format!("name/{}", name.join("/")),
            ),
            _ => return text(StatusCode::BAD_REQUEST, "invalid path"),
        };
        if self.is_blocked(&pin_key) {
            return text(StatusCode::FORBIDDEN, "this object has been taken down");
        }
        // `permanent` is an operations privilege: a user publish always has a
        // term (24h by default), so "no expiry" cannot be bought by a client.
        let permanent = header_value(headers, PIN_HEADER) == Some("permanent");
        if permanent && role == Role::User {
            return text(
                StatusCode::FORBIDDEN,
                "permanent pins require the operations token",
            );
        }
        let requested = match requested_expiry(headers, now) {
            Ok(expires_at) => expires_at,
            Err(message) => return text(StatusCode::BAD_REQUEST, message),
        };
        let cap = |at: u64| {
            if self.max_expiry_days > 0 {
                at.min(now.saturating_add(self.max_expiry_days.saturating_mul(DAY_SECONDS)))
            } else {
                at
            }
        };
        let expires_at = match role {
            // Operational files are permanent unless a term is requested.
            Role::Ops if permanent => None,
            Role::Ops => requested.map(cap),
            // No paid tier yet: user pins last 24h by default and at most 24h.
            // `user_expiry_secs == 0` is the self-host opt-out (no default).
            Role::User if self.user_expiry_secs == 0 => requested,
            Role::User => {
                let until = now.saturating_add(self.user_expiry_secs);
                Some(requested.unwrap_or(until).min(until))
            }
        };

        // Content-addressed writes are idempotent: an object we already have is
        // reported instead of rewritten (the "server already has it" contract).
        if expected_hash.is_some() && tokio::fs::metadata(&dest).await.is_ok() {
            if !drain_limited(body, limit).await {
                return too_large(limit);
            }
            if let Some(at) = expires_at {
                self.grant(&pin_key, at);
            }
            return json(
                StatusCode::OK,
                serde_json::json!({
                    "sha256": expected_hash,
                    "existed": true,
                    "expires_at": self.expires_at(&pin_key),
                }),
            );
        }

        // The store quota is a user-abuse control; the operations token is the
        // service itself and is bound by the disk, not by this cap.
        let used = if role == Role::User {
            used_bytes(&self.root)
        } else {
            0
        };
        if role == Role::User && self.quota_bytes > 0 {
            if declared.is_some_and(|size| used.saturating_add(size) > self.quota_bytes) {
                drain(body).await;
                return text(StatusCode::INSUFFICIENT_STORAGE, "storage quota exceeded");
            }
            if used >= self.quota_bytes {
                drain(body).await;
                return text(StatusCode::INSUFFICIENT_STORAGE, "storage quota exceeded");
            }
        }

        if let Some(parent) = dest.parent() {
            if let Err(error) = tokio::fs::create_dir_all(parent).await {
                return server_error(error);
            }
        }
        let temp =
            self.root
                .join("sha256")
                .join(format!(".incoming-{}-{}", std::process::id(), nanos()));
        let mut file = match tokio::fs::File::create(&temp).await {
            Ok(file) => file,
            Err(error) => return server_error(error),
        };
        let mut hasher = Sha256::new();
        let mut size = 0u64;
        loop {
            let frame = match body.frame().await {
                Some(Ok(frame)) => frame,
                Some(Err(_)) => {
                    remove(&temp).await;
                    return text(StatusCode::BAD_REQUEST, "unreadable body");
                }
                None => break,
            };
            let Some(data) = frame.data_ref() else {
                continue;
            };
            size = size.saturating_add(data.len() as u64);
            if limit > 0 && size > limit {
                remove(&temp).await;
                return too_large(limit);
            }
            if role == Role::User
                && self.quota_bytes > 0
                && used.saturating_add(size) > self.quota_bytes
            {
                remove(&temp).await;
                return text(StatusCode::INSUFFICIENT_STORAGE, "storage quota exceeded");
            }
            hasher.update(data);
            if let Err(error) = file.write_all(data).await {
                remove(&temp).await;
                return server_error(error);
            }
        }
        if let Err(error) = file.flush().await {
            remove(&temp).await;
            return server_error(error);
        }
        drop(file);

        let digest = hex(&hasher.finalize());
        if let Some(expected) = &expected_hash {
            if digest != *expected {
                remove(&temp).await;
                return text(StatusCode::BAD_REQUEST, "sha256 does not match the URL");
            }
        }
        if let Err(error) = tokio::fs::rename(&temp, &dest).await {
            remove(&temp).await;
            return server_error(error);
        }
        if let Some(at) = expires_at {
            self.grant(&pin_key, at);
        }
        json(
            StatusCode::CREATED,
            serde_json::json!({
                "sha256": digest,
                "size": size,
                "existed": false,
                "expires_at": self.expires_at(&pin_key),
            }),
        )
    }

    /// Operational takedown: removes the bytes and the pin. Idempotent. Needs
    /// the operations token — a user token cannot delete other people's files.
    async fn unpublish(&self, headers: &HeaderMap, path: &str) -> Response<ResponseBody> {
        let Some(ops) = self.ops_token.as_deref() else {
            return text(
                StatusCode::FORBIDDEN,
                "deletion requires the operations token",
            );
        };
        if !bearer(headers).is_some_and(|given| constant_time_eq(given, ops)) {
            return text(
                StatusCode::FORBIDDEN,
                "deletion requires the operations token",
            );
        }
        if !self.write_allowed(Role::Ops) {
            return text(StatusCode::TOO_MANY_REQUESTS, "too many writes; retry shortly");
        }
        let (file, key) = if let Some(hash) = content_hash(path) {
            (self.root.join("sha256").join(hash), format!("sha256/{hash}"))
        } else if let Some(name) = name_path(path) {
            (self.root.join(name.join("/")), format!("name/{}", name.join("/")))
        } else {
            return text(StatusCode::BAD_REQUEST, "invalid path");
        };
        remove(&file).await;
        if let Ok(mut pins) = self.pins.lock() {
            let had_pin = pins.pins.remove(&key).is_some();
            let blocked = pins.blocked.insert(key);
            if had_pin || blocked {
                self.persist_pins(&pins);
            }
        }
        Response::builder()
            .status(StatusCode::NO_CONTENT)
            .body(idfon_gateway::bytes_body(Bytes::new()))
            .expect("static response")
    }
}

/// Reads `x-idfon-expires-in` (seconds) or `x-idfon-expires-at` (unix seconds).
fn requested_expiry(headers: &HeaderMap, now: u64) -> Result<Option<u64>, &'static str> {
    if let Some(value) = header_value(headers, "x-idfon-expires-in") {
        let seconds: u64 = value
            .parse()
            .map_err(|_| "x-idfon-expires-in must be whole seconds")?;
        if seconds == 0 {
            return Err("expiry must be in the future");
        }
        return Ok(Some(now.saturating_add(seconds)));
    }
    if let Some(value) = header_value(headers, "x-idfon-expires-at") {
        let at: u64 = value
            .parse()
            .map_err(|_| "x-idfon-expires-at must be unix seconds")?;
        if at <= now {
            return Err("expiry must be in the future");
        }
        return Ok(Some(at));
    }
    Ok(None)
}

fn header_value<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers
        .get(name)?
        .to_str()
        .ok()
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

/// A taken-down key: gone, and not safely cacheable as "not found".
fn blocked() -> Response<ResponseBody> {
    Response::builder()
        .status(StatusCode::GONE)
        .header(http::header::CONTENT_TYPE, "text/plain; charset=utf-8")
        .header(http::header::CACHE_CONTROL, "no-store")
        .body(idfon_gateway::bytes_body("unavailable"))
        .expect("static response")
}

fn expired() -> Response<ResponseBody> {
    Response::builder()
        .status(StatusCode::GONE)
        .header(http::header::CONTENT_TYPE, "text/plain; charset=utf-8")
        .header(http::header::CACHE_CONTROL, "no-store")
        .body(idfon_gateway::bytes_body("expired"))
        .expect("static response")
}

impl LocalRoute for FilesRoutes {
    fn matches(&self, method: &Method, account: &str, path: &str) -> bool {
        let read = matches!(*method, Method::GET | Method::HEAD);
        if !(read || matches!(*method, Method::PUT | Method::DELETE)) {
            return false;
        }
        let prefixes: Vec<&str> = self.prefixes.iter().map(String::as_str).collect();
        let path = routed_path(&prefixes, account, path);
        content_hash(&path).is_some() || name_path_in(&prefixes, &path).is_some()
    }

    fn handle(
        &self,
        method: &Method,
        account: &str,
        path: &str,
        headers: &HeaderMap,
        _uri: &http::Uri,
        mut body: Incoming,
    ) -> Pin<Box<dyn Future<Output = Response<ResponseBody>> + Send + '_>> {
        let method = method.clone();
        let headers = headers.clone();
        let prefixes: Vec<&str> = self.prefixes.iter().map(String::as_str).collect();
        let path = routed_path(&prefixes, account, path);
        Box::pin(async move {
            match method {
                Method::GET | Method::HEAD => self.serve(&method, &path).await,
                Method::PUT => self.publish(&headers, &path, &mut body).await,
                Method::DELETE => self.unpublish(&headers, &path).await,
                _ => text(StatusCode::METHOD_NOT_ALLOWED, "method not allowed"),
            }
        })
    }
}

/// On an IP/localhost edge the gateway strips the first path segment into
/// `account`; `/files/...` and `/models/...` must still address the same store.
/// The gateway strips the first segment as the request's `account`, so a
/// mounted namespace has to be put back before the store sees the path.
fn routed_path(prefixes: &[&str], account: &str, path: &str) -> String {
    if !account.is_empty()
        && prefixes
            .iter()
            .any(|prefix| prefix.trim_matches('/') == account)
    {
        format!("/{account}{path}")
    } else {
        path.to_owned()
    }
}

/// `.../sha256/<64 lowercase hex>` at the end of the path. Any prefix is
/// allowed so content URLs keep working under a pack directory or a CDN root.
fn content_hash(path: &str) -> Option<&str> {
    let segments: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    let index = segments.iter().position(|segment| *segment == "sha256")?;
    let hash = *segments.get(index + 1)?;
    let valid = hash.len() == 64
        && hash
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
    (index + 2 == segments.len() && valid).then_some(hash)
}

/// A validated `/files/<name...>` or `/models/<name...>` path, as segments.
/// First segments stay out of the routes that live beside them.
const RESERVED_NAMES: &[&str] = &["sha256"];

/// A public name is a handle: lowercase, 1–32 of `[a-z0-9_-]`, starting with a
/// letter or digit (Twitter-like, hyphens allowed for `talk-radio`). The first
/// segment names the namespace, so it is the claim; later segments are just
/// files and keep the looser rule below.
fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    name.len() <= 32
        && (first.is_ascii_lowercase() || first.is_ascii_digit())
        && !RESERVED_NAMES.contains(&name)
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
}

fn name_path(path: &str) -> Option<Vec<&str>> {
    name_path_in(&NAME_PREFIXES, path)
}

fn name_path_in<'a>(prefixes: &[&'a str], path: &'a str) -> Option<Vec<&'a str>> {
    // A directory URL keeps its trailing slash; drop it for the prefix match and
    // the segment split, then resolve the directory to its index document.
    let (path, is_dir) = match path.strip_suffix('/') {
        Some(dir) => (dir, true),
        None => (path, false),
    };
    let (rest, alias) = prefixes.iter().find_map(|prefix| {
        // `/files` and `/files/` mount the same tree.
        let base = prefix.trim_end_matches('/');
        let rest = path.strip_prefix(base)?;
        if !(rest.is_empty() || rest.starts_with('/')) {
            return None;
        }
        // `/files/` and `/models/` mount the store as-is. Any other prefix is a
        // top-level namespace alias that also names the store directory, so the
        // name goes back into the path: `/talk-radio/x` → `talk-radio/x`.
        let as_is = NAME_PREFIXES.iter().any(|mounted| mounted == prefix);
        let alias = (!as_is).then(|| base.trim_start_matches('/'));
        Some((rest.strip_prefix('/').unwrap_or(rest), alias))
    })?;

    let mut segments: Vec<&str> = Vec::new();
    if let Some(alias) = alias {
        segments.push(alias);
    }
    if !rest.is_empty() {
        segments.extend(rest.split('/'));
    }
    if segments.is_empty() {
        return None; // the mount root has no index of its own
    }
    if is_dir {
        segments.push("index.html");
    }
    for segment in &segments {
        let valid = !segment.is_empty()
            && *segment != "."
            && *segment != ".."
            && segment.len() <= 200
            && segment
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'));
        if !valid {
            return None;
        }
    }
    // A namespace is a handle; a flat file is just a file (legacy names keep
    // working), so the rule applies only once a path nests under its first
    // segment.
    let (first, rest) = segments.split_first()?;
    if !rest.is_empty() && !valid_name(first) {
        return None;
    }
    Some(segments)
}

async fn static_file(
    file: PathBuf,
    content_type: &str,
    cache_control: &str,
    head: bool,
    read_limit: Option<Arc<ReadLimiter>>,
) -> Response<ResponseBody> {
    let Ok(metadata) = tokio::fs::metadata(&file).await else {
        return not_found();
    };
    if !metadata.is_file() {
        return not_found();
    }
    let response = Response::builder()
        .status(StatusCode::OK)
        .header(http::header::CONTENT_TYPE, content_type)
        .header(http::header::CONTENT_LENGTH, metadata.len())
        .header(http::header::CACHE_CONTROL, cache_control);
    if head {
        return response
            .body(idfon_gateway::bytes_body(Bytes::new()))
            .expect("static response");
    }
    match tokio::fs::File::open(&file).await {
        Ok(file) => {
            let stream = ReaderStream::new(file)
                .map_ok(http_body::Frame::data)
                .then(move |frame| {
                    let limit = read_limit.clone();
                    async move {
                        if let (Some(limit), Ok(frame)) = (&limit, &frame) {
                            if let Some(len) = frame.data_ref().map(|data| data.len() as u64) {
                                let wait = limit.reserve(len);
                                if !wait.is_zero() {
                                    tokio::time::sleep(wait).await;
                                }
                            }
                        }
                        frame
                    }
                });
            response
                .body(BodyExt::boxed(StreamBody::new(stream)))
                .expect("static response")
        }
        Err(_) => not_found(),
    }
}

/// Total bytes pinned under `root` (temp uploads excluded).
fn used_bytes(root: &Path) -> u64 {
    let mut total = 0u64;
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let Ok(metadata) = entry.metadata() else {
                continue;
            };
            if metadata.is_dir() {
                pending.push(entry.path());
            } else if !entry
                .file_name()
                .to_string_lossy()
                .starts_with(".incoming-")
            {
                total = total.saturating_add(metadata.len());
            }
        }
    }
    total
}

async fn drain(body: &mut Incoming) {
    while body.frame().await.is_some() {}
}

/// Discards a body, refusing once it exceeds `limit` (0 = unlimited).
async fn drain_limited(body: &mut Incoming, limit: u64) -> bool {
    if limit == 0 {
        drain(body).await;
        return true;
    }
    let mut total = 0u64;
    while let Some(frame) = body.frame().await {
        let Ok(frame) = frame else {
            return true;
        };
        if let Some(data) = frame.data_ref() {
            total = total.saturating_add(data.len() as u64);
            if total > limit {
                return false;
            }
        }
    }
    true
}

fn too_large(limit: u64) -> Response<ResponseBody> {
    text(
        StatusCode::PAYLOAD_TOO_LARGE,
        &format!("file exceeds the {} upload limit", pretty_bytes(limit)),
    )
}

fn pretty_bytes(bytes: u64) -> String {
    if bytes >= 1024 * 1024 && bytes % (1024 * 1024) == 0 {
        format!("{} MB", bytes / (1024 * 1024))
    } else if bytes >= 1024 && bytes % 1024 == 0 {
        format!("{} KB", bytes / 1024)
    } else {
        format!("{bytes} byte")
    }
}

async fn remove(path: &Path) {
    let _ = tokio::fs::remove_file(path).await;
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}

fn constant_time_eq(given: &str, expected: &str) -> bool {
    let (given, expected) = (given.as_bytes(), expected.as_bytes());
    given.len() == expected.len()
        && given
            .iter()
            .zip(expected)
            .fold(0u8, |acc, (a, b)| acc | (a ^ b))
            == 0
}

fn content_type(name: &str) -> &'static str {
    match name
        .rsplit('.')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase()
        .as_str()
    {
        "json" => "application/json",
        "txt" | "md" => "text/plain; charset=utf-8",
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript",
        "wasm" => "application/wasm",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "svg" => "image/svg+xml",
        "wav" => "audio/wav",
        _ => "application/octet-stream",
    }
}

fn hex(digest: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0)
}

fn nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos())
        .unwrap_or(0)
}

fn not_found() -> Response<ResponseBody> {
    text(StatusCode::NOT_FOUND, "not found")
}

fn server_error(error: std::io::Error) -> Response<ResponseBody> {
    text(StatusCode::INTERNAL_SERVER_ERROR, &error.to_string())
}

fn text(status: StatusCode, message: &str) -> Response<ResponseBody> {
    Response::builder()
        .status(status)
        .header(http::header::CONTENT_TYPE, "text/plain; charset=utf-8")
        .body(idfon_gateway::bytes_body(message.to_owned()))
        .expect("static response")
}

fn json(status: StatusCode, value: serde_json::Value) -> Response<ResponseBody> {
    Response::builder()
        .status(status)
        .header(http::header::CONTENT_TYPE, "application/json")
        .body(idfon_gateway::bytes_body(value.to_string()))
        .expect("static response")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_paths_accept_any_prefix_and_reject_bad_hashes() {
        let hash = "ab".repeat(32);
        assert_eq!(
            content_hash(&format!("/sha256/{hash}")),
            Some(hash.as_str())
        );
        assert_eq!(
            content_hash(&format!("/files/phonon-31m/sha256/{hash}")),
            Some(hash.as_str())
        );
        assert_eq!(content_hash(&format!("/sha256/{}", "AB".repeat(32))), None);
        assert_eq!(content_hash(&format!("/sha256/{hash}/extra")), None);
        assert_eq!(content_hash("/sha256/short"), None);
    }

    #[test]
    fn names_are_handles() {
        assert!(valid_name("talk-radio"));
        assert!(valid_name("tyger_2"));
        assert!(valid_name("phonon-31m"));
        assert!(!valid_name("TalkRadio"), "lowercase only");
        assert!(!valid_name("-leading"));
        assert!(!valid_name("_x"));
        assert!(!valid_name("has.dot"));
        assert!(!valid_name(""));
        assert!(!valid_name(&"a".repeat(33)));
        assert!(!valid_name("sha256"), "reserved for the content route");
    }

    #[test]
    fn named_paths_are_guarded() {
        assert_eq!(name_path("/files/a/b.json"), Some(vec!["a", "b.json"]));
        assert_eq!(name_path("/files/Talk/b.json"), None, "handle rule");
        assert_eq!(
            name_path("/files/talk-radio/"),
            Some(vec!["talk-radio", "index.html"]),
            "a directory serves its index"
        );
        assert_eq!(
            name_path("/files/talk-radio/topics.html"),
            Some(vec!["talk-radio", "topics.html"])
        );
        assert_eq!(name_path("/models/tyger/"), Some(vec!["tyger", "index.html"]));
        assert_eq!(name_path("/files/"), None);
        assert_eq!(name_path("/files"), None);
        // A deployment-declared alias mounts a top-level name as a namespace:
        // `/talk-radio/` serves `talk-radio/index.html`.
        let aliased: Vec<&str> = vec!["/files/", "/models/", "/talk-radio/"];
        assert_eq!(
            name_path_in(&aliased, "/talk-radio/"),
            Some(vec!["talk-radio", "index.html"])
        );
        assert_eq!(
            name_path_in(&aliased, "/talk-radio/tech-talk.html"),
            Some(vec!["talk-radio", "tech-talk.html"])
        );
        // Without the alias it stays a resource path, not a file.
        assert_eq!(name_path("/talk-radio/"), None);
        assert_eq!(
            name_path("/files/README.html"),
            Some(vec!["README.html"]),
            "a flat file is not a namespace claim"
        );
        assert_eq!(name_path("/files/sha256/b.json"), None, "reserved");
        assert_eq!(
            name_path("/models/phonon-31m/bundle.json"),
            Some(vec!["phonon-31m", "bundle.json"])
        );
        assert_eq!(name_path("/files/../etc/passwd"), None);
        assert_eq!(name_path("/files/a//b"), None);
        assert_eq!(name_path("/elsewhere/a.json"), None);
    }

    #[test]
    fn an_alias_serves_and_accepts_writes() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("idfon-files-alias-{}-{nanos}", std::process::id()));
        let (routes, ok) = FilesRoutes::new(&root, 0, Some("t".into()))
            .unwrap()
            .with_alias("talk-radio");
        assert!(ok);
        assert!(routes.matches(&Method::GET, "talk-radio", "/"));
        assert!(routes.matches(&Method::PUT, "", "/talk-radio/index.html"));
        assert!(!routes.matches(&Method::GET, "other", "/"));
        let (routes, ok) = FilesRoutes::new(&root, 0, None).unwrap().with_alias("Talk");
        assert!(!ok, "not a handle");
        let _ = routes;
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn user_upload_cap_defaults_to_2mb() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("idfon-files-cap-{}-{nanos}", std::process::id()));
        let routes = FilesRoutes::new(&root, 0, None).unwrap();
        assert_eq!(routes.max_upload_bytes, 2 * 1024 * 1024);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn read_limiter_bursts_one_second_then_holds_the_rate() {
        let limiter = ReadLimiter::new(1_000_000);
        assert_eq!(limiter.reserve(1_000_000), Duration::ZERO, "burst is free");
        let wait = limiter.reserve(1_000_000);
        assert!(
            wait >= Duration::from_millis(900),
            "second second must wait ~1s, got {wait:?}"
        );
    }

    #[test]
    fn expiry_headers_are_validated() {
        let mut headers = HeaderMap::new();
        assert_eq!(requested_expiry(&headers, 100), Ok(None));
        headers.insert("x-idfon-expires-in", "60".parse().unwrap());
        assert_eq!(requested_expiry(&headers, 100), Ok(Some(160)));
        headers.insert("x-idfon-expires-in", "0".parse().unwrap());
        assert!(requested_expiry(&headers, 100).is_err());
        let mut headers = HeaderMap::new();
        headers.insert("x-idfon-expires-at", "50".parse().unwrap());
        assert!(requested_expiry(&headers, 100).is_err());
    }

    #[test]
    fn latest_expiry_wins_and_grace_controls_deletion() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("idfon-files-pins-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(root.join("sha256")).unwrap();
        let hash = "ab".repeat(32);
        let object = root.join("sha256").join(&hash);
        std::fs::write(&object, b"bytes").unwrap();

        let routes = FilesRoutes::new(&root, 0, None)
            .unwrap()
            .with_expiry(0, 1);
        routes.grant(&format!("sha256/{hash}"), 200);
        routes.grant(&format!("sha256/{hash}"), 100); // an older grant never shortens
        assert_eq!(routes.expires_at(&format!("sha256/{hash}")), Some(200));

        routes.sweep(200 + DAY_SECONDS - 1);
        assert!(object.exists(), "still inside the grace period");
        routes.sweep(200 + DAY_SECONDS);
        assert!(!object.exists(), "deleted after grace");
        assert_eq!(routes.expires_at(&format!("sha256/{hash}")), None);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn content_types_follow_the_extension() {
        assert_eq!(content_type("bundle.json"), "application/json");
        assert_eq!(content_type("x.safetensors"), "application/octet-stream");
    }
}
