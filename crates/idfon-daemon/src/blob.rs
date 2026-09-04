use std::{
    path::PathBuf,
    sync::{Mutex, OnceLock},
};

use iroh::protocol::Router;
use iroh::{endpoint::presets, Endpoint};
use iroh_blobs::{store::fs::FsStore, ticket::BlobTicket, BlobsProtocol, ALPN as BLOBS_ALPN};

struct BlobProvider {
    endpoint: Endpoint,
    store: FsStore,
    #[allow(dead_code)]
    router: Router,
}

static PROVIDER: OnceLock<Mutex<Option<BlobProvider>>> = OnceLock::new();

/// Shared runtime for the blocking `run_*` entry points. The blob provider's
/// endpoint/router tasks live on this runtime; a runtime dropped after
/// `block_on` returns would tear them down and leave the blob unservable.
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| tokio::runtime::Runtime::new().expect("tokio runtime"))
}

pub async fn put(root: PathBuf, data: Vec<u8>) -> anyhow::Result<(BlobTicket, usize)> {
    // One provider (endpoint + FsStore + router) per process, created lazily
    // and reused. The store locks blobs.db: opening a second FsStore on the
    // same root while this one is alive deadlocks, and the provider must stay
    // alive anyway to serve fetchers. The lock is held across add_slice to
    // serialize store access.
    let mut guard = PROVIDER
        .get_or_init(|| Mutex::new(None))
        .lock()
        .expect("blob provider poisoned");
    let (endpoint, store) = match guard.as_ref() {
        Some(provider) => (provider.endpoint.clone(), provider.store.clone()),
        None => {
            let endpoint = Endpoint::bind(presets::N0).await?;
            let store = FsStore::load(root).await?;
            let protocol = BlobsProtocol::new(store.as_ref(), None);
            let router = Router::builder(endpoint.clone())
                .accept(BLOBS_ALPN, protocol)
                .spawn();
            let provider = BlobProvider {
                endpoint: endpoint.clone(),
                store: store.clone(),
                router,
            };
            *guard = Some(provider);
            (endpoint, store)
        }
    };
    let content = store
        .blobs()
        .add_slice(&data)
        .with_named_tag(format!("resource-{}", blake3::hash(&data)))
        .await?;
    let ticket = BlobTicket::new(endpoint.addr(), content.hash, content.format);
    Ok((ticket, data.len()))
}

pub async fn fetch(ticket: String, root: PathBuf) -> anyhow::Result<PathBuf> {
    let ticket: BlobTicket = ticket.parse()?;
    // The sender's first pkarr publish may still be propagating when the fetch
    // arrives; the lookup then fails and DNS negative caching would poison
    // retries on the same endpoint. Rebind a fresh endpoint per attempt so
    // each gets a clean resolver.
    // ponytail: 6 attempts x 1s; awaiting publish completion on the sender
    // would remove the guesswork.
    let mut last = None;
    for attempt in 0..6 {
        if attempt > 0 {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
        let endpoint = Endpoint::bind(presets::N0).await?;
        let result = fetch_with(&ticket, &endpoint, &root).await;
        endpoint.close().await;
        match result {
            Ok(path) => return Ok(path),
            Err(error) => last = Some(error),
        }
    }
    Err(last.expect("at least one attempt"))
}

async fn fetch_with(
    ticket: &BlobTicket,
    endpoint: &Endpoint,
    root: &PathBuf,
) -> anyhow::Result<PathBuf> {
    let store = FsStore::load(root).await?;
    // The downloader has no internal timeout; a stuck connection must not hang
    // the daemon request (and worker) indefinitely.
    tokio::time::timeout(
        std::time::Duration::from_secs(30),
        store
            .downloader(endpoint)
            .download(ticket.hash(), Some(ticket.addr().id)),
    )
    .await??;
    let output = root.join(format!("{}.blob", ticket.hash()));
    store.blobs().export(ticket.hash(), &output).await?;
    Ok(output)
}

pub fn run_fetch(ticket: String, root: PathBuf) -> anyhow::Result<PathBuf> {
    // block_on on a fresh thread: the daemon calls this from tokio workers,
    // where blocking panics ("cannot start a runtime from within a runtime").
    std::thread::spawn(move || runtime().block_on(fetch(ticket, root)))
        .join()
        .map_err(|_| anyhow::anyhow!("blob worker panicked"))?
}

pub fn run_put(root: PathBuf, data: Vec<u8>) -> anyhow::Result<(BlobTicket, usize)> {
    std::thread::spawn(move || runtime().block_on(put(root, data)))
        .join()
        .map_err(|_| anyhow::anyhow!("blob worker panicked"))?
}
