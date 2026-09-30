# idfon:// resource routing — research notes

> **Status:** historical research Q&A, corrected. The conclusion it led to is
> implemented: `idfon://` addressing, a loopback gateway library, and
> multimodal artifacts. See `docs/idfon-gateway.md` and
> `docs/idfon-artifacts.md`. Written 2026-09-29; corrected 2026-09-29.

## Corrections and outcome

The Q&A below is kept as the working record, but several answers are wrong or
overstated. What actually holds:

- **Scheme:** `idfon://`, not `iroh://`. iOS already registered it; macOS now
  does too (`CFBundleURLTypes`), so `idfon://` already served a purpose before
  resources.
- **HTTP/3 over iroh is not `h3-quinn`.** iroh 1.2 uses the `noq` fork, whose
  stream types do not match upstream `quinn`, which `h3-quinn` requires. The
  adapter that exists is `iroh-h3` / `iroh-h3-axum` (third-party, iroh `^1.0`,
  `h3 0.0.8`). It has no consumer in this stack: Eve's MCP client
  (`defineMcpClientConnection`) takes a URL only and Node speaks HTTP/1.1–2,
  and the artifact WebView speaks loopback HTTP. H3 is deferred; the **loopback
  gateway** is idfon's HTTP surface.
- **Node id as a URL host:** iroh's `EndpointId` displays as 64 hex, which
  exceeds the 63-character DNS label limit; z-base-32 (`to_z32`, 52 chars) is
  the DNS-friendly form. Deeplinks need no DNS, so hex is fine. Note `FromStr`
  accepts hex or RFC 4648 base32, while `from_z32` is a separate method.
- **No DNS/PKARR/`.iroh`/meta-tag naming layer was needed.** The daemon contact
  book already resolves refs (peer id, name, alias, endpoint id), and tickets
  carry `account_id`. A *derived* `blake3(account_id)` handle is stored as a
  reserved alias, so `idfon://<handle>` resolves with no ticket field or
  protocol bump. Ownership via `<meta>` tags is a claim, not proof, and adds a
  spoofing surface; grants are key-bound, so a name must never be an
  authorization input.
- **MCP resources are not at well-known places.** They are server-defined URIs,
  discovered with `resources/list` / `resources/templates/list` and read with
  `resources/read`; custom schemes are explicitly allowed (RFC 3986). The
  2026-07-28 revision removed HTTP GET streams and protocol sessions, and
  `x-mcp-header` promotes tool params to `Mcp-Param-{name}` (not a raw
  `x-mcp-header` header).
- **"Just expose Eve's resources" does not work.** vercel/eve is an MCP
  **client** (its runtime handles `resources/list`/`read`); it has no
  `defineResource` and serves no resource catalog — it exposes tools, channels,
  and a workspace. idfon would have to synthesize resources for it. (Python
  Eve, a different framework, does have resource/item/sub-resource REST
  routes.)
- **Certificate claim:** over H3-on-iroh the QUIC handshake already
  authenticated the peer; there is no extra Web-PKI trust step. TLS exists only
  on the loopback hop for external tools.
- **QUIC batching:** "automatic UDP coalescing" holds only within one transmit
  cycle; not verified here. Streams avoid a per-stream handshake but still pay
  flow control.

## What shipped

- `idfon://<ref>[/path]` grammar, deeplinks, and the derived account handle —
  see `docs/idfon-gateway.md`.
- `crates/idfon-gateway`: a reusable loopback HTTP gateway library
  (`Backend`/`Authorizer`, token/`Host`/`Origin` hardening), plus the
  `idfon-mcp fs` folder provider.
- Multimodal artifacts (model, thread UI, agent emit/resolve, references,
  sandboxed web view) — see `docs/idfon-artifacts.md`.

---

===
Q: does iroh have protocol scheme yet? I want to have a scheme like "iron://<pub_key>/<path>/" to map to resources hosted by the endpoint like MCP servers.
===

Iroh does not define or enforce a formal URI scheme like `idfon://<pubkey>/<path>` out of the box. Because Iroh operates primarily as a networking transport layer (establishing direct, authenticated peer-to-peer QUIC streams addressed by Node ID/Public Key), it leaves high-level URL schemes, resource mapping, and path routing up to individual applications.

However, the architecture of Iroh makes mapping a custom URI structure like `idfon://<node_id>/<path>` straight to services (like Model Context Protocol / MCP servers) very clean to implement:

### How to map `idfon://<pubkey>/<path>` to an MCP Server

1. **Protocol Negotiation (ALPN):**
In Iroh, custom protocols are multiplexed on the QUIC connection using an **ALPN** (Application-Layer Protocol Negotiation) string. You can define a custom ALPN for your MCP proxy layer:
```rust
const MCP_ALPN: &[u8] = b"my-app/mcp/v1";

```


2. **The Client side (Parsing the URI):**
Parse `idfon://<pubkey>/<path>` into:
* **Node Public Key / Endpoint ID (`<pubkey>`):** Passed to `endpoint.connect(node_id, MCP_ALPN)` to open an encrypted stream.
* **Resource Route (`<path>`):** Passed inside the first frame/headers sent across the newly opened QUIC stream to request a specific MCP tool, prompt, or server instance.


3. **The Server side (Routing & Handling):**
Use Iroh's `Router` API to listen on your custom ALPN. Upon receiving a stream, extract the requested `<path>`, resolve it to the appropriate MCP transport (e.g., bridging the stream to `stdio` or Server-Sent Events / SSE of the target MCP server), and handle communication over standard bi-directional streams.

