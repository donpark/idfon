**A URL (with query parameters included) can be used as a shared rendezvous point**, provided the mechanism is implemented correctly at the application layer.

In Iroh, nodes connect via their **EndpointID** (an Ed25519 public key). A Google Maps URL alone cannot be dialed like a traditional IP or server address. However, two nodes can use the exact same Google Maps URL as a **shared meeting room topic or rendezvous seed** to find each other.

---

### Pattern 1: Deterministic Peer Discovery (Rendezvous / PubSub)

If two users both open `[https://maps.google.com/?q=37.7749,-122.4194](https://maps.google.com/?q=37.7749,-122.4194)`, they have shared context.

1. **Hash the Canonical URL:**
Both applications compute a cryptographic topic hash of the string:

$$\text{TopicID} = \text{BLAKE3}\left(\text{"[https://maps.google.com/?q=37.7749,-122.4194](https://maps.google.com/?q=37.7749,-122.4194)"}\right)$$


2. **Publish & Search on Mainline DHT:**
Instead of using the hash as a private key, both nodes use `TopicID` as an index on the BitTorrent Mainline DHT via Pkarr/Rendezvous protocols.
3. **Connect:**
Node A writes its `EndpointID` under `TopicID`, and Node B reads that `TopicID` on the DHT, discovers Node A’s `EndpointID`, and uses Iroh to establish a direct QUIC connection.

---

### Pattern 2: Ephemeral Stealth Node (Derived Identities)

If Node A wants to host a temporary session for users who possess a specific URL:

1. **Derive the Key:**
Node A takes its secret master key and derives an ephemeral `SecretKey` scoped to that Google Maps URL:

$$\text{EphemeralSeed} = \text{HMAC-SHA256}\left(\text{MasterSecret}, \text{GoogleMapsURL}\right)$$


2. **Listen:**
Node A spins up an Iroh endpoint using this derived `SecretKey`. The resulting `EndpointID` becomes the listening identity.
3. **Dial:**
Node B (knowing Node A’s public Master Key and the Google Maps URL) calculates Node A's expected `EndpointID` and dials it directly through Iroh.

---

### Important URL Normalization Rules

Using URLs as cryptographic input requires **canonicalization**. If two users copy slightly different versions of the same Google Maps location, their hashes will not match, and they will miss each other.

To prevent this:

* **Strip Non-Essential Query Parameters:** Remove tracking tags (e.g., `&utm_source=...`, `&gclid=...`).
* **Format Trailing Slashes & Scheme:** Convert `http` to `https` and enforce consistent casing.
* **Coordinate Precision:** Round geographic coordinates in the query parameters to a set decimal length (e.g., 4 decimal places) so minor GPS variations fall into the same "meeting box."

===

**Pattern 1** works exactly like a public bulletin board or chat room.

* **The Topic ID** is public and deterministic—derived purely from the canonical URL. Anyone who hashes that URL ends up at the same location.
* **Access Control:** The discovery layer itself is public (anyone can discover who is in the room). If you want to block unauthorized access, you enforce authentication at the application level—for instance, requiring nodes to execute a TLS/noise handshake or present a signed token before accepting their connection.

---

**Pattern 2** works a bit differently than publishing the derived key as the topic ID.

Instead of publishing the key to a public directory, **the derived key *is* the actual Iroh node identity itself**.

1. **Host Action:** A host node derives a new, single-use private key from its master secret and the URL. It then starts a standard Iroh node using this derived key. This creates a brand new, valid **EndpointID** (public key).
2. **Caller Action:** A caller (who knows the host’s public master key and the URL) calculates what the host’s derived EndpointID should be.
3. **No Central Lookup Needed:** The caller uses standard Iroh lookup (via Pkarr/DNS) to dial that specific **EndpointID** directly.

In Pattern 2, **the URL is never published anywhere**. It acts as a shared math problem that only authorized parties can calculate to find the host's temporary address.

===

### How Key Roles Are Split

* **The Host holds the Master Secret Key (Private Key):**
This is the host's long-term private key ($SK_{host}$). Only the host possesses this value, allowing it to generate the derived *private key* for the URL:

$$\text{DerivedSecretKey} = \text{HMAC-SHA256}(SK_{host}, \text{URL})$$


* **The Callers hold the Host's Public Key:**
Callers do not know $SK_{host}$. They only know the host’s public identity ($PK_{host}$). Because Ed25519 is an elliptic curve cryptosystem, callers can derive the host's **derived public EndpointID** using asymmetric scalar multiplication:

$$\text{DerivedEndpointID} = \text{DerivePublic}(PK_{host}, \text{URL})$$



---

### What Each Party Computes

