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

use std::collections::HashMap;
use std::io::BufReader;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use bytes::Bytes;
use http::{header, HeaderMap, HeaderValue, StatusCode, Uri};
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::TokioIo;
use idfon_core::transport::IrohTransport;
use idfon_h3::H3Client;
use iroh::EndpointAddr;
use rustls::server::{ClientHello, ResolvesServerCert};
use rustls::sign::CertifiedKey;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tokio_rustls::TlsAcceptor;

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
        caller: &Caller,
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
    /// Opaque caller credential (e.g. an `x-idfon-ticket` value) to forward to
    /// the peer over H3. `None` for bearer-token callers.
    pub ticket: Option<String>,
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

/// A completed request, as seen by a [`RequestObserver`].
pub struct RequestEvent<'a> {
    pub method: &'a str,
    pub host: Option<&'a str>,
    pub path: &'a str,
    pub status: StatusCode,
    pub latency: Duration,
    /// Verified requester (`Caller.subject`); `None` before authentication.
    pub caller: Option<&'a str>,
    /// The resolved peer ref; `None` before it is known.
    pub account: Option<&'a str>,
}

/// Per-request logging/metrics. Called for every served request except the
/// health and metrics probes. An implementation lives on the edge; the
/// loopback gateway ignores it by default.
pub trait RequestObserver: Send + Sync + 'static {
    fn observe(&self, event: &RequestEvent<'_>);
    /// Prometheus text for [`Config::metrics_path`]; `None` disables the probe.
    fn render_metrics(&self) -> Option<String>;
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
            ticket: None,
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum GatewayError {
    #[error("unknown account {0}")]
    UnknownAccount(String),
    #[error("resource not found: {0}")]
    NotFound(String),
    #[error("refused: {0}")]
    Forbidden(String),
    #[error("backend: {0}")]
    Backend(String),
}

/// TLS termination for the gateway's HTTP listener (PEM cert chain + private
/// key). `None` serves plain HTTP.
#[derive(Debug, Clone)]
pub struct TlsConfig {
    pub cert: PathBuf,
    pub key: PathBuf,
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
    /// Serve HTTPS with this cert/key. `None` serves plain HTTP (the loopback
    /// case; a public edge should set it or terminate TLS in front).
    pub tls: Option<TlsConfig>,
    /// When set, `GET <path>` returns `200 ok` before auth/host checks, for
    /// health probes.
    pub health_path: Option<String>,
    /// When set, `GET <path>` (after auth) returns [`RequestObserver::render_metrics`].
    pub metrics_path: Option<String>,
    /// Per-request observer for logging/metrics. `None` disables both.
    pub observer: Option<Arc<dyn RequestObserver>>,
    /// Add `nosniff`, `Referrer-Policy`, and a framing CSP to every response
    /// (plus HSTS when `tls` is set). Default on.
    pub security_headers: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            bind: ([127, 0, 0, 1], 0).into(),
            auth: None,
            origin_domain: None,
            tls: None,
            health_path: None,
            metrics_path: None,
            observer: None,
            security_headers: true,
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
    let tls = config
        .tls
        .as_ref()
        .map(load_tls)
        .transpose()?
        .map(|tls| TlsAcceptor::from(Arc::new(tls)));
    let shared = Arc::new(Shared {
        backend,
        authorizer,
        auth: config.auth,
        origin_domain: config.origin_domain,
        health_path: config.health_path,
        metrics_path: config.metrics_path,
        observer: config.observer,
        security_headers: config.security_headers,
        tls: config.tls.is_some(),
    });
    let task = tokio::spawn(async move {
        while let Ok((stream, _peer)) = listener.accept().await {
            let shared = shared.clone();
            let tls = tls.clone();
            tokio::spawn(async move {
                match tls {
                    Some(acceptor) => {
                        if let Ok(stream) = acceptor.accept(stream).await {
                            let _ = serve_connection(TokioIo::new(stream), shared).await;
                        }
                    }
                    None => {
                        let _ = serve_connection(TokioIo::new(stream), shared).await;
                    }
                }
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
    health_path: Option<String>,
    metrics_path: Option<String>,
    observer: Option<Arc<dyn RequestObserver>>,
    security_headers: bool,
    tls: bool,
}

/// Serves one accepted connection (plain or TLS-wrapped) with HTTP/1.
async fn serve_connection<I, B, A>(io: I, shared: Arc<Shared<B, A>>) -> Result<(), hyper::Error>
where
    I: hyper::rt::Read + hyper::rt::Write + Unpin + Send + 'static,
    B: Backend,
    A: Authorizer,
{
    let service = service_fn(move |request| {
        let shared = shared.clone();
        async move {
            let mut response = handle(shared.clone(), request).await;
            if shared.security_headers {
                add_security_headers(&mut response, shared.tls);
            }
            Ok::<_, std::convert::Infallible>(response)
        }
    });
    hyper::server::conn::http1::Builder::new()
        .serve_connection(io, service)
        .await
}

/// Defense-in-depth response headers. HSTS only over TLS (browsers ignore it
/// on plain HTTP); the framing CSP blocks embedding without restricting the
/// resource's own scripts/styles.
fn add_security_headers(response: &mut Response<Full<Bytes>>, tls: bool) {
    let headers = response.headers_mut();
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static("frame-ancestors 'none'; base-uri 'self'; object-src 'none'"),
    );
    if tls {
        headers.insert(
            header::STRICT_TRANSPORT_SECURITY,
            HeaderValue::from_static("max-age=31536000; includeSubDomains"),
        );
    }
}

/// Loads the PEM cert chain + private key into a rustls server config that
/// re-reads the files when either changes, so a rotated certificate is served
/// without restarting the edge.
fn load_tls(config: &TlsConfig) -> std::io::Result<rustls::ServerConfig> {
    // Fail fast on an unusable cert/key, then hand handshakes to the resolver.
    // Both `ring` and `aws-lc-rs` end up enabled in this dependency graph, so
    // rustls cannot pick a process-default provider. Choose one explicitly.
    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let resolver = Arc::new(ReloadingCert::new(config.clone())?);
    Ok(rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(std::io::Error::other)?
        .with_no_client_auth()
        .with_cert_resolver(resolver))
}

/// Parses the cert/key pair from disk (the startup and reload path).
fn certified_key(config: &TlsConfig) -> std::io::Result<CertifiedKey> {
    let mut cert_reader = BufReader::new(std::fs::File::open(&config.cert)?);
    let certs = rustls_pemfile::certs(&mut cert_reader)
        .collect::<Result<Vec<_>, _>>()
        .map_err(std::io::Error::other)?;
    let mut key_reader = BufReader::new(std::fs::File::open(&config.key)?);
    let key = rustls_pemfile::private_key(&mut key_reader)
        .map_err(std::io::Error::other)?
        .ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "no private key in the TLS key file",
            )
        })?;
    let provider = rustls::crypto::aws_lc_rs::default_provider();
    CertifiedKey::from_der(certs, key, &provider).map_err(std::io::Error::other)
}

/// The newest mtime of the cert/key files; the reload trigger.
fn cert_modified_at(config: &TlsConfig) -> Option<SystemTime> {
    let cert = std::fs::metadata(&config.cert)
        .and_then(|m| m.modified())
        .ok()?;
    let key = std::fs::metadata(&config.key)
        .and_then(|m| m.modified())
        .ok()?;
    Some(cert.max(key))
}

/// A rustls cert resolver that re-reads the cert/key from disk when either file
/// changes. A reload that fails keeps serving the last good key, so a
/// half-written rotated certificate never breaks TLS.
struct ReloadingCert {
    config: TlsConfig,
    cached: Mutex<Option<(SystemTime, Arc<CertifiedKey>)>>,
}

impl ReloadingCert {
    fn new(config: TlsConfig) -> std::io::Result<Self> {
        let key = Arc::new(certified_key(&config)?);
        let at = cert_modified_at(&config).unwrap_or(SystemTime::UNIX_EPOCH);
        Ok(Self {
            config,
            cached: Mutex::new(Some((at, key))),
        })
    }

    fn load(&self) -> Option<Arc<CertifiedKey>> {
        let cached = self.cached.lock().ok()?.clone();
        let newest = cert_modified_at(&self.config);
        if let (Some((at, key)), Some(newest)) = (&cached, newest) {
            if *at == newest {
                return Some(key.clone());
            }
        }
        match certified_key(&self.config) {
            Ok(key) => {
                let key = Arc::new(key);
                let at = newest.unwrap_or_else(SystemTime::now);
                if let Ok(mut cache) = self.cached.lock() {
                    *cache = Some((at, key.clone()));
                }
                Some(key)
            }
            Err(_) => cached.map(|(_, key)| key),
        }
    }
}

impl std::fmt::Debug for ReloadingCert {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReloadingCert")
            .field("cert", &self.config.cert)
            .field("key", &self.config.key)
            .finish()
    }
}

impl ResolvesServerCert for ReloadingCert {
    fn resolve(&self, _client_hello: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        self.load()
    }
}

async fn handle<B: Backend, A: Authorizer>(
    shared: Arc<Shared<B, A>>,
    request: Request<Incoming>,
) -> Response<Full<Bytes>> {
    let started = Instant::now();
    let method = request.method().clone();
    let uri = request.uri().clone();
    let host = request
        .headers()
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let probe = shared.health_path.as_deref() == Some(uri.path())
        || shared.metrics_path.as_deref() == Some(uri.path());
    let (response, caller, account) = handle_inner(shared.clone(), request, &uri).await;
    if !probe {
        if let Some(observer) = shared.observer.as_deref() {
            observer.observe(&RequestEvent {
                method: method.as_str(),
                host: host.as_deref(),
                path: uri.path(),
                status: response.status(),
                latency: started.elapsed(),
                caller: caller.as_deref(),
                account: account.as_deref(),
            });
        }
    }
    response
}

/// Returns `(response, caller subject, account)` so the caller can observe the
/// request with the identity/target it resolved.
async fn handle_inner<B: Backend, A: Authorizer>(
    shared: Arc<Shared<B, A>>,
    request: Request<Incoming>,
    uri: &Uri,
) -> (Response<Full<Bytes>>, Option<String>, Option<String>) {
    if request.method() != http::Method::GET {
        return (
            plain(StatusCode::METHOD_NOT_ALLOWED, "method not allowed"),
            None,
            None,
        );
    }
    let headers = request.headers();
    if shared.health_path.as_deref() == Some(uri.path()) {
        return (plain(StatusCode::OK, "ok"), None, None);
    }
    if !hosts_allowed(headers, shared.origin_domain.as_deref()) {
        return (plain(StatusCode::FORBIDDEN, "host not allowed"), None, None);
    }
    let caller = match &shared.auth {
        Some(auth) => match auth.authenticate(headers, uri) {
            Some(caller) => caller,
            None => {
                return (
                    plain(StatusCode::UNAUTHORIZED, "missing or invalid credentials"),
                    None,
                    None,
                )
            }
        },
        None => Caller::anonymous(),
    };
    if shared.metrics_path.as_deref() == Some(uri.path()) {
        let subject = caller.subject.clone();
        let body = shared
            .observer
            .as_deref()
            .and_then(|observer| observer.render_metrics());
        return match body {
            Some(text) => (plain_metrics(&text), Some(subject), None),
            None => (
                plain(StatusCode::NOT_FOUND, "not found"),
                Some(subject),
                None,
            ),
        };
    }
    let subject = caller.subject.clone();
    let Some((account, path)) = target(uri, headers, shared.origin_domain.as_deref()) else {
        return (
            plain(StatusCode::BAD_REQUEST, "missing account"),
            Some(subject),
            None,
        );
    };
    if path.split('/').any(|segment| segment == "..") {
        return (
            plain(StatusCode::BAD_REQUEST, "invalid path"),
            Some(subject),
            Some(account),
        );
    }
    if !shared.authorizer.authorize(&caller, &account, &path) {
        return (
            plain(StatusCode::FORBIDDEN, "not authorized"),
            Some(subject),
            Some(account),
        );
    }
    let response = match shared.backend.fetch(&caller, &account, &path).await {
        Ok(resource) => Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, resource.content_type)
            .body(Full::new(Bytes::from(resource.body)))
            .unwrap_or_else(|_| plain(StatusCode::INTERNAL_SERVER_ERROR, "response error")),
        Err(GatewayError::UnknownAccount(account)) => plain(
            StatusCode::NOT_FOUND,
            &format!("unknown account: {account}"),
        ),
        Err(GatewayError::NotFound(path)) => plain(
            StatusCode::NOT_FOUND,
            &format!("peer has no such resource: {path}"),
        ),
        Err(GatewayError::Forbidden(message)) => {
            plain(StatusCode::FORBIDDEN, &format!("peer refused: {message}"))
        }
        Err(GatewayError::Backend(message)) => {
            plain(StatusCode::BAD_GATEWAY, &format!("backend: {message}"))
        }
    };
    (response, Some(subject), Some(account))
}