```rust
use iroh::{Endpoint, protocol::{Router, ProtocolHandler}};

// Example server listener setup
let endpoint = Endpoint::bind(iroh::endpoint::presets::N0).await?;
let router = Router::builder(endpoint)
    .accept(MCP_ALPN, McpServerHandler)
    .spawn();

```

If you are using or exposing `iroh-blobs` directly, the Iroh ecosystem uses ticket strings (e.g., `blob...`) for sharing content-addressed blobs, but for interactive or request-response systems like MCP over streams, a custom URI scheme handled by your application layer is the recommended pattern.

===
Q: Could HTTP/3 overlaid atop iroh use such path to expose HTTP-like endpoints to clients?
===

Yes, absolutely. Because Iroh’s underlying protocol layer is built directly on QUIC (using standard TLS 1.3 encryption and stream multiplexing), **HTTP/3 can run directly on top of Iroh connections**.

This allows you to map full HTTP semantics—including request methods (`GET`, `POST`), HTTP headers, response codes, and path routing (`/v1/tools/call`)—directly over an Iroh peer-to-peer link.

---

### How HTTP/3 over Iroh Works

1. **Protocol Negotiation (ALPN):**
Standard HTTP/3 uses the ALPN string `h3`. When your client connects to an Iroh node using its Public Key, it requests the `h3` protocol:
```rust
// The connection uses Iroh's address resolution and NAT hole-punching,
// but establishes a standard HTTP/3 QUIC connection.
let connection = endpoint.connect(node_id, b"h3").await?;

```


2. **Routing the `idfon://<pubkey>/<path>` Scheme:**
Your application client can parse `idfon://<pubkey>/<path>` and transform it into an HTTP/3 request over the Iroh transport:
* **Host / Node:** Resolves `<pubkey>` to an Iroh `EndpointId`.
* **HTTP Request:** Opens an HTTP/3 request stream over the connection, targeting `/:path`.


```text
URI:          idfon://<node_id>/mcp/v1/tools/list
-------------------------------------------------
Iroh Route:   Connect to peer <node_id> via ALPN "h3"
H3 Request:   GET /mcp/v1/tools/list HTTP/3
              Host: <node_id>

```


3. **Exposing Endpoints (Server Side):**
On the hosting endpoint, you can wire an Iroh connection listener directly into Rust HTTP frameworks that support HTTP/3 over custom QUIC transports (such as `quinn` or `h3` crates).

---

### Why this is ideal for MCP Servers over P2P

* **Native Streaming:** HTTP/3 allows multiplexed request/response cycles as well as server-driven streams over independent QUIC streams.
* **Standard Web Tooling Compatibility:** Instead of defining a custom binary layout, you can leverage existing MCP JSON-RPC over HTTP/SSE transports seamlessly without redesigning the protocol.
* **Granular Path Exposing:** A single node running on one `<pubkey>` can expose multiple decoupled endpoints (e.g., `idfon://<pubkey>/mcp/mcp-server-a`, `idfon://<pubkey>/mcp/mcp-server-b`, `idfon://<pubkey>/health`).

If you are using Rust, the `h3` crate (`h3` + `h3-quinn`) can be bound to `iroh::Endpoint` connections to serve standard HTTP/3 responses directly to connected peers.

===
Q: but how would HTTP URL be used with http3 over iroh?
===

To route standard HTTP/3 over Iroh using `http://` or `https://` URLs, you face a practical challenge: standard HTTP clients (like `curl`, web browsers, or standard HTTP libraries) do not natively know how to resolve an Iroh Node ID/Public Key or talk to Iroh's custom QUIC NAT-traversal layer.

You can bridge a URL like `http://<node_id>.iroh/path` or `idfon://<node_id>/path` into actual HTTP/3 traffic using two main architectural patterns:

---

### Pattern 1: Embedded Iroh HTTP/3 Client (App-Level Integration)

If your app controls both sides (e.g., an MCP client or CLI tool written in Rust, Go, TypeScript, etc.), you bypass standard OS networking entirely.

Instead of using `net::TcpStream` or standard QUIC, you plug Iroh directly into an HTTP/3 library (like the Rust `h3` crate) as the underlying transport:

1. **Parse the URL:** Extract the Node ID (`<node_id>`) and path (`/mcp/v1`).
2. **Connect via Iroh:** Call `iroh_endpoint.connect(node_id, b"h3")` to create a P2P QUIC connection.
3. **Hand over to HTTP/3:** Pass the resulting Iroh connection to an HTTP/3 driver (`h3::client::new(iroh_conn)`).
4. **Send HTTP Request:** Execute a `GET /mcp/v1` or `POST /mcp/v1` over that HTTP/3 connection.

```text
+-----------------------+      1. Parse Host ID & Path      +------------------------+
| Custom MCP Client App | --------------------------------> | Extract Node ID & Path |
+-----------------------+                                   +------------------------+
            |                                                           |
            | 2. h3 over Iroh Connection                                | 3. Dial Node ID
            v                                                           v
  +-------------------+        P2P Encrypted QUIC Stream        +------------------------+
  |  HTTP/3 Pipeline  | <=====================================> |  Target Iroh Endpoint  |
  +-------------------+                                         +------------------------+

```

---

### Pattern 2: Local HTTP-to-Iroh Proxy (For Generic HTTP Clients & MCP)

If you want **unmodified standard tools** (like `curl`, browsers, or off-the-shelf MCP clients using standard HTTP/SSE) to interact with `idfon://<node_id>/path`, you run a **Local Proxy Daemon** on the client machine.

#### Step 1: Client Makes a Standard HTTP Request

The client sends a standard HTTP request to a local proxy port or uses a fake top-level domain via `.localhost` or `.iroh` (using standard proxy settings or custom host headers):

