//! `idfon-gateway` — a reusable loopback HTTP gateway for `idfon://` resources.
//!
//! Apps embed this to expose account resources to an HTTP consumer (a WebView,
//! an MCP facade, a local tool) without committing to a process model. The
//! crate owns HTTP mechanics and address mapping; it does **not** own identity,
//! authorization policy, resource providers, or MCP semantics — those arrive as
//! a [`Backend`] and an [`Authorizer`]. Agents that would rather keep their own
//! IPC simply don't link it.
//!
//! Addressing (the virtual-host form is preferred — the path passes through
//! untouched, so a provider's own routes survive):
//!
//! ```text
//! idfon://<account>/<path>   <->   http://<account>.localhost:<port>/<path>
//!                                  http://127.0.0.1:<port>/<account>/<path>
//! ```
//!
//! Safety defaults: loopback bind, a required bearer token for any non-loopback
//! bind, `Host`/`Origin` validation (DNS-rebinding), and `..` rejection.

use std::net::SocketAddr;
use std::sync::Arc;

use bytes::Bytes;
use http::{header, HeaderMap, StatusCode, Uri};
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::TokioIo;
use idfon_core::transport::IrohTransport;
use idfon_h3::H3Client;
use iroh::EndpointAddr;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

/// Upper bound on a single fetched resource body.
pub const MAX_RESOURCE_BYTES: usize = 8 * 1024 * 1024;

/// A fetched resource body.
#[derive(Debug, Clone)]
pub struct Resource {
    pub content_type: String,
    pub body: Vec<u8>,
}

/// Fetches a resource for an account, given the path after the account.
pub trait Backend: Send + Sync + 'static {
    fn fetch(
        &self,
        account: &str,
        path: &str,
    ) -> impl std::future::Future<Output = Result<Resource, GatewayError>> + Send;
}

/// Per-request authorization. The caller is the verified requester from
/// [`Authenticator`]; `account`/`path` are the request target.
pub trait Authorizer: Send + Sync + 'static {
    fn authorize(&self, caller: &Caller, account: &str, path: &str) -> bool;
}

/// Verified requester identity, produced by an [`Authenticator`]. `subject` is
/// empty for an unauthenticated (open, loopback-only) gateway.
#[derive(Debug, Clone, Default)]
pub struct Caller {
    pub subject: String,
}

impl Caller {
    pub fn anonymous() -> Self {
        Self::default()
    }
}

/// Verifies requester credentials from the HTTP request. Returning `None`
/// rejects the request (401). The default loopback gateway uses
/// [`StaticToken`]; a public edge verifies a signed token or capability ticket.
pub trait Authenticator: Send + Sync + 'static {
    fn authenticate(&self, headers: &HeaderMap, uri: &Uri) -> Option<Caller>;
}

/// The loopback gateway's shared-secret bearer token.
pub struct StaticToken(String);

impl StaticToken {
    pub fn new(token: impl Into<String>) -> Self {
        Self(token.into())
    }
}