/// Prometheus text exposition (the probe body, not an app response).
fn plain_metrics(body: &str) -> Response<Full<Bytes>> {
    Response::builder()
        .status(StatusCode::OK)
        .header(
            header::CONTENT_TYPE,
            "text/plain; version=0.0.4; charset=utf-8",
        )
        .body(Full::new(Bytes::from(body.to_owned())))
        .expect("static response builds")
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
///
/// A domain edge is **subdomain-only**: the path form (`/<ref>/<path>`) gives
/// every peer the same origin, so cookies and web storage leak across peers.
/// The path form is accepted only when no `origin_domain` is configured (raw-IP
/// / localhost / dev edges, where wildcard DNS/TLS is unavailable).
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
    if origin_domain.is_some() {
        return None;
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
    cache: ResolveCache,
}

/// How long a resolver answer is reused before the peer store is read again.
const RESOLVE_TTL: Duration = Duration::from_secs(30);

impl IrohBackend {
    pub fn new(
        transport: &IrohTransport,
        resolver: impl AccountResolver,
    ) -> Result<Self, GatewayError> {
        Ok(Self {
            client: H3Client::new(transport)
                .map_err(|error| GatewayError::Backend(error.to_string()))?,
            resolver: Arc::new(resolver),
            cache: ResolveCache::new(RESOLVE_TTL),
        })
    }
}

impl Backend for IrohBackend {
    async fn fetch(
        &self,
        caller: &Caller,
        account: &str,
        path: &str,
    ) -> Result<Resource, GatewayError> {
        let addr = self
            .cache
            .resolve(account, self.resolver.as_ref())
            .ok_or_else(|| GatewayError::UnknownAccount(account.to_owned()))?;
        // Direct addresses change over time; the client refreshes its known set.
        self.client.add_address(&addr);
        let mut request = self.client.get(&addr, path);
        // Forward the caller's credential so the peer can authorize the issuer
        // rather than this transport peer (P3 transparent edge).
        if let Some(ticket) = &caller.ticket {
            request = request.header("x-idfon-ticket", ticket.clone());
        }
        let response = request
            .send()
            .await
            .map_err(|error| GatewayError::Backend(error.to_string()))?;
        if response.status == StatusCode::NOT_FOUND {
            return Err(GatewayError::NotFound(path.to_owned()));
        }
        if response.status == StatusCode::FORBIDDEN {
            return Err(GatewayError::Forbidden(path.to_owned()));
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

/// Caches a resolver's `EndpointAddr` answers for a short TTL so the peer store
/// is not re-read on every request. A miss re-resolves; `None` is not cached.
struct ResolveCache {
    ttl: Duration,
    entries: Mutex<HashMap<String, (EndpointAddr, Instant)>>,
}

impl ResolveCache {
    fn new(ttl: Duration) -> Self {
        Self {
            ttl,
            entries: Mutex::new(HashMap::new()),
        }
    }

    fn resolve(&self, account: &str, resolver: &dyn AccountResolver) -> Option<EndpointAddr> {
        let now = Instant::now();
        if let Ok(entries) = self.entries.lock() {
            if let Some((addr, at)) = entries.get(account) {
                if now.duration_since(*at) < self.ttl {
                    return Some(addr.clone());
                }
            }
        }
        let addr = resolver.resolve(account)?;
        if let Ok(mut entries) = self.entries.lock() {
            entries.insert(account.to_owned(), (addr.clone(), now));
        }
        Some(addr)
    }
}

/// Direct-first routing: try `primary`; on a transport failure, try `secondary`.
/// Definitive answers (`NotFound`, `UnknownAccount`) are returned as-is, so a
/// peer's 404 is not retried through the edge.
pub struct FallbackBackend<P, S> {
    primary: P,
    secondary: S,
}

impl<P, S> FallbackBackend<P, S> {
    pub fn new(primary: P, secondary: S) -> Self {
        Self { primary, secondary }
    }
}

impl<P: Backend, S: Backend> Backend for FallbackBackend<P, S> {
    async fn fetch(
        &self,
        caller: &Caller,
        account: &str,
        path: &str,
    ) -> Result<Resource, GatewayError> {
        match self.primary.fetch(caller, account, path).await {
            Ok(resource) => Ok(resource),
            Err(GatewayError::Backend(direct)) => {
                match self.secondary.fetch(caller, account, path).await {
                    Ok(resource) => Ok(resource),
                    Err(secondary) => Err(GatewayError::Backend(format!(
                        "direct: {direct}; edge: {secondary}"
                    ))),
                }
            }
            Err(other) => Err(other),
        }
    }
}

/// Fetches through the public edge: `GET <base>/<ref><path>` with an opaque
/// auth header (bearer token or capability ticket). The last-resort leg of
/// direct-first routing.
pub struct EdgeBackend {
    base: String,
    headers: Vec<(String, String)>,
    client: reqwest::Client,
}

impl EdgeBackend {
    pub fn new(
        base: impl Into<String>,
        headers: Vec<(String, String)>,
    ) -> Result<Self, GatewayError> {
        let client = reqwest::Client::builder()
            .build()
            .map_err(|error| GatewayError::Backend(error.to_string()))?;
        Ok(Self::with_client(base, headers, client))
    }

    pub fn with_client(
        base: impl Into<String>,
        headers: Vec<(String, String)>,
        client: reqwest::Client,
    ) -> Self {
        Self {
            base: base.into().trim_end_matches('/').to_owned(),
            headers,
            client,
        }
    }
}

impl Backend for EdgeBackend {
    async fn fetch(
        &self,
        caller: &Caller,
        account: &str,
        path: &str,
    ) -> Result<Resource, GatewayError> {
        let url = format!("{}/{}{}", self.base, account, path);
        let mut request = self.client.get(&url);
        for (name, value) in &self.headers {
            request = request.header(name, value);
        }
        if let Some(ticket) = &caller.ticket {
            request = request.header("x-idfon-ticket", ticket.clone());
        }
        let response = request
            .send()
            .await
            .map_err(|error| GatewayError::Backend(error.to_string()))?;
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(GatewayError::NotFound(path.to_owned()));
        }
        if response.status() == reqwest::StatusCode::FORBIDDEN {
            return Err(GatewayError::Forbidden(path.to_owned()));
        }
        if !response.status().is_success() {
            return Err(GatewayError::Backend(format!(
                "edge returned {}",
                response.status()
            )));
        }
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("application/octet-stream")
            .to_owned();
        let body = response
            .bytes()
            .await
            .map_err(|error| GatewayError::Backend(error.to_string()))?;
        if body.len() > MAX_RESOURCE_BYTES {
            return Err(GatewayError::Backend("resource too large".to_owned()));
        }
        Ok(Resource {
            content_type,
            body: body.to_vec(),
        })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    struct Static(HashMap<(String, String), Vec<u8>>);

    impl Backend for Static {
        async fn fetch(
            &self,
            _caller: &Caller,
            account: &str,
            path: &str,
        ) -> Result<Resource, GatewayError> {
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
                    ticket: None,
                })
        }
    }

    struct SubjectAlice;

    impl Authorizer for SubjectAlice {
        fn authorize(&self, caller: &Caller, _account: &str, _path: &str) -> bool {
            caller.subject == "alice"
        }
    }

    #[derive(Default)]
    struct TestObserver {
        events: Mutex<Vec<(String, u16, Option<String>, Option<String>)>>,
    }

    impl RequestObserver for TestObserver {
        fn observe(&self, event: &RequestEvent<'_>) {
            self.events.lock().unwrap().push((
                event.path.to_owned(),
                event.status.as_u16(),
                event.caller.map(str::to_owned),
                event.account.map(str::to_owned),
            ));
        }

        fn render_metrics(&self) -> Option<String> {
            Some("idfon_test_total 1\n".to_owned())
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
                ..Config::default()
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
    async fn observes_requests_and_serves_authenticated_metrics() {
        let mut map = HashMap::new();
        map.insert(
            ("acct".to_owned(), "/public/readme.txt".to_owned()),
            b"hi".to_vec(),
        );
        let observer = Arc::new(TestObserver::default());
        let handle = serve(
            Config {
                auth: Some(Arc::new(StaticToken::new("s3cret"))),
                health_path: Some("/healthz".to_owned()),
                metrics_path: Some("/metrics".to_owned()),
                observer: Some(observer.clone()),
                ..Config::default()
            },
            Static(map),
            PublicOnly,
        )
        .await
        .expect("gateway binds");
        let addr = handle.local_addr();

        let (status, body) = get(
            addr,
            "/acct/public/readme.txt",
            "127.0.0.1",
            Some("s3cret"),
            None,
        )
        .await;
        assert_eq!((status, body.as_str()), (200, "hi"));
        let (status, _) = get(addr, "/acct/private/x", "127.0.0.1", Some("s3cret"), None).await;
        assert_eq!(status, 403);
        // Health is a probe: served before auth and not observed.
        let (status, _) = get(addr, "/healthz", "127.0.0.1", None, None).await;
        assert_eq!(status, 200);

        {
            let events = observer.events.lock().unwrap();
            assert_eq!(events.len(), 2, "resource + denied observed, health not");
            assert_eq!(events[0].0, "/acct/public/readme.txt");
            assert_eq!(events[0].1, 200);
            assert_eq!(events[0].2.as_deref(), Some("local"));
            assert_eq!(events[0].3.as_deref(), Some("acct"));
            assert_eq!(events[1].1, 403);
        }

        // Metrics is gated by auth and is itself a probe (not counted).
        let (status, _) = get(addr, "/metrics", "127.0.0.1", None, None).await;
        assert_eq!(status, 401);
        let (status, body) = get(addr, "/metrics", "127.0.0.1", Some("s3cret"), None).await;
        assert_eq!(status, 200);
        assert!(body.starts_with("idfon_test_total 1"));
        assert_eq!(
            observer.events.lock().unwrap().len(),
            2,
            "metrics not observed"
        );

        handle.shutdown();
    }

    #[tokio::test]
    async fn domain_edge_rejects_the_path_form() {
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

        // The subdomain form works.
        let (status, body) = get(addr, "/public/readme.txt", "acct.idfon.net", token, None).await;
        assert_eq!((status, body.as_str()), (200, "hi"));

        // The path form must not: it would give every peer one origin, leaking
        // cookies/storage across peers.
        let (status, _) = get(addr, "/acct/public/readme.txt", "idfon.net", token, None).await;
        assert_ne!(status, 200, "path form must be rejected on a domain edge");
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

    struct CountingResolver {
        calls: std::sync::atomic::AtomicUsize,
        addr: EndpointAddr,
    }

    impl AccountResolver for CountingResolver {
        fn resolve(&self, account: &str) -> Option<EndpointAddr> {
            self.calls
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            (account == "acct").then(|| self.addr.clone())
        }
    }

    #[test]
    fn resolve_cache_serves_within_ttl_and_skips_misses() {
        let addr = EndpointAddr::new(iroh::SecretKey::from_bytes(&[7u8; 32]).public());
        let resolver = CountingResolver {
            calls: std::sync::atomic::AtomicUsize::new(0),
            addr,
        };
        let cache = ResolveCache::new(Duration::from_secs(60));

        assert!(cache.resolve("acct", &resolver).is_some());
        assert!(cache.resolve("acct", &resolver).is_some());
        assert_eq!(
            resolver.calls.load(std::sync::atomic::Ordering::Relaxed),
            1,
            "the second hit is served from the cache"
        );

        // Unknown refs are not cached.
        assert!(cache.resolve("nope", &resolver).is_none());
        assert!(cache.resolve("nope", &resolver).is_none());
        assert_eq!(resolver.calls.load(std::sync::atomic::Ordering::Relaxed), 3);
    }

    struct FailBackend;

    impl Backend for FailBackend {
        async fn fetch(
            &self,
            _caller: &Caller,
            _account: &str,
            _path: &str,
        ) -> Result<Resource, GatewayError> {
            Err(GatewayError::Backend("direct transport failed".to_owned()))
        }
    }

    #[tokio::test]
    async fn fallback_tries_the_secondary_only_on_transport_failure() {
        let mut primary = HashMap::new();
        primary.insert(("acct".to_owned(), "/x".to_owned()), b"direct".to_vec());
        let mut secondary = HashMap::new();
        secondary.insert(("acct".to_owned(), "/x".to_owned()), b"edge".to_vec());

        // Primary succeeds: the secondary is never consulted.
        let backend = FallbackBackend::new(Static(primary), Static(HashMap::new()));
        assert_eq!(
            backend
                .fetch(&Caller::anonymous(), "acct", "/x")
                .await
                .unwrap()
                .body,
            b"direct"
        );

        // Primary transport failure: the secondary serves.
        let backend = FallbackBackend::new(FailBackend, Static(secondary));
        assert_eq!(
            backend
                .fetch(&Caller::anonymous(), "acct", "/x")
                .await
                .unwrap()
                .body,
            b"edge"
        );

        // A definitive primary 404 is not retried through the secondary.
        let backend = FallbackBackend::new(Static(HashMap::new()), FailBackend);
        assert!(matches!(
            backend.fetch(&Caller::anonymous(), "acct", "/x").await,
            Err(GatewayError::NotFound(_))
        ));
    }

    #[tokio::test]
    async fn edge_backend_fetches_through_a_gateway() {
        let mut map = HashMap::new();
        map.insert(
            ("acct".to_owned(), "/public/readme.txt".to_owned()),
            b"via edge".to_vec(),
        );
        let handle = serve(
            Config {
                auth: Some(Arc::new(StaticToken::new("tok"))),
                ..Config::default()
            },
            Static(map),
            PublicOnly,
        )
        .await
        .expect("gateway binds");

        let backend = EdgeBackend::new(
            format!("http://{}", handle.local_addr()),
            vec![("Authorization".to_owned(), "Bearer tok".to_owned())],
        )
        .expect("backend builds");
        let resource = backend
            .fetch(&Caller::anonymous(), "acct", "/public/readme.txt")
            .await
            .expect("fetches");
        assert_eq!(resource.body, b"via edge");

        // A peer's explicit refusal stays a Forbidden, not a generic backend
        // error, so a client can tell "denied" from "transport failed".
        assert!(matches!(
            backend
                .fetch(&Caller::anonymous(), "acct", "/private/x")
                .await,
            Err(GatewayError::Forbidden(_))
        ));

        // The edge enforces its auth; a missing credential is a backend error.
        let unauthenticated =
            EdgeBackend::new(format!("http://{}", handle.local_addr()), vec![]).unwrap();
        assert!(matches!(
            unauthenticated
                .fetch(&Caller::anonymous(), "acct", "/public/readme.txt")
                .await,
            Err(GatewayError::Backend(_))
        ));

        handle.shutdown();
    }

    // Throwaway self-signed localhost cert/key for the TLS test only.
    const TEST_CERT: &str = "-----BEGIN CERTIFICATE-----\nMIIDBjCCAe6gAwIBAgIUJwjjiqFWM9QftAcJGMI/keSP1zAwDQYJKoZIhvcNAQEL\nBQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAwNzE4NDQxOFoYDzIxMjYw\nOTEzMTg0NDE4WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB\nAQUAA4IBDwAwggEKAoIBAQCz4P/Pr9In6Gbqt7Xk9GMlEvS9b95bKHjwd2IRydju\nCLXBwiotoOLandPED0iiehLJktnelsClFETszGh40mmsOIoX4DOVin1CqrV6pH5U\nmX8vjhKNoRN2WnVBz7tEGbNGaFQl2qvHwzvLHe6Lif3feB5mirBNOMOb3qHKO83b\nCOyDdTNQ8XFQ1OBgzd36aPBusTRIccPoPbQt4ZmZbAYmZ+vpl3q+2BLFHRPcURjO\n4gZbKT6TWDorl5z3pkTaPbQ2xQ7qxBZzripek61fPaXFScgKxByAD2ilv+qHahiF\nX6Es+JQ49BXzfsFI6cUV1x9SBCnzxeywzMJMBCp3jXYHAgMBAAGjTjBMMB0GA1Ud\nDgQWBBR9vfFbO8cxxGppa9N0GMLAvne/4TAPBgNVHRMBAf8EBTADAQH/MBoGA1Ud\nEQQTMBGCCWxvY2FsaG9zdIcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEAJJPmLa0F\nsPl5K7QbyQ9LCKe6kw5UkSvHY3wipoZDIykVIhPBoPeGr+uKjtfGS8vKQ+olpeLS\na0zN/MCP83arhSv4186jj39KX7MPFOpDs/i3X3sZWZnKbXjYZPe+xR4nS8xl9Z5V\n/SPFg5eGJeolXV8hUOCxABwFTWw5SDyZCT01dYzJb2PQDMxbt64FVdkBMey8YpG3\nOmgQEmf3eF6cKRMMlTrenWufRajk6iBEpmF1dg+OtGrpYfciEzuGghwxLKCZMY4M\nrdo21Z4idz9R6qNA5qmtBjmtYsPbHkikvQEf6biKIim78TlFjysuTCCGwCvxFndP\n8bpmxClB2xrKUg==\n-----END CERTIFICATE-----\n";
    const TEST_KEY: &str = "-----BEGIN PRIVATE KEY-----\nMIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCz4P/Pr9In6Gbq\nt7Xk9GMlEvS9b95bKHjwd2IRydjuCLXBwiotoOLandPED0iiehLJktnelsClFETs\nzGh40mmsOIoX4DOVin1CqrV6pH5UmX8vjhKNoRN2WnVBz7tEGbNGaFQl2qvHwzvL\nHe6Lif3feB5mirBNOMOb3qHKO83bCOyDdTNQ8XFQ1OBgzd36aPBusTRIccPoPbQt\n4ZmZbAYmZ+vpl3q+2BLFHRPcURjO4gZbKT6TWDorl5z3pkTaPbQ2xQ7qxBZzripe\nk61fPaXFScgKxByAD2ilv+qHahiFX6Es+JQ49BXzfsFI6cUV1x9SBCnzxeywzMJM\nBCp3jXYHAgMBAAECggEAGJ2jVEAa0dRHdTpzvWPGR5YLAPuUocPtnPaxaH7HXXe6\nq8vO6tSYBtPPXYa76WQsOwKKJyBZN54I+qDUcShWRresCi1n0cCUeLGUyTZGhXxF\n//OAzXnsCGfDoSB035Jmyq1PSqjclic9AQRVFypooBK3kk/LZZ3tguCaImtBtgYM\n7T3gH6aR9VlOHAOVMA4gjmuiUClpiIUXLgVwFH8QcLI6E6DR/IIdu9Xlc/SP5Lkq\nTZQMnaiManYAT89MScVn84WNY97u1zgIox9nnmDt8Vr4fBjD5TKphbuwtxc0DSNf\nucVxUYsW69BwLS2EiGdcQVs2aN4X4Y7SXmLmXKtIoQKBgQDy0XLDgItM/fncy3CG\n5gQkkCpe0zpi/TkqKqmR0Jf6VfpbvvhIeUu1jnixnPTkHcC1OhLLPEgFFViMY9Ut\nUFy/FrIpmzUqB+3PuxFY5KeCxk+JXo479mfY2wjlVRPbMJ9dHsbfl+ZCmBUnJnLA\nqiLbzH1Q9F9Ewa3MFLLUS9kO4QKBgQC9pNsxL9/SxlakCVIPM3g0DgThBi/HvJng\noJD1GqWFSp8fZFPDwLp/yDNIZ6LFkyvSCvhUqcte3H09p4JdJFrveb7ruJ7uTO1U\nbQRJGIkGkm0DDk9srWBLX8DP/wfd9GMvxUIv+DsnsbEbH4w/jXX9Xh9H+c5ksYuE\nni8TiC8p5wKBgGz2Qjqq11fgbJyBCmjulRNXQjw1K3E6UsmyRU+yvFBQ/rzm8IGN\nNMUvPsftOBOZql1oxwA+d88YKhktv37LHiN96ssy4+ONlVDvkDREv0q29QAe11Lf\nGvC8Mby/td5ZbloaMoIppuFhX7Sm0z3T2zqpA98tGgc/pl77Nth/hNLhAoGAPpxf\n9aRNrCPpVOzy16vxgpYiTDyjp7j/wKaiVRnADfquAEo6UYWezTNGox/8IGjPbeBL\nToBkcWQwQRu9sYygLTIvs1lXt2tUa6w2Xv+ntbDAJuMhm8q94QSy/ri/WyslWA8z\nI+07coZ6526J+i11B/p8L2ItHxdy7YzgE/3BPH8CgYA1n88J7KuMtvr2E7STB97E\nz2DVuTW6F/4qVL+W20Nq2y9RiYHghKNkkg/o/hIeKe3RIxIr5oz9mkFKDB4kMX0d\nUFVtUDNk38bK5lZpYjD6rofmFtoTOeM7f+T0LOPmLAeX78Fd3U/qJJ3vT4K42MZs\nLM6YOpxFZLwnEmDMr2WEfQ==\n-----END PRIVATE KEY-----\n";

    #[tokio::test]
    async fn serves_https_and_health_checks() {
        let dir = std::env::temp_dir().join(format!("idfon-gw-tls-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let cert = dir.join("cert.pem");
        let key = dir.join("key.pem");
        std::fs::write(&cert, TEST_CERT).unwrap();
        std::fs::write(&key, TEST_KEY).unwrap();

        let mut map = HashMap::new();
        map.insert(
            ("acct".to_owned(), "/public/readme.txt".to_owned()),
            b"tls resource".to_vec(),
        );
        let handle = serve(
            Config {
                auth: Some(Arc::new(StaticToken::new("s3cret"))),
                tls: Some(TlsConfig { cert, key }),
                health_path: Some("/healthz".to_owned()),
                ..Config::default()
            },
            Static(map),
            PublicOnly,
        )
        .await
        .expect("gateway binds");
        let addr = handle.local_addr();

        let client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .build()
            .expect("client builds");

        // Health bypasses auth over TLS.
        let response = client
            .get(format!("https://{addr}/healthz"))
            .send()
            .await
            .expect("health request");
        assert_eq!(response.status(), 200);
        assert_eq!(response.text().await.unwrap(), "ok");

        // A resource needs the token.
        let response = client
            .get(format!("https://{addr}/acct/public/readme.txt"))
            .bearer_auth("s3cret")
            .send()
            .await
            .expect("resource request");
        assert_eq!(response.status(), 200);
        // Security headers ride every response; HSTS only over TLS.
        let headers = response.headers().clone();
        assert_eq!(
            headers
                .get("x-content-type-options")
                .and_then(|v| v.to_str().ok()),
            Some("nosniff")
        );
        assert!(headers.get("content-security-policy").is_some());
        assert!(headers.get("strict-transport-security").is_some());
        assert_eq!(response.text().await.unwrap(), "tls resource");

        let response = client
            .get(format!("https://{addr}/acct/public/readme.txt"))
            .send()
            .await
            .expect("unauthenticated request");
        assert_eq!(response.status(), 401);

        // Plain HTTP against the TLS port never gets an HTTP response.
        let (status, _) = get(
            addr,
            "/acct/public/readme.txt",
            "127.0.0.1",
            Some("s3cret"),
            None,
        )
        .await;
        assert_eq!(status, 0);

        handle.shutdown();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn reloading_cert_reloads_on_change_and_keeps_the_last_good_key() {
        let dir = std::env::temp_dir().join(format!("idfon-gw-reload-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let cert = dir.join("cert.pem");
        let key = dir.join("key.pem");
        std::fs::write(&cert, TEST_CERT).unwrap();
        std::fs::write(&key, TEST_KEY).unwrap();

        let resolver = ReloadingCert::new(TlsConfig {
            cert: cert.clone(),
            key: key.clone(),
        })
        .expect("initial cert loads");
        let first = resolver.load().expect("initial key");
        // Unchanged files are served from the cache.
        let again = resolver.load().expect("cached key");
        assert!(Arc::ptr_eq(&first, &again), "unchanged files stay cached");

        // A newer mtime invalidates the cache and re-reads from disk.
        let later = SystemTime::now() + Duration::from_secs(30);
        std::fs::File::options()
            .write(true)
            .open(&key)
            .unwrap()
            .set_modified(later)
            .unwrap();
        let reloaded = resolver.load().expect("reloaded key");
        assert!(
            !Arc::ptr_eq(&first, &reloaded),
            "mtime change invalidates the cache"
        );

        // A half-written rotated key must not drop TLS: keep the last good key.
        std::fs::write(&key, "-----BEGIN PRIVATE KEY-----\nnot a key\n").unwrap();
        std::fs::File::options()
            .write(true)
            .open(&key)
            .unwrap()
            .set_modified(later + Duration::from_secs(30))
            .unwrap();
        let fallback = resolver.load().expect("fallback key");
        assert!(
            Arc::ptr_eq(&reloaded, &fallback),
            "a failed reload keeps the last good key"
        );

        let _ = std::fs::remove_dir_all(dir);
    }
}