```bash
# Example: Client accesses the endpoint via a local proxy daemon
curl http://localhost:8080/ -H "Host: <node_id>.iroh"

```

#### Step 2: Proxy Traverses Iroh to Target Node

The local proxy receives the request, extracts the target `<node_id>` from the `Host` header or path, and performs the following pipeline:

```text
[Standard Client] ---> (HTTP 1.1 / HTTP/2) ---> [ Local Iroh Proxy ] 
                                                        |
                                            Iroh P2P QUIC Stream (ALPN: "h3")
                                                        v
                                             [ Remote Iroh Node ]

```

1. Local Proxy extracts `<node_id>` and path (`/mcp/v1`).
2. Local Proxy opens/reuses an Iroh HTTP/3 stream to `<node_id>` via `endpoint.connect(node_id, b"h3")`.
3. Local Proxy translates the local HTTP request to HTTP/3 over Iroh and pipes the response back to `curl`.

---

### Key Technical Implementation Details

#### 1. TLS and Certificate Verification

Standard HTTP/3 enforces TLS 1.3 certificates.

* **Native Iroh:** Iroh uses `Ed25519` key pairs for mTLS where the peer's Node ID is its TLS certificate public key.
* If you run standard HTTP/3 tools directly over Iroh, your HTTP client must be configured to accept Iroh's self-signed/Node-ID-derived TLS certificates instead of checking standard Web PKI (X.509) CA roots.

#### 2. ALPN Negotiation

During the QUIC handshake, both ends must agree on the protocol. For HTTP/3 over Iroh, you can either:

* **Option A:** Register the official HTTP/3 ALPN (`h3`) with Iroh's endpoint builder.
* **Option B:** Use a domain-specific ALPN like `b"my-app/mcp-h3/v1"` to ensure only your specific app handlers respond to the stream.

#### 3. Host Headers

When formulating HTTP/3 request frames, populate the `:authority` pseudo-header (the HTTP `Host` equivalent) with the Node ID string (e.g., `:authority = <node_id>`). This allows a single hosting node behind one key to route requests to different internal services based on hostnames or paths.

