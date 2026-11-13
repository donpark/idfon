use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, OnceLock,
    },
};

use iroh::protocol::Router;
use iroh::{address_lookup::memory::MemoryLookup, Endpoint};
use iroh_blobs::{
    store::fs::FsStore, ticket::BlobTicket, BlobFormat, BlobsProtocol, ALPN as BLOBS_ALPN,
};

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
            let endpoint = idfon_core::relay::endpoint_builder().bind().await?;
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
    // The ticket carries the address, so it must be minted after the endpoint
    // knows one (same wait as the other bind sites). A ticket built mid-connect
    // has no route and forces the receiver into the retry loop in `fetch`.
    let _ = tokio::time::timeout(std::time::Duration::from_secs(5), endpoint.online()).await;
    let ticket = BlobTicket::new(endpoint.addr(), content.hash, content.format);
    Ok((ticket, data.len()))
}

pub async fn fetch(ticket: String, root: PathBuf) -> anyhow::Result<PathBuf> {
    let ticket: BlobTicket = ticket.parse()?;
    // A collection ticket (what `sendme send` prints) names a HashSeq, not a
    // file: `export` would write the 32-byte entries. Refuse instead of
    // handing the caller that as the payload.
    if ticket.format() != BlobFormat::Raw {
        anyhow::bail!(
            "ticket names a {:?} blob; only single-file (Raw) tickets are supported",
            ticket.format()
        );
    }
    let output = root.join(format!("{}.blob", ticket.hash()));
    // A completed transfer is the cache for all later chunk requests: check it
    // before binding an endpoint or opening the store, so a cache hit costs one
    // local read and no network, no blobs.db lock, and no retry sleep.
    if cache_matches(&output, ticket.hash()) {
        return Ok(output);
    }
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
        // The ticket carries the provider's own addresses (direct and relay).
        // Seed them so the download does not depend on pkarr having propagated —
        // that race was the PeerOffline failure for freshly published blobs.
        let lookup = MemoryLookup::from_endpoint_info([ticket.addr().clone()]);
        let endpoint = idfon_core::relay::endpoint_builder()
            .address_lookup(lookup)
            .bind()
            .await?;
        let result = fetch_with(&ticket, &endpoint, &root, &output).await;
        endpoint.close().await;
        match result {
            Ok(path) => return Ok(path),
            Err(error) => last = Some(error),
        }
    }
    Err(last.expect("at least one attempt"))
}

/// True only for a cache file whose bytes hash to the blob's hash. Exports can
/// be interrupted, and older builds wrote the target non-atomically, so the
/// file's presence alone proves nothing.
fn cache_matches(path: &Path, hash: iroh_blobs::Hash) -> bool {
    use std::io::Read;
    let Ok(mut file) = std::fs::File::open(path) else {
        return false;
    };
    let mut hasher = blake3::Hasher::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        match file.read(&mut buf) {
            Ok(0) => return hasher.finalize().as_bytes() == hash.as_bytes(),
            Ok(n) => {
                hasher.update(&buf[..n]);
            }
            Err(_) => return false,
        }
    }
}