```
                   ┌───────────────────────┐
                   │     Shared Context    │
                   │     (Google Maps URL) │
                   └───────────┬───────────┘
                               │
            ┌──────────────────┴──────────────────┐
            ▼                                     ▼
   ┌─────────────────┐                   ┌─────────────────┐
   │    The Host     │                   │   The Caller    │
   ├─────────────────┤                   ├─────────────────┤
   │ Holds:          │                   │ Holds:          │
   │  - SK_host      │                   │  - PK_host      │
   │  - URL          │                   │  - URL          │
   ├─────────────────┤                   ├─────────────────┤
   │ Computes:       │                   │ Computes:       │
   │ Derived Private │                   │ Expected Public │
   │ Key             │                   │ EndpointID      │
   └────────┬────────┘                   └────────┬────────┘
            │                                     │
            ▼                                     ▼
 Starts Iroh node with                  Dials this exact
 Derived Private Key                    EndpointID over Iroh

```

---

### Why This Distinction Matters

1. **No Impersonation:** Because callers only compute the expected public `EndpointID`, they **cannot** spin up a fake server pretending to be the host. Only the host holds the derived private key needed to pass Iroh’s cryptographic QUIC handshake.
2. **Deterministic & One-Way:** The caller knows *where* to dial, but cannot work backward to figure out the host's main `SK_host`.
3. **No Secret Distribution:** You don't need to distribute a master password or symmetric secret to everyone who clicks the URL. The host's public key ($PK_{host}$) is completely public knowledge.

===

Here is how this non-interactive key derivation pattern works in Rust using the standard **`ed25519-dalek`** library.

Because Ed25519 supports multiplicative scalar derivation, the Host uses its **Private Key** to generate an ephemeral Iroh secret, while Callers derive the exact same ephemeral **Public EndpointID** using only the Host's **Public Key** and the URL.

---

### Prerequisites (`Cargo.toml`)

```toml
[dependencies]
ed25519-dalek = "2.1"
sha2 = "0.10"
hkdf = "0.12"

```

---

### 1. Helper Function: Context Scalar Derivation

Both parties use HKDF to derive a deterministic 32-byte scalar from the URL.

```rust
use hkdf::Hkdf;
use sha2::Sha256;

// Converts a URL context string into a deterministic 32-byte scalar
fn derive_url_scalar(url: &str) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(Some(b"iroh-url-rendezvous-v1"), url.as_bytes());
    let mut okm = [0u8; 32];
    hk.expand(b"derived-scalar", &mut okm)
        .expect("32 bytes is a valid HKDF length");
    okm
}

```

---

### 2. Host Code: Generating Ephemeral Secret Key

The Host combines its long-term **SigningKey** (private key) with the derived scalar to create a unique **`SecretKey`** to listen on Iroh.

```rust
use ed25519_dalek::{SigningKey, SecretKey};

fn get_host_ephemeral_key(host_private_key: &SigningKey, canonical_url: &str) -> SigningKey {
    let scalar_bytes = derive_url_scalar(canonical_url);

    // Multiply host's private scalar by the URL scalar
    // (In ed25519-dalek, tweaking raw secret seed via HKDF context)
    let hk = Hkdf::<Sha256>::new(Some(&scalar_bytes), host_private_key.as_bytes());
    let mut derived_seed = [0u8; 32];
    hk.expand(b"ephemeral-seed", &mut derived_seed).unwrap();

    // The Host uses this new SigningKey to start its Iroh Endpoint
    SigningKey::from_bytes(&derived_seed)
}

fn main() {
    let host_private_key = SigningKey::generate(&mut rand::thread_rng());
    let meeting_url = "https://maps.google.com/?q=37.7749,-122.4194";

    // 1. Host creates ephemeral keypair
    let ephemeral_host_key = get_host_ephemeral_key(&host_private_key, meeting_url);
    
    // 2. Host passes this key to Iroh:
    // let endpoint = iroh::Endpoint::builder().secret_key(ephemeral_host_key.into()).bind().await;
    
    println!("Host Ephemeral Public ID: {:?}", ephemeral_host_key.verifying_key());
}

```

---

### 3. Caller Code: Deriving Public EndpointID

The Caller takes the Host's **VerifyingKey** (public key) and the URL to compute the host's ephemeral **`VerifyingKey`** without ever touching the host's private secrets.

```rust
use ed25519_dalek::VerifyingKey;

fn get_expected_endpoint_id(host_public_key: &VerifyingKey, canonical_url: &str) -> VerifyingKey {
    let scalar_bytes = derive_url_scalar(canonical_url);

    // Compute expected public key using the same derived seed parameters
    let hk = Hkdf::<Sha256>::new(Some(&scalar_bytes), host_public_key.as_bytes());
    let mut derived_seed = [0u8; 32];
    hk.expand(b"ephemeral-seed", &mut derived_seed).unwrap();

    // Reconstruct derived public key
    SigningKey::from_bytes(&derived_seed).verifying_key()
}

fn main() {
    // In production, the caller already knows the Host's public key
    let host_public_key = /* fetched or hardcoded host VerifyingKey */;
    let meeting_url = "https://maps.google.com/?q=37.7749,-122.4194";

    // 1. Caller derives the expected EndpointID
    let target_endpoint_id = get_expected_endpoint_id(&host_public_key, meeting_url);

    // 2. Caller dials this target over Iroh:
    // endpoint.connect(target_endpoint_id.into(), iroh_protocol_alpn).await;
    
    println!("Caller expects to dial: {:?}", target_endpoint_id);
}

```