- [Write your own iroh protocol](https://docs.iroh.computer/protocols/writing-a-protocol)

===
Q: as long as clients don't check protocol used and only focused on paths, they should be able function just fine, no?
===

Yes, conceptually you are right—if a client only cares about paths, methods, and payloads, it doesn't care what network transport delivers them.

However, in practice, whether standard clients function "just fine" depends entirely on **where the abstraction boundary sits**:

### 1. If you mean standard app code (e.g., JS/Python MCP SDKs, `fetch()`, REST libraries)

**Yes, it works seamlessly.**

If you give high-level client code an HTTP-like client interface where it can make requests like `client.get("/mcp/v1/tools")` or `client.post("/mcp/v1/call")`, the higher-level code has zero awareness of TCP, IP addresses, or QUIC.

As long as your underlying transport layer implements the HTTP request/response state machine (mapping method, path, headers, and body onto an Iroh QUIC stream), the application logic will behave identically to standard Web HTTP.

---

### 2. If you mean off-the-shelf HTTP networking software (e.g., `curl`, Chrome, OS `net/http` packages)

**No, they will fail at the network socket layer.**

Even if these tools only care about paths, they expect to pass hostnames to OS DNS, get an IP address back, and open a raw TCP or UDP socket. They will fail because:

* **No DNS Resolution:** An Iroh Public Key (`<node_id>`) is not a domain name or IP address that OS network stacks can resolve.
* **Special Handshake Requirements:** Iroh handles hole-punching, DERP relay fallbacks, and Node-ID based mTLS authentication before any byte stream opens. Standard HTTP/3 libraries don't know how to execute this P2P setup sequence.

---

### Summary of How to Make It "Just Work"

To keep client application code completely focused on paths without worrying about Iroh's P2P mechanics, you have two options:

1. **Custom Network Adapter:** Inject an Iroh transport module into your HTTP client library (e.g., replacing standard `fetch()` or `axios` adapters with an Iroh-backed fetch adapter).
2. **Local Loopback Proxy:** Run a lightweight Iroh proxy daemon locally on `localhost`. The client makes standard calls to `http://localhost:8080/path` with a header pointing to the target `<node_id>`, and the proxy handles all Iroh transport under the hood.

===
Q: or are app-level proxy supported by platforms?
===

Yes, **app-level proxies (and per-app networking) are heavily supported across modern operating systems**, but the exact implementation mechanism depends on whether you are working at the OS layer, the runtime level, or inside an application framework.

---

### 1. OS-Level Per-App Proxy Interfaces (Mobile & Desktop)

Modern operating systems provide native developer APIs to route traffic for specific applications through a local proxy or VPN tunnel without touching global device traffic.

* **macOS & iOS (`NetworkExtension`):**
Apple provides [NEAppProxyProvider](https://developer.apple.com/documentation/networkextension/neappproxyprovider) (Per-App Proxy). You can register an app extension that intercepts TCP/UDP flows *only* for specifically designated apps (or bundle IDs) and diverts those flows over your custom Iroh P2P transport.
* **Android (`VpnService` / Per-App VPN):**
Android's [VpnService API](https://developer.android.com/develop/connectivity/vpn) includes `addAllowedApplication(packageName)`. You can launch a background service that creates a local `TUN` interface and explicitly restricts it so *only* your target application's traffic flows through it into your Iroh node.
* **Windows (WinINet / AppContainer & Enterprise MDM):**
Windows supports per-app proxying via enterprise profiles or local loopback routing, though developers typically handle Windows by launching a local proxy server (e.g., `127.0.0.1:8080`) and setting `HTTP_PROXY` environment variables specifically for the child process.

---

### 2. Runtime & Process-Level Proxying (CLI & Desktop Apps)

If you are invoking external tools, scripts, or LLM runners (like `ollama`, Python MCP clients, or Node.js) from your application, you don't need OS-level permissions. You can inject proxy settings at the **process boundary**:

```bash
# Example: Spawning an isolated MCP client subprocess routed through your Iroh proxy
HTTP_PROXY="http://127.0.0.1:8080" \
HTTPS_PROXY="http://127.0.0.1:8080" \
python mcp_client.py

```

Most network libraries (Python `requests`/`httpx`, Node `fetch`/`undici`, Go `net/http`, Rust `reqwest`) automatically read `HTTP_PROXY` on a per-process basis without modifying global system proxy settings.

---

### 3. Application Framework Level (Electron, WebViews)

If you are building an application framework or GUI app that needs to execute MCP calls:

* **Electron:** You can call `session.defaultSession.setProxy({ proxyRules: "[http://127.0.0.1:8080](http://127.0.0.1:8080)" })` to route only that application window's web traffic through your Iroh proxy daemon.
* **Browsers / Extensions:** Extensions can use the `chrome.proxy` API to dynamically set routing rules for standard `.iroh` or `.local` domains while leaving standard web browsing intact.

---

### Recommended Architecture for Iroh + MCP

To make `idfon://<node_id>/<path>` work seamlessly with off-the-shelf MCP tooling:

1. **Local Sidecar Daemon:** Run a lightweight Iroh daemon listening on `127.0.0.1:8080`.
2. **Process Scope:** Launch your MCP client/worker process with `HTTP_PROXY=[http://127.0.0.1:8080](http://127.0.0.1:8080)`.
3. **Transparent Forwarding:** When the MCP client requests `http://<node_id>.iroh/mcp/v1`, the sidecar captures it, resolves `<node_id>` over the Iroh peer network, establishes the QUIC stream, and pipes the HTTP/3 response back to the client.

===
Q: How would MCP resources work in this?
===

When combining **MCP (Model Context Protocol)** with **HTTP/3 over Iroh**, the interaction model is remarkably clean.

Because MCP has evolved into a **stateless HTTP transport model**, an MCP resource is simply a JSON-RPC method request targeted at a specific endpoint via a standard HTTP `POST`.

---

### How the Layering Works

Here is how the data flows when an AI agent requests an MCP Resource via `idfon://`:

```text
[ Client AI Agent ]
       │
       │ 1. Request: "Read resource idfon://<node_id>/mcp/v1"
       ▼
[ Local Iroh Proxy / Native Transport ]
       │
       │ 2. Dial Peer <node_id> over Iroh QUIC Stream (ALPN: "h3")
       │ 3. Send HTTP/3 POST /mcp/v1
       ▼
[ Remote Iroh MCP Server Node ]
       │
       │ 4. Route POST /mcp/v1 to internal MCP Handler
       │ 5. Execute method: "resources/read"
       ▼
[ Local File / Database / Custom Tool ]

```

---

### Step-by-Step Breakdown of an MCP Resource Fetch

#### 1. URI Mapping

The user or LLM targets a specific resource host:
`idfon://6b4e...a9f2/mcp/v1`

* **`6b4e...a9f2`**: The Iroh **Node ID / Public Key** (used for P2P routing & mTLS encryption).
* **`/mcp/v1`**: The base path where the remote MCP HTTP server listens.

#### 2. The HTTP/3 Request over Iroh

The client opens a QUIC stream to the node via Iroh, opens an HTTP/3 framing session, and submits a `POST /mcp/v1` request:

```http
POST /mcp/v1 HTTP/3
Host: 6b4e...a9f2.iroh
Content-Type: application/json
Accept: application/json
Mcp-Method: resources/read

{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "resources/read",
  "params": {
    "uri": "memo://project-docs/architecture.md"
  },
  "_meta": {
    "io.modelcontextprotocol.version": "2026-07-28"
  }
}

```

*(Note: standard MCP headers like `Mcp-Method` allow edge gateways/proxies to inspect or route requests without parsing the underlying JSON body).*

#### 3. Response Delivery

The Iroh node executes the resource fetch locally and streams the JSON-RPC response back over the same HTTP/3 stream:

```http
HTTP/3 200 OK
Content-Type: application/json

{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "contents": [
      {
        "uri": "memo://project-docs/architecture.md",
        "mimeType": "text/markdown",
        "text": "# Architecture\nWe use Iroh as our P2P transport..."
      }
    ]
  }
}

```

---

### Key Technical Advantages of this Setup

1. **No Session Pinning Needed:** MCP's stateless HTTP specification means you do not need long-lived stateful connections or server-side session stores. Every HTTP/3 request over Iroh carries its own context metadata (`_meta`), meaning requests can land on any stream safely.
2. **Direct P2P Encryption:** Since Iroh relies natively on `Ed25519` key pairs for mutual TLS authentication, the MCP JSON-RPC messages are automatically end-to-end encrypted between the client and the node serving the resource, bypassing public internet proxies.
3. **Multi-Tenant Server Pathing:** A single Iroh Node Key can host multiple, distinct MCP server instances simply by exposing different paths:
* `idfon://<node_id>/db-server/mcp` $\rightarrow$ Database MCP Server
* `idfon://<node_id>/fs-server/mcp` $\rightarrow$ File System MCP Server

===
Q: what I want to support TLDs as well as nodeIds?
===

To support both human-readable TLDs (e.g., `idfon://mcp-server.iroh/path`) and raw Node IDs (e.g., `idfon://6b4e...a9f2/path`), you need a **Name Resolution Layer** sitting between the URI parser and your Iroh transport module.

Here is how to map, resolve, and handle both formats cleanly:

---

### 1. The Name Resolution Pipeline

When your application encounters `idfon://<host>/<path>`, it runs a simple resolution step before initiating the Iroh connection:

```text
               idfon://<host>/<path>
                         │
           Is <host> a 32-byte Public Key?
                     ├── YES ──> [ Use Direct Node ID ] ─────────┐
                     │                                           │
                     └── NO ───> [ Perform PKARR / DNS Lookup ]  │
                                              │                  │
                                     Returns Node ID             │
                                              │                  │
                                              v                  v
                                    Connect via Iroh:
                            endpoint.connect(node_id, ALPN)

```

---

### 2. Resolution Strategies for `.iroh` TLDs

Depending on how decentralized you want your ecosystem to be, you can resolve TLDs using one or a combination of these three approaches:

#### Option A: P2P Public Key Address Resolution (PKARR / Mainline DHT)

* **How it works:** Iroh natively pairs well with **PKARR** (Public Key Address Readability). Under PKARR, a node signs a DNS record zone using its own Ed25519 keypair and publishes it to the Mainline DHT or relay nodes.
* **TLD Format:** You can use z-base32 encoded public key domains (e.g., `idfon://<zbase32-key>.iroh/path`) or human-friendly names anchored to a DHT record.
* **Advantage:** Completely P2P, serverless, and cryptographically verified.

#### Option B: Standard DNS TXT / HTTPS Records

* **How it works:** Bind a standard internet domain (like `mcp-server.com` or `mcp.mycompany.internal`) to an Iroh Node ID using DNS TXT records.
* **DNS Record Setup:**
```text
_iroh.mcp-server.com.  IN  TXT  "node_id=6b4e...a9f2"

```


* **Resolution:** Your proxy/client queries standard DNS for `_iroh.mcp-server.com`, extracts the `node_id`, and then opens an Iroh QUIC stream to that ID.

#### Option C: Local `hosts` Mapping / App-Level Registry

* **How it works:** Maintain an in-memory or configuration-file lookup table inside your local sidecar proxy or application runtime.
* **Config (`~/.iroh/hosts`):**
```text
docs-server.iroh  6b4e...a9f2
code-assistant.iroh  f3a1...8e4b

```



---

### 3. Implementing the URI Parser (Code Pattern)

Here is how you can structure the host parsing logic (using Rust-like pseudocode):

```rust
async fn resolve_iroh_uri(uri: &str) -> Result<(NodeId, String)> {
    let parsed = Url::parse(uri)?; // e.g., idfon://mcp-server.iroh/v1/tools
    let host = parsed.host_str().ok_or("Missing host")?;
    let path = parsed.path().to_string();

    // 1. Check if the host is already a raw Node ID (Public Key)
    if let Ok(node_id) = host.parse::<NodeId>() {
        return Ok((node_id, path));
    }

    // 2. Resolve human-readable domain/TLD
    let node_id = match host {
        // Option C: Local alias
        name if is_local_alias(name) => lookup_local_alias(name)?,

        // Option B: Standard DNS resolution for custom TLDs/domains
        domain if domain.ends_with(".iroh") || domain.contains('.') => {
            resolve_dns_txt_record(&format!("_iroh.{}", domain)).await?
        }

        _ => return Err("Invalid Iroh host format".into()),
    };

    Ok((node_id, path))
}

```

---

### 4. Handling HTTP Headers and Host Matching

When the client transforms `idfon://mcp-server.iroh/path` into an HTTP/3 request over the P2P connection, preserve both identity elements in the request:

```http
POST /v1/tools HTTP/3
Host: mcp-server.iroh
X-Iroh-Node-Id: 6b4e...a9f2
Content-Type: application/json

```

* **`Host` Header:** Kept as `mcp-server.iroh` so multi-tenant MCP servers sitting on the remote node can route requests by virtual hostname.
* **TLS / QUIC Connection:** Handled strictly using the resolved `NodeId` for cryptographic endpoint identity and NAT hole-punching.

===
Q: isn't how custom scheme works dictated by some standard and hence affects how URL is formatted?
===

Yes, absolutely. URI/URL syntax is governed by internet standards—primarily **[RFC 3986](https://www.loc.gov/standards/uri/generic.html)** (URI Generic Syntax) and the **[WHATWG URL Standard](https://url.spec.whatwg.org/)**.

However, because of how these standards are structured, **`idfon://<node_id>/<path>` is already 100% compliant** with standard generic URI grammar.

Here is how the standard rules dictate custom URL formatting and how Iroh fits into them:

---

### 1. Hierarchical vs. Opaque Schemes

RFC 3986 splits URIs into two structural styles:

* **Hierarchical URIs (`scheme://authority/path`):** Uses double slashes `//` to indicate that an **Authority** (host/ip) follows.
* **Opaque URIs (`scheme:opaque_data`):** Uses a colon without double slashes. Examples include `mailto:user@example.com` or `urn:isbn:0451450523`.

Because you want `idfon://<host>/<path>`, you are using a **Hierarchical URI**.

---

### 2. Standard Grammar Mapping for `idfon://`

Under RFC 3986 / WHATWG rules, your proposed structure maps directly to generic URL components:

$$\text{idfon://} \underbrace{\text{6b4e...a9f2}}_{\text{Authority / Host}} \quad \underbrace{\text{/mcp/v1/tools}}_{\text{Path}}$$

1. **Scheme Name (`iroh`):** RFC 3986 dictates schemes must start with a letter and contain only ASCII letters, numbers, `+`, `-`, or `.`. `iroh` complies perfectly.
2. **Authority / Host (`<node_id>` or `<tld>.iroh`):** Standard URL parsers treat whatever comes between `//` and the first `/` as the **Host/Authority**.
* **Node ID:** To a generic parser, an Ed25519 public key (like `6b4e...a9f2`) is simply an unreserved alphanumeric host string.
* **TLD:** A name like `server.iroh` is treated as a domain host string.


3. **Path (`/mcp/v1`):** Governed by standard `/` delimiter path rules, allowing tools, endpoints, or resources to be nested.

---

### 3. Special vs. Non-Special Schemes (WHATWG URL Standard)

In modern web development (JavaScript `new URL()`, Chrome, Node.js), URL parsing follows the **WHATWG URL Standard**.

WHATWG classifies schemes into two categories:

* **Special Schemes:** Schemes known to web engines (`http`, `https`, `ftp`, `ws`, `wss`, `file`). Web parsers apply strict default ports, IP normalization, and DNS path rules to these.
* **Non-Special / Custom Schemes:** Everything else (e.g., `iroh`, `git`, `docker`, `ipfs`).

Because `iroh` is a non-special scheme, standard WHATWG URL parsers treat `idfon://` as a generic hierarchical URL.

#### What JavaScript/Node `new URL()` does with `idfon://`

If you run `idfon://6b4e...a9f2/mcp/v1` through standard JS or Rust URL parsers, it parses smoothly without errors:

```js
const u = new URL("idfon://6b4e1234567890abcdef/mcp/v1?timeout=30#tools");

console.log(u.protocol); // "iroh:"
console.log(u.hostname); // "6b4e1234567890abcdef"
console.log(u.pathname); // "/mcp/v1"
console.log(u.search);   // "?timeout=30"
console.log(u.hash);     // "#tools"

```

---

### 4. Constraints You Must Follow for Standards Compliance

To ensure generic HTTP clients, browser extensions, and URL libraries parse your `idfon://` URLs without throwing errors, adhere to these RFC rules:

* **No Underscores or Illegal Characters in Hostnames:** Ed25519 public keys or node IDs must be serialized using characters valid for hosts (alphanumeric characters, lowercase hex, Base32, or z-base32).
* **Percent-Encoding in Paths:** If your path or query parameters contain spaces, non-ASCII characters, or reserved signs, they must be percent-encoded (e.g., `%20` for spaces).
* **Case Sensitivity:** By RFC 3986, the scheme (`idfon://`) and host components are case-insensitive and normalized to lowercase by parsers. Make sure your Node ID serialization is case-insensitive or strictly lowercase (such as lowercase hex or z-base32).

===
Q: What's the industry proven method of claiming domain or domain with path?
===

When establishing ownership or control over identifiers like `idfon://<host>/<path>` across different network layers, **"claiming" a domain vs. claiming a path** relies on distinct, industry-proven standards depending on whether you operate at the local OS, global DNS, or protocol level.

---

### 1. Claiming a Scheme (`idfon://`)

If you want to formally claim `idfon://` so standard applications and operating systems recognize your application as the handler:

* **Official Global Registration (IANA):** To prevent collisions globally, custom schemes are registered in the **[IANA URI Scheme Registry](https://www.iana.org/assignments/uri-schemes/uri-schemes.xhtml)**. Under [RFC 7595](https://www.rfc-editor.org/info/rfc7595) (updating RFC 3986), you submit an RFC or specification detailing the scheme's syntax and semantics.
* **Local OS Deep Linking Registration:** At the desktop/mobile OS level, apps register their scheme via manifest declarations:
* **macOS/iOS:** `CFBundleURLTypes` in `Info.plist`.
* **Android:** `<intent-filter>` with `<data android:scheme="iroh" />` in `AndroidManifest.xml`.
* **Windows:** Registering a key under `HKEY_CLASSES_ROOT\iroh` in the Windows Registry.



---

### 2. Claiming a Domain/Authority (`<node_id>` or `.iroh` TLD)

To prove that your application legitimately controls a specific host/authority name (preventing impersonation), the industry relies on cryptographic or domain verification:

* **Cryptographic Domain Ownership (P2P / Web3):** In peer-to-peer architectures like Iroh, IPFS, or Dat, authority ownership is inherently claimed via **Public Key Cryptography** (Ed25519). You don't "register" a Node ID with a central registrar; you prove ownership on every TLS handshake by signing challenges with the matching private key.
* **DNS TXT / DNSSEC Proof (Web Bridge):** When mapping human-readable TLDs (e.g., `mcp-server.com` or `mcp.iroh`) to a P2P Node ID, the standard approach is **DNS TXT verification** (similar to DKIM/SPF):
```text
_iroh.mcp-server.com. IN TXT "iroh-node-id=6b4e...a9f2"

```


* **PKARR (Public Key Address Readability):** A P2P-native standard where the owner of an Ed25519 keypair signs DNS resource records locally and publishes them directly to a Distributed Hash Table (DHT).

---

### 3. Claiming a Path (`/mcp/v1/tools`)

Under standard Web Architecture (RFC 3986), **paths are strictly local to the authority hosting them**. You do not globally register or "claim" paths across the internet; instead, ownership of a path is claimed within an application through **Routing and Protocol Delegation**:

* **Universal Links / App Links (OS Level):** Modern operating systems (iOS Universal Links and Android App Links) solved the security flaws of custom URI schemes by binding paths directly to verified domain origins using hosting manifests:
* **Apple:** Host `/.well-known/apple-app-site-association` on the domain to specify which URL paths map to which native apps.
* **Android:** Host `/.well-known/assetlinks.json` on the domain to claim specific paths.


* **Well-Known URIs (RFC 8615):** If you want to claim a standardized path prefix across multiple nodes for automated discovery (e.g., claiming where MCP servers live on any given host), standard practice is to register a prefix in the **IANA Well-Known URIs Registry**:
* Example: `idfon://<node_id>/.well-known/mcp`



---

### Summary Matrix

| Level | What You Are Claiming | Industry-Proven Standard / Mechanism |
| --- | --- | --- |
| **Scheme** | `idfon://` | **IANA Scheme Registry** (Global) / OS Intent & URL Handlers (Local Device) |
| **Domain** | `<node_id>` / `.iroh` | **Ed25519 Private Key** (Cryptographic) or **DNS TXT / PKARR Records** |
| **Path** | `/path` | **Application Router** (Internal) or **RFC 8615 Well-Known URIs** |

===
Q: How about exposing their public ID in the metadata (HTML meta tag) which would make ownership of a path also easier (metadata on subpage).
===

Exposing the public Node ID in an HTML `<meta>` tag is a well-established pattern across the web. Big platforms like Google Search Console, Meta/Facebook, and OpenGraph use HTML `<meta>` tags as a primary mechanism to prove ownership or bind services to specific domain paths.

Applying this pattern to Iroh and MCP resources works smoothly, with key considerations around implementation, advantages, and cryptographic trade-offs:

---

### How HTML Meta Tag Binding Works

If a node hosts a traditional web application or documentation site, it can embed its Iroh Public Key directly in the `<head>` of any subpage HTML:

```html
<!DOCTYPE html>
<html>
<head>
  <title>MCP Tool Server Documentation</title>
  
  <!-- Direct Node ID ownership claim -->
  <meta name="iroh:node-id" content="6b4e123456789012345678901234567890123456789012345678901234567890">
  
  <!-- Optional: Declare the associated MCP endpoint path -->
  <meta name="iroh:mcp-path" content="/mcp/v1">
</head>
<body> ... </body>
</html>

```

When a user or AI agent visits `[https://example.com/docs/tools](https://example.com/docs/tools)`, a client script/extension scrapes the meta tag to resolve the `idfon://6b4e.../mcp/v1` backend serving that specific subpage.

---

### Advantages of HTML Path Meta Tags

1. **Subpage & Granular Path Ownership:**
Unlike DNS TXT records—which generally apply to an entire domain or subdomain—HTML `<meta>` tags inherently adhere to individual URLs. This allows path-level delegation:
* `[https://example.com/team-a/docs](https://example.com/team-a/docs)` $\rightarrow$ `<meta name="iroh:node-id" content="<Node_ID_A>">`
* `[https://example.com/team-b/docs](https://example.com/team-b/docs)` $\rightarrow$ `<meta name="iroh:node-id" content="<Node_ID_B>">`


2. **Web-to-P2P Discovery:**
An AI agent browsing the standard web can dynamically discover P2P endpoints. Upon encountering an `<meta name="iroh:node-id">` tag on a website, it can upgrade the connection from HTTP to a direct Iroh QUIC stream for lower latency or cryptographically secure RPCs.
3. **Ease of Deployment:**
Non-technical users or CMS administrators who do not have access to DNS settings can easily add `<meta>` tags via CMS plugins, static site generators, or simple HTML updates.

---

### Key Security & Verification Trade-Offs

While HTML `<meta>` tags claim ownership, **claiming is not proving**. To establish cryptographic proof of path ownership, apply these security considerations:

#### 1. One-Way vs. Two-Way Verification

* **The Claim (HTTP Site):** The webpage says: *"My corresponding Iroh Node ID is `6b4e...`"*.
* **The Verification (Iroh Stream):** Anyone can put an arbitrary Public Key inside an HTML tag on their blog. To confirm true ownership, the client must initiate an Iroh connection to `6b4e...` and verify that the remote node can answer a cryptographic challenge proving it holds the matching private key.

#### 2. Protecting Against Tag Hijacking (Signatures)

If an attacker compromises a web host or performs a Man-in-the-Middle (MitM) attack, they could swap the `<meta name="iroh:node-id">` content with their own node ID to hijack MCP traffic.

To solve this, pair the Node ID with a **signed cryptographic attestation**:

```html
<meta name="iroh:node-id" content="6b4e...">
<meta name="iroh:path-claim" content="/docs/tools">
<!-- Signature generated by the Node ID's private key over the string "https://example.com/docs/tools" -->
<meta name="iroh:signature" content="z3a9f81b...">

```

By verifying the `iroh:signature` using the `iroh:node-id` public key, the client guarantees that the node operator explicitly authorized that specific website path.

---

### Recommended Standard Mapping

For a clean, standards-compliant implementation:

| Metadata Tag | Example Value | Purpose |
| --- | --- | --- |
| `<meta name="iroh:node-id">` | `6b4e...a9f2` | Binds the HTML page/path to an Iroh Endpoint. |
| `<meta name="iroh:mcp-endpoint">` | `/mcp/v1` | Declares the exact path where the MCP HTTP/3 transport listens. |
| `<meta name="iroh:signature">` | `ed25519_sig...` | Cryptographic signature verifying path authorization. |

===
Q: Couldn't I also use deeplink in the same way so there is no difference between a deeplink and a endpoint resource URL?
===

Yes, absolutely. In fact, under modern web architecture standards (such as **Apple Universal Links** and **Android App Links**), **there is intentionally no structural difference between a deep link and an endpoint resource URL**.

When you design your custom scheme or URL strategy (like `idfon://<node_id>/<path>`), a single URL can serve **both** roles simultaneously—functioning as a user-facing **Deep Link** (triggering an UI action or launching an app) or a machine-facing **Endpoint Resource URL** (fetching data or calling an MCP tool) depending on *who* invokes it and *how*.

---

### The Dual Role of the Same URL

Consider the URL: `idfon://6b4e...a9f2/mcp/v1/tools/weather`

#### 1. Invoked as an Endpoint Resource URL (Programmatic API Call)

* **Caller:** An AI Agent, LLM runner, or HTTP/3 backend.
* **Mechanism:** Opens an Iroh QUIC stream using `ALPN: "h3"`, sending a `POST` or `GET` request directly to the underlying MCP server.
* **Result:** Returns structured data (`JSON-RPC`, raw binary, or context blobs).

#### 2. Invoked as a Deep Link (UI / OS Action)

* **Caller:** A user clicking a link inside a browser, messaging app, or CLI prompt.
* **Mechanism:** The Operating System interceptor captures `idfon://` and passes the URL string to an installed native desktop app, browser extension, or UI tool.
* **Result:** Opens a specific GUI screen showing the MCP Tool Inspector, user interface, or configuration page for that exact resource.

---

### Why Converging Deep Links and Endpoint URLs Works

Historically, developers used separate custom schemes for deep linking (e.g., `slack://open?channel=123`) versus standard REST URLs (`[https://api.slack.com/v1/channels/123](https://api.slack.com/v1/channels/123)`). Modern architecture abandoned this split for several key reasons:

1. **Semantic Identicality:** A resource's path is its canonical location. A path like `/projects/42/summary` means the exact same thing whether an AI agent fetches its raw JSON representation or a native app opens a visual dashboard for project 42.
2. **Context-Aware Routing (Negotiation):** Just as HTTP uses **Content Negotiation** (`Accept: application/json` vs. `Accept: text/html`), your Iroh proxy or local handler routes the request based on context:
* **Application Context:** If the caller is an OS deep-link handler, open the UI.
* **Transport Context:** If the caller initiates an HTTP/3 or raw QUIC stream, execute the RPC endpoint.



---

### Implementation Pattern for Dual-Purpose `idfon://` URLs

To implement this seamlessly in your app, use an **Intent Router** that inspects the request environment:

```text
               idfon://6b4e...a9f2/mcp/v1/tools/weather
                                │
               Is this invoked by OS or Network?
                                │
          ┌─────────────────────┴─────────────────────┐
          ▼                                           ▼
 [ OS / User Desktop ]                      [ P2P Network / Agent ]
  • Triggered via URL Handler                • Triggered via HTTP/3 Stream
  • Parses host & path                       • Sends JSON-RPC "tools/call"
  • Launches GUI window:                     • Returns raw response payload:
    "Inspecting Weather Tool"                  {"temperature": "22C"}

```

### Key Takeaway

By designing `idfon://<node_id>/<path>` cleanly according to [RFC 3986](https://www.loc.gov/standards/uri/generic.html), you do not need separate URL schemes for apps vs. APIs. The URL is simply a universal identifier for a resource on a peer node—whether a human views it through a deep link or a machine queries it as an endpoint.

===

**You generally do not need to manually batch application messages to reduce connection cost or latency.**

Because Iroh is built directly on QUIC (via `noq`/`quinn`), the low-level network stack automatically optimizes streams and packets for you. Understanding how QUIC handles messaging under the hood reveals why manual batching can actually be counterproductive:

---

### 1. Zero Connection Cost for Sub-Streams

Opening new streams within an existing Iroh connection requires **0 Round-Trip Time (0-RTT)**.

* **No Handshake Overhead:** You do not pay a TCP three-way handshake or TLS negotiation cost every time you send a request.
* **Streams are Cheap:** QUIC treats streams as lightweight logical abstractions, not heavy operating system sockets. You can open thousands of streams over a single established Iroh connection without creating connection overhead.

---

### 2. Automatic UDP Packet Coalescing (Transport-Level Batching)

When you write small messages to an active Iroh stream (or open multiple streams in quick succession), **the underlying QUIC implementation automatically batches them into single UDP datagrams** at the OS level:

* If you send three small messages back-to-back, QUIC packs their frames together into one network packet (up to the Maximum Transmission Unit / MTU size, typically ~1200–1500 bytes).
* You get the efficiency of packet-level batching **without forcing your application code to wait around to fill a buffer**.

---

### 3. Head-of-Line Blocking (Why Manual Batching Can Hurt Latency)

If you manually batch multiple independent requests (e.g., combining 10 MCP tool calls into a single JSON array on a single stream), you introduce **Head-of-Line Blocking**:

```text
[ Manual Batching ]
Message 1, Message 2, Message 3  ---> Sent on ONE Stream
* If Message 1 drops, Messages 2 & 3 must WAIT until Message 1 is retransmitted.

[ Native Iroh Multiplexing ]
Message 1  ---> Stream 1  ──┐
Message 2  ---> Stream 2  ──┼─> All packed into same UDP Packet
Message 3  ---> Stream 3  ──┘
* If Stream 1 drops, Stream 2 and Stream 3 process IMMEDIATELY on the peer.

```

By keeping messages separate and letting Iroh multiplex them over independent QUIC streams, lost packets only delay the specific message that was dropped, keeping latency minimal for everything else.

---

### When Batching *Is* Useful

While you don't need batching for network latency, application-level batching still makes sense in two specific scenarios:

1. **High Throughput / Bulk Transfers:** If you are pushing millions of tiny events per second, batching reduces local CPU overhead (reducing sys-calls and context switches).
2. **Server-Side Processing:** If the remote MCP server can perform database/LLM batch execution cheaper in bulk (e.g., processing a vector batch in GPU memory), batching provides computational efficiency.

### Summary

To minimize latency over Iroh, **send messages or open streams as soon as the data is ready**. Let Iroh's QUIC engine handle packing the bytes into UDP datagrams.