/// Waits until a direct IP path is selected, or `limit` elapses. The relay
/// path already works; this only decides whether the transfer starts before or
/// after hole punching wins.
async fn wait_for_direct_path(
    conn: &iroh::endpoint::Connection,
    limit: std::time::Duration,
) -> bool {
    let deadline = tokio::time::Instant::now() + limit;
    loop {
        if conn.paths().iter().any(|path| path.is_ip() && path.is_selected()) {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
}

async fn fetch_with(
    ticket: &BlobTicket,
    endpoint: &Endpoint,
    root: &PathBuf,
    output: &Path,
) -> anyhow::Result<PathBuf> {
    static NEXT_TMP: AtomicU64 = AtomicU64::new(0);
    let store = FsStore::load(root).await?;
    let result = async {
        // Dial before the downloader does, so hole punching starts while the
        // transfer is still being set up. Paths opened on this connection are
        // opened on the downloader's connection too, so a direct path found
        // here is what keeps a short transfer off the relay.
        let prewarm = match endpoint.connect(ticket.addr().clone(), BLOBS_ALPN).await {
            Ok(conn) => {
                let direct =
                    wait_for_direct_path(&conn, std::time::Duration::from_secs(2)).await;
                tracing::debug!(target: "idfon.blob", direct, "blob fetch prewarm");
                Some(conn)
            }
            Err(error) => {
                tracing::debug!(target: "idfon.blob", %error, "blob fetch prewarm failed");
                None
            }
        };
        // The downloader has no internal timeout; a stuck connection must not
        // hang the daemon request (and worker) indefinitely.
        tokio::time::timeout(
            std::time::Duration::from_secs(30),
            store
                .downloader(endpoint)
                .download(ticket.hash(), Some(ticket.addr().id)),
        )
        .await??;
        // Copy the verified blob out ourselves instead of `export`: write to a
        // unique temp file, fsync, then rename. A reader therefore never sees a
        // half-written cache file, and concurrent fetches cannot interleave.
        let tmp = root.join(format!(
            "{}.blob.tmp.{}.{}",
            ticket.hash(),
            std::process::id(),
            NEXT_TMP.fetch_add(1, Ordering::Relaxed)
        ));
        let write = async {
            let mut reader = store.blobs().reader(ticket.hash());
            let mut file = tokio::fs::File::create(&tmp).await?;
            tokio::io::copy(&mut reader, &mut file).await?;
            file.sync_all().await?;
            drop(file);
            tokio::fs::rename(&tmp, output).await?;
            Ok::<_, std::io::Error>(())
        }
        .await;
        if let Err(error) = write {
            let _ = tokio::fs::remove_file(&tmp).await;
            return Err(error.into());
        }
        drop(prewarm);
        Ok::<PathBuf, anyhow::Error>(output.to_path_buf())
    }
    .await;
    // `Drop` shuts the store down in the background: pending DB commits are
    // lost and blobs.db stays locked for a moment (the per-request retry loop
    // used to eat that as a 1s sleep). Close it deliberately; the cache file is
    // already durable, so a failure (or a stuck shutdown) must not fail the
    // fetch or hang the request.
    let _ = tokio::time::timeout(std::time::Duration::from_secs(5), store.shutdown()).await;
    result
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Fails before any network work: a collection ticket is never kept.
    #[test]
    fn rejects_collection_ticket() {
        let id = iroh::SecretKey::generate().public();
        let hashseq = BlobTicket::new(
            iroh::EndpointAddr::new(id),
            iroh_blobs::Hash::new(b"entries"),
            BlobFormat::HashSeq,
        );
        let error = runtime()
            .block_on(fetch(
                hashseq.to_string(),
                std::env::temp_dir().join("idfon-blob-guard-test"),
            ))
            .unwrap_err();
        assert!(error.to_string().contains("Raw"), "{error}");
    }

    /// A second fetch of the same ticket must come from the verified cache
    /// file, not the network and not the store's own copy (a chunked transfer
    /// asks for the same blob once per chunk).
    #[test]
    fn second_fetch_uses_verified_cache() {
        runtime().block_on(async {
            let base =
                std::env::temp_dir().join(format!("idfon-blob-cache-test-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&base);
            // Provider side, built by hand so we can shut it down.
            let provider = idfon_core::relay::endpoint_builder().bind().await.unwrap();
            let provider_store = FsStore::load(base.join("blobs")).await.unwrap();
            let protocol = BlobsProtocol::new(provider_store.as_ref(), None);
            let router = iroh::protocol::Router::builder(provider.clone())
                .accept(BLOBS_ALPN, protocol)
                .spawn();
            let data = vec![7u8; 512 * 1024];
            let content = provider_store.blobs().add_slice(&data).await.unwrap();
            let _ =
                tokio::time::timeout(std::time::Duration::from_secs(5), provider.online()).await;
            let ticket = BlobTicket::new(provider.addr(), content.hash, content.format);
            let fetch_root = base.join("fetched");

            let first = fetch(ticket.to_string(), fetch_root.clone()).await.unwrap();
            // Keep only the cache file, so the store's local copy cannot be
            // what makes the second fetch succeed.
            let bytes = std::fs::read(&first).unwrap();
            std::fs::remove_dir_all(&fetch_root).unwrap();
            std::fs::create_dir_all(&fetch_root).unwrap();
            std::fs::write(fetch_root.join(first.file_name().unwrap()), &bytes).unwrap();

            router.shutdown().await.ok();
            provider.close().await;
            drop(provider_store);
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;

            let second = tokio::time::timeout(
                std::time::Duration::from_secs(3),
                fetch(ticket.to_string(), fetch_root.clone()),
            )
            .await
            .expect("cache miss: the second fetch needed the network")
            .unwrap();
            assert_eq!(second, fetch_root.join(format!("{}.blob", ticket.hash())));
            let _ = std::fs::remove_dir_all(&base);
        });
    }

    /// A truncated or tampered cache file must not be served.
    #[test]
    fn cache_rejects_corrupt_file() {
        let root =
            std::env::temp_dir().join(format!("idfon-blob-cache-corrupt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let data = b"cache me";
        let hash = iroh_blobs::Hash::new(data);
        let path = root.join(format!("{hash}.blob"));
        std::fs::write(&path, data).unwrap();
        assert!(cache_matches(&path, hash));
        std::fs::write(&path, b"cache m3").unwrap();
        assert!(!cache_matches(&path, hash));
        let _ = std::fs::remove_dir_all(&root);
    }
}