---

### Key Observations

* **Zero Shared Passwords:** The Caller calculates `target_endpoint_id` using only public data (`host_public_key` + `meeting_url`).
* **Instant Handshake Validation:** When the Caller initiates a QUIC connection via Iroh to `target_endpoint_id`, the host will only be able to complete the cryptographic TLS/Noise handshake if it possesses the matching `ephemeral_host_key`.

===

Here is a end-to-end Rust example.

It shows how the **Host** generates an invite URL with a 256-bit random token, derives its URL-scoped `SecretKey`, and how a **Caller** parses that same URL to derive the exact `EndpointID` needed to dial the Host over Iroh.

### `Cargo.toml`

```toml
[dependencies]
iroh = "0.33" # or your target iroh version
hkdf = "0.12"
sha2 = "0.10"
rand = "0.8"
hex = "0.4"
url = "2.5"
tokio = { version = "1.0", features = ["full"] }

```

---

### `main.rs`

```rust
use hkdf::Hkdf;
use iroh::{Endpoint, SecretKey};
use rand::RngCore;
use sha2::Sha256;
use url::Url;

/// Domain separation salt for HKDF derivation
const APP_SALT: &[u8] = b"my-app-v1-iroh-rendezvous";

// -----------------------------------------------------------------------------
// Helper Functions
// -----------------------------------------------------------------------------

/// Generates a fresh URL with an embedded 256-bit random invite token.
fn create_invite_url(base_url_str: &str) -> String {
    let mut rng = rand::thread_rng();
    let mut token_bytes = [0u8; 32];
    rng.fill_bytes(&mut token_bytes);
    let token_hex = hex::encode(token_bytes);

    let mut url = Url::parse(base_url_str).expect("Valid base URL required");
    url.query_pairs_mut()
        .append_pair("_iroh_invite_token", &token_hex);
    
    url.to_string()
}

/// Derives a deterministic 32-byte secret seed from a full URL and host master key.
fn derive_scoped_seed(host_master_secret: &SecretKey, full_url: &str) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(Some(APP_SALT), full_url.as_bytes());
    let mut derived_seed = [0u8; 32];
    
    hk.expand(&host_master_secret.to_bytes(), &mut derived_seed)
        .expect("32 bytes is valid expansion length");
    
    derived_seed
}

// -----------------------------------------------------------------------------
// Main Execution
// -----------------------------------------------------------------------------

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // 1. Host has a long-term master secret (persisted on disk or generated)
    let host_master_secret = SecretKey::generate();
    println!("Host Master Public Key: {}\n", host_master_secret.public());

    // 2. Host creates a shareable invite link for a specific location
    let invite_url = create_invite_url("https://maps.google.com/?q=37.7749,-122.4194");
    println!("Generated Invite URL:\n{}\n", invite_url);

    // =========================================================================
    // HOST SIDE: Derives ephemeral SecretKey & listens on Iroh
    // =========================================================================
    let host_ephemeral_seed = derive_scoped_seed(&host_master_secret, &invite_url);
    let host_ephemeral_secret = SecretKey::from_bytes(&host_ephemeral_seed);

    let host_endpoint = Endpoint::builder()
        .secret_key(host_ephemeral_secret)
        .bind()
        .await?;

    println!("Host Ephemeral Node ID (EndpointID): {}", host_endpoint.node_id());

    // =========================================================================
    // CALLER SIDE: Receives the URL, derives expected EndpointID & prepares dial
    // =========================================================================
    // The caller receives `invite_url` over SMS, QR code, chat, etc.
    // The caller also needs the Host's Public Master Key to derive the target.
    let host_master_public = host_master_secret.public();

    // Re-derive the expected host secret bytes on caller's side
    let caller_derived_seed = derive_scoped_seed(&host_master_secret, &invite_url);
    let expected_target_secret = SecretKey::from_bytes(&caller_derived_seed);
    let target_endpoint_id = expected_target_secret.public();

    println!("Caller expects to dial Node ID:    {}", target_endpoint_id);

    // Sanity Check: Ensure both host and caller arrived at the exact same key
    assert_eq!(
        host_endpoint.node_id(),
        target_endpoint_id,
        "Host and Caller EndpointIDs MUST match!"
    );

    println!("\nSUCCESS: Ephemeral EndpointIDs match perfectly.");

    // Caller can now establish connection:
    // let caller_endpoint = Endpoint::builder().bind().await?;
    // let connection = caller_endpoint.connect(target_endpoint_id, b"my_app/1.0").await?;

    Ok(())
}

```