impl Authenticator for StaticToken {
    fn authenticate(&self, headers: &HeaderMap, uri: &Uri) -> Option<Caller> {
        let presented = bearer(headers).or_else(|| query_token(uri))?;
        constant_time_eq(presented.as_bytes(), self.0.as_bytes()).then(|| Caller {
            subject: "local".to_owned(),
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum GatewayError {
    #[error("unknown account {0}")]
    UnknownAccount(String),
    #[error("resource not found: {0}")]
    NotFound(String),
    #[error("backend: {0}")]
    Backend(String),
}

/// Gateway configuration. `auth` is required for a non-loopback bind.
#[derive(Clone)]
pub struct Config {
    pub bind: SocketAddr,
    /// Verifies the requester. `None` is an open gateway, allowed only on
    /// loopback.
    pub auth: Option<Arc<dyn Authenticator>>,
    /// When set, `<ref>.<origin_domain>` is accepted as a virtual host in
    /// addition to loopback and `*.localhost` (e.g. `idfon.net`).
    pub origin_domain: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            bind: ([127, 0, 0, 1], 0).into(),
            auth: None,
            origin_domain: None,
        }
    }
}

/// A running gateway. Dropping it aborts the accept loop.
pub struct GatewayHandle {
    addr: SocketAddr,
    task: JoinHandle<()>,
}

impl GatewayHandle {
    pub fn local_addr(&self) -> SocketAddr {
        self.addr
    }

    /// Stops accepting new connections. In-flight requests are not aborted.
    pub fn shutdown(self) {
        self.task.abort();
    }
}

impl Drop for GatewayHandle {
    fn drop(&mut self) {
        // The doc promises dropping aborts the accept loop; detaching the
        // JoinHandle would leave the listener task running.
        self.task.abort();
    }
}

/// Binds the loopback listener and serves until the handle is dropped/aborted.
pub async fn serve<B, A>(
    config: Config,
    backend: B,
    authorizer: A,
) -> std::io::Result<GatewayHandle>
where
    B: Backend,
    A: Authorizer,
{
    if !config.bind.ip().is_loopback() && config.auth.is_none() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "an authenticator is required for a non-loopback bind",
        ));
    }
    let listener = TcpListener::bind(config.bind).await?;
    let addr = listener.local_addr()?;
    let shared = Arc::new(Shared {
        backend,
        authorizer,
        auth: config.auth,
        origin_domain: config.origin_domain,
    });
    let task = tokio::spawn(async move {
        while let Ok((stream, _peer)) = listener.accept().await {
            let shared = shared.clone();
            tokio::spawn(async move {
                let io = TokioIo::new(stream);
                let service = service_fn(move |request| {
                    let shared = shared.clone();
                    async move { Ok::<_, std::convert::Infallible>(handle(shared, request).await) }
                });
                let _ = hyper::server::conn::http1::Builder::new()
                    .serve_connection(io, service)
                    .await;
            });
        }
    });
    Ok(GatewayHandle { addr, task })
}

struct Shared<B, A> {
    backend: B,
    authorizer: A,
    auth: Option<Arc<dyn Authenticator>>,
    origin_domain: Option<String>,
}

async fn handle<B: Backend, A: Authorizer>(
    shared: Arc<Shared<B, A>>,
    request: Request<Incoming>,
) -> Response<Full<Bytes>> {
    if request.method() != http::Method::GET {
        return plain(StatusCode::METHOD_NOT_ALLOWED, "method not allowed");
    }
    let uri = request.uri().clone();
    let headers = request.headers();
    if !hosts_allowed(headers, shared.origin_domain.as_deref()) {
        return plain(StatusCode::FORBIDDEN, "host not allowed");
    }
    let caller = match &shared.auth {
        Some(auth) => match auth.authenticate(headers, &uri) {
            Some(caller) => caller,
            None => return plain(StatusCode::UNAUTHORIZED, "missing or invalid credentials"),
        },
        None => Caller::anonymous(),
    };
    let Some((account, path)) = target(&uri, headers, shared.origin_domain.as_deref()) else {
        return plain(StatusCode::BAD_REQUEST, "missing account");
    };
    if path.split('/').any(|segment| segment == "..") {
        return plain(StatusCode::BAD_REQUEST, "invalid path");
    }
    if !shared.authorizer.authorize(&caller, &account, &path) {
        return plain(StatusCode::FORBIDDEN, "not authorized");
    }
    match shared.backend.fetch(&account, &path).await {
        Ok(resource) => Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, resource.content_type)
            .body(Full::new(Bytes::from(resource.body)))
            .unwrap_or_else(|_| plain(StatusCode::INTERNAL_SERVER_ERROR, "response error")),
        Err(GatewayError::UnknownAccount(_)) | Err(GatewayError::NotFound(_)) => {
            plain(StatusCode::NOT_FOUND, "not found")
        }
        Err(GatewayError::Backend(message)) => {
            plain(StatusCode::BAD_GATEWAY, &format!("backend: {message}"))
        }
    }
}

fn plain(status: StatusCode, body: &str) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
        .body(Full::new(Bytes::from(body.to_owned())))
        .expect("static response builds")
}

/// True when `Host` (and, if present, `Origin`) names a loopback authority, a
/// `*.localhost` name, or `*.<origin_domain>`. Blocks DNS-rebinding from a
/// foreign web origin.
fn hosts_allowed(headers: &HeaderMap, origin_domain: Option<&str>) -> bool {
    let host_ok = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .map(host_without_port)
        .is_some_and(|host| allowed_host(host, origin_domain));
    let origin_ok = match headers.get(header::ORIGIN).and_then(|v| v.to_str().ok()) {
        None => true,
        Some(origin) => Uri::try_from(origin)
            .ok()
            .and_then(|uri| uri.host().map(str::to_owned))
            .is_some_and(|host| allowed_host(&host, origin_domain)),
    };
    host_ok && origin_ok
}

