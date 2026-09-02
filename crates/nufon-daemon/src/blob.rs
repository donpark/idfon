use std::{
    path::PathBuf,
    sync::{Mutex, OnceLock},
};

use iroh::protocol::Router;
use iroh::{endpoint::presets, Endpoint};
use iroh_blobs::{store::fs::FsStore, ticket::BlobTicket, BlobsProtocol, ALPN as BLOBS_ALPN};

#[allow(dead_code)]
pub struct BlobProvider {
    pub endpoint: Endpoint,
    pub store: FsStore,
    pub router: Router,
}

static PROVIDER: OnceLock<Mutex<Option<BlobProvider>>> = OnceLock::new();

pub async fn put(root: PathBuf, data: Vec<u8>) -> anyhow::Result<(BlobTicket, usize)> {
    let endpoint = Endpoint::bind(presets::N0).await?;
    let store = FsStore::load(root).await?;
    let content = store
        .blobs()
        .add_slice(&data)
        .with_named_tag(format!("resource-{}", blake3::hash(&data)))
        .await?;
    let protocol = BlobsProtocol::new(store.as_ref(), None);
    let router = Router::builder(endpoint.clone())
        .accept(BLOBS_ALPN, protocol)
        .spawn();
    let ticket = BlobTicket::new(endpoint.addr(), content.hash, content.format);
    PROVIDER
        .get_or_init(|| Mutex::new(None))
        .lock()
        .expect("blob provider poisoned")
        .replace(BlobProvider {
            endpoint,
            store,
            router,
        });
    Ok((ticket, data.len()))
}

pub async fn fetch(ticket: String, root: PathBuf) -> anyhow::Result<PathBuf> {
    let ticket: BlobTicket = ticket.parse()?;
    let endpoint = Endpoint::bind(presets::N0).await?;
    let store = FsStore::load(&root).await?;
    store
        .downloader(&endpoint)
        .download(ticket.hash(), Some(ticket.addr().id))
        .await?;
    let output = root.join(format!("{}.blob", ticket.hash()));
    store.blobs().export(ticket.hash(), &output).await?;
    endpoint.close().await;
    Ok(output)
}

pub fn run_fetch(ticket: String, root: PathBuf) -> anyhow::Result<PathBuf> {
    std::thread::spawn(move || {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(fetch(ticket, root))
    })
    .join()
    .map_err(|_| anyhow::anyhow!("blob worker panicked"))?
}

pub fn run_put(root: PathBuf, data: Vec<u8>) -> anyhow::Result<(BlobTicket, usize)> {
    std::thread::spawn(move || {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(put(root, data))
    })
    .join()
    .map_err(|_| anyhow::anyhow!("blob worker panicked"))?
}