fn allowed_host(host: &str, origin_domain: Option<&str>) -> bool {
    if host == "127.0.0.1" || host == "localhost" || host == "::1" || host.ends_with(".localhost") {
        return true;
    }
    match origin_domain {
        Some(domain) => host == domain || host.ends_with(&format!(".{domain}")),
        None => false,
    }
}

fn host_without_port(host: &str) -> &str {
    if let Some(rest) = host.strip_prefix('[') {
        if let Some(end) = rest.find(']') {
            return &rest[..end];
        }
    }
    host.split(':').next().unwrap_or(host)
}

/// Resolves the request target: `account` + `path`.
fn target(uri: &Uri, headers: &HeaderMap, origin_domain: Option<&str>) -> Option<(String, String)> {
    if let Some(host) = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .map(host_without_port)
    {
        if let Some(account) = virtual_host_account(host, origin_domain) {
            return Some((account, uri.path().to_owned()));
        }
    }
    let mut segments = uri.path().trim_start_matches('/').splitn(2, '/');
    let account = segments.next().filter(|s| !s.is_empty())?.to_owned();
    let path = match segments.next() {
        Some(rest) if !rest.is_empty() => format!("/{rest}"),
        _ => "/".to_owned(),
    };
    Some((account, path))
}

/// The account named by a virtual host (`<account>.localhost` or
/// `<account>.<origin_domain>`), if any.
fn virtual_host_account(host: &str, origin_domain: Option<&str>) -> Option<String> {
    if let Some(account) = host.strip_suffix(".localhost").filter(|a| !a.is_empty()) {
        return Some(account.to_owned());
    }
    if let Some(domain) = origin_domain {
        if let Some(account) = host
            .strip_suffix(&format!(".{domain}"))
            .filter(|a| !a.is_empty())
        {
            return Some(account.to_owned());
        }
    }
    None
}

fn bearer(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::to_owned)
}

fn query_token(uri: &Uri) -> Option<String> {
    uri.query().and_then(|query| {
        query
            .split('&')
            .find_map(|pair| pair.strip_prefix("token="))
            .map(str::to_owned)
    })
}

/// Length-independent comparison, so token checks don't leak length/prefix.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Resolves an `idfon://` account ref to a dialable peer.
///
/// Ref resolution needs the peer store, which the gateway does not own, so the
/// embedder supplies this. `account` is whatever the HTTP request named — the
/// derived `blake3(account_id)` handle in the canonical case, but any ref the
/// embedder chooses to accept (account id, endpoint id, alias, name). Returning
/// `None` yields 404.
pub trait AccountResolver: Send + Sync + 'static {
    fn resolve(&self, account: &str) -> Option<EndpointAddr>;
}

/// Default backend: fetch a resource from a peer over HTTP/3.
///
/// The peer hosts an axum router with [`idfon_h3::serve_router`]; this issues a
/// `GET <path>` over [`idfon_h3::ALPN`] and returns the response body.
pub struct IrohBackend {
    client: H3Client,
    resolver: Arc<dyn AccountResolver>,
}

impl IrohBackend {
    pub fn new(
        transport: &IrohTransport,
        resolver: impl AccountResolver,
    ) -> Result<Self, GatewayError> {
        Ok(Self {
            client: H3Client::new(transport)
                .map_err(|error| GatewayError::Backend(error.to_string()))?,
            resolver: Arc::new(resolver),
        })
    }
}

impl Backend for IrohBackend {
    async fn fetch(&self, account: &str, path: &str) -> Result<Resource, GatewayError> {
        let addr = self
            .resolver
            .resolve(account)
            .ok_or_else(|| GatewayError::UnknownAccount(account.to_owned()))?;
        // A peer's direct addresses change over time; refresh per request.
        self.client.add_address(&addr);
        let response = self
            .client
            .get(&addr, path)
            .send()
            .await
            .map_err(|error| GatewayError::Backend(error.to_string()))?;
        if response.status == StatusCode::NOT_FOUND {
            return Err(GatewayError::NotFound(path.to_owned()));
        }
        if !response.status.is_success() {
            return Err(GatewayError::Backend(format!(
                "peer returned {}",
                response.status
            )));
        }
        let content_type = response
            .headers
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("application/octet-stream")
            .to_owned();
        let body = response
            .bytes()
            .await
            .map_err(|error| GatewayError::Backend(error.to_string()))?
            .to_vec();
        if body.len() > MAX_RESOURCE_BYTES {
            return Err(GatewayError::Backend("resource too large".to_owned()));
        }
        Ok(Resource { content_type, body })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    struct Static(HashMap<(String, String), Vec<u8>>);

    impl Backend for Static {
        async fn fetch(&self, account: &str, path: &str) -> Result<Resource, GatewayError> {
            self.0
                .get(&(account.to_owned(), path.to_owned()))
                .map(|body| Resource {
                    content_type: "text/plain".to_owned(),
                    body: body.clone(),
                })
                .ok_or_else(|| GatewayError::NotFound(path.to_owned()))
        }
    }

    struct PublicOnly;

    impl Authorizer for PublicOnly {
        fn authorize(&self, _caller: &Caller, account: &str, path: &str) -> bool {
            account == "acct" && path.starts_with("/public")
        }
    }

    /// Verifies a plain `x-subject` header, so the caller-context plumbing is
    /// observable end to end.
    struct SubjectAuth;

    impl Authenticator for SubjectAuth {
        fn authenticate(&self, headers: &HeaderMap, _uri: &Uri) -> Option<Caller> {
            headers
                .get("x-subject")
                .and_then(|value| value.to_str().ok())
                .map(|subject| Caller {
                    subject: subject.to_owned(),
                })
        }
    }

    struct SubjectAlice;

    impl Authorizer for SubjectAlice {
        fn authorize(&self, caller: &Caller, _account: &str, _path: &str) -> bool {
            caller.subject == "alice"
        }
    }

    async fn gateway() -> GatewayHandle {
        let mut map = HashMap::new();
        map.insert(
            ("acct".to_owned(), "/public/readme.txt".to_owned()),
            b"hello resource".to_vec(),
        );
        serve(
            Config {
                auth: Some(Arc::new(StaticToken::new("s3cret"))),
                ..Config::default()
            },
            Static(map),
            PublicOnly,
        )
        .await
        .expect("gateway binds")
    }

    /// Minimal HTTP/1.1 client: enough to assert status + body without a dep.
    async fn get(
        addr: SocketAddr,
        path: &str,
        host: &str,
        token: Option<&str>,
        origin: Option<&str>,
    ) -> (u16, String) {
        let mut stream = tokio::net::TcpStream::connect(addr).await.expect("connect");
        let mut request = format!("GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n");
        if let Some(token) = token {
            request.push_str(&format!("Authorization: Bearer {token}\r\n"));
        }
        if let Some(origin) = origin {
            request.push_str(&format!("Origin: {origin}\r\n"));
        }
        request.push_str("\r\n");
        stream.write_all(request.as_bytes()).await.expect("write");
        let mut raw = Vec::new();
        stream.read_to_end(&mut raw).await.expect("read");
        let text = String::from_utf8_lossy(&raw);
        let status = text
            .split_whitespace()
            .nth(1)
            .and_then(|code| code.parse().ok())
            .unwrap_or(0);
        let body = text
            .split_once("\r\n\r\n")
            .map(|(_, body)| body.to_owned())
            .unwrap_or_default();
        (status, body)
    }

    #[tokio::test]
    async fn serves_an_authorized_resource_and_rejects_everything_else() {
        let handle = gateway().await;
        let addr = handle.local_addr();
        let token = Some("s3cret");

        // Virtual-host addressing: the path passes through untouched.
        let (status, body) = get(addr, "/public/readme.txt", "acct.localhost", token, None).await;
        assert_eq!(status, 200);
        assert_eq!(body, "hello resource");

        // Path-based addressing is also accepted.
        let (status, body) = get(addr, "/acct/public/readme.txt", "127.0.0.1", token, None).await;
        assert_eq!(status, 200);
        assert_eq!(body, "hello resource");

        // Authorizer denies.
        let (status, _) = get(addr, "/private/x", "acct.localhost", token, None).await;
        assert_eq!(status, 403);

        // Missing token.
        let (status, _) = get(addr, "/public/readme.txt", "acct.localhost", None, None).await;
        assert_eq!(status, 401);

        // Foreign web origin (DNS rebinding).
        let (status, _) = get(
            addr,
            "/public/readme.txt",
            "acct.localhost",
            token,
            Some("https://evil.example"),
        )
        .await;
        assert_eq!(status, 403);

        // Traversal.
        let (status, _) = get(addr, "/acct/../secret", "127.0.0.1", token, None).await;
        assert_eq!(status, 400);

        handle.shutdown();
    }

    #[tokio::test]
    async fn refuses_a_non_loopback_bind_without_a_token() {
        let mut map = HashMap::new();
        map.insert(("a".to_owned(), "/".to_owned()), b"x".to_vec());
        let result = serve(
            Config {
                bind: "0.0.0.0:0".parse().unwrap(),
                auth: None,
                origin_domain: None,
            },
            Static(map),
            PublicOnly,
        )
        .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn carries_the_verified_caller_to_the_authorizer() {
        let mut map = HashMap::new();
        map.insert(("acct".to_owned(), "/".to_owned()), b"hi".to_vec());
        let handle = serve(
            Config {
                auth: Some(Arc::new(SubjectAuth)),
                ..Config::default()
            },
            Static(map),
            SubjectAlice,
        )
        .await
        .expect("gateway binds");
        let addr = handle.local_addr();

        // Authenticator rejects (no subject header).
        let (status, _) = get(addr, "/acct/", "127.0.0.1", None, None).await;
        assert_eq!(status, 401);

        // Verified, but not alice.
        let (status, _) = get_with(addr, "/acct/", "127.0.0.1", &[("x-subject", "bob")]).await;
        assert_eq!(status, 403);

        // Verified as alice.
        let (status, body) = get_with(addr, "/acct/", "127.0.0.1", &[("x-subject", "alice")]).await;
        assert_eq!(status, 200);
        assert_eq!(body, "hi");
        handle.shutdown();
    }

    #[tokio::test]
    async fn accepts_the_edge_origin_domain() {
        let mut map = HashMap::new();
        map.insert(
            ("acct".to_owned(), "/public/readme.txt".to_owned()),
            b"hi".to_vec(),
        );
        let handle = serve(
            Config {
                auth: Some(Arc::new(StaticToken::new("s3cret"))),
                origin_domain: Some("idfon.net".to_owned()),
                ..Config::default()
            },
            Static(map),
            PublicOnly,
        )
        .await
        .expect("gateway binds");
        let addr = handle.local_addr();
        let token = Some("s3cret");

        // <ref>.idfon.net virtual host resolves the account.
        let (status, body) = get(addr, "/public/readme.txt", "acct.idfon.net", token, None).await;
        assert_eq!(status, 200);
        assert_eq!(body, "hi");

        // A matching Origin is accepted; a foreign one is not.
        let (status, _) = get(
            addr,
            "/public/readme.txt",
            "acct.idfon.net",
            token,
            Some("https://acct.idfon.net"),
        )
        .await;
        assert_eq!(status, 200);
        let (status, _) = get(
            addr,
            "/public/readme.txt",
            "acct.idfon.net",
            token,
            Some("https://evil.example"),
        )
        .await;
        assert_eq!(status, 403);

        // A host outside the configured domain is still rejected.
        let (status, _) = get(addr, "/public/readme.txt", "acct.evil.example", token, None).await;
        assert_eq!(status, 403);

        handle.shutdown();
    }

    /// HTTP GET with arbitrary extra headers.
    async fn get_with(
        addr: SocketAddr,
        path: &str,
        host: &str,
        extra: &[(&str, &str)],
    ) -> (u16, String) {
        let mut stream = tokio::net::TcpStream::connect(addr).await.expect("connect");
        let mut request = format!("GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n");
        for (name, value) in extra {
            request.push_str(&format!("{name}: {value}\r\n"));
        }
        request.push_str("\r\n");
        stream.write_all(request.as_bytes()).await.expect("write");
        let mut raw = Vec::new();
        stream.read_to_end(&mut raw).await.expect("read");
        let text = String::from_utf8_lossy(&raw);
        let status = text
            .split_whitespace()
            .nth(1)
            .and_then(|code| code.parse().ok())
            .unwrap_or(0);
        let body = text
            .split_once("\r\n\r\n")
            .map(|(_, body)| body.to_owned())
            .unwrap_or_default();
        (status, body)
    }
}
