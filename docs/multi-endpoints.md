Running **3 distinct Iroh `Endpoint` instances** simultaneously (one for each identity) is relatively lightweight, but operating system resource constraints—especially on mobile—mean you need to manage them carefully.

Here is the breakdown of expected resource costs on desktop vs. mobile:

---

### **Resource Impact Breakdown**

| Metric | Desktop Impact (3 Endpoints) | Mobile Impact (iOS / Android) |
| --- | --- | --- |
| **RAM Footprint** | **~15–45 MB total** (~5–15 MB per idle endpoint depending on connection state and peer caches). | **~15–45 MB total** (Acceptable on modern hardware, but vulnerable to OS low-memory killers). |
| **Sockets & Ports** | **3 UDP Sockets** (1 local bound port per identity). | **3 UDP Sockets** (Fine while active, but mobile OSs penalize open sockets in the background). |
| **Relay Connections** | **3 active TLS/QUIC connections** to an `iroh-relay` server to listen for incoming hole-punching attempts. | **High Battery Impact:** 3 separate keep-alive ping loops will repeatedly wake up the cellular/Wi-Fi radio. |
| **CPU / Battery** | Minimal idle usage (**<1% CPU** for NAT path monitoring and STUN probes). | **Significant Battery Drain** if all 3 maintain active background keep-alives continuously. |

---

### **Platform Differences**

#### **On Desktop (macOS, Windows, Linux)**

* **Verdict:** **Negligible.**
* Desktop systems handle thousands of file descriptors and background sockets without issue. Running 3 endpoints concurrently will cost under 50 MB of RAM and negligible CPU cycles while idle. You can safely keep all three listening continuously.

#### **On Mobile (iOS & Android)**

* **Verdict:** **Not viable for long-term background listening.**
* Both iOS and Android aggressively restrict background execution to preserve battery:
* **Background Termination:** If your app goes to the background with 3 active UDP sockets and 3 open TLS relay connections, the mobile OS will terminate the app or force-close its background sockets to save power.
* **Radio Wakeups:** Keeping 3 distinct relay keep-alive timers running causes frequent radio wakeups, noticeably draining the device battery.



---

### **Recommended Mobile & Desktop Strategy**

To support 3 isolated identities without incurring battery or connection penalties:

1. **On Mobile (Active/Lazy Swapping + Push Notifications):**
* Keep only the **active identity's `Endpoint` running** in the foreground.
* Tear down or pause idle endpoints when switching identities or putting the app in the background.
* Rely on centralized or unified **Push Notifications (APNs / FCM)** to signal incoming requests for inactive identities, then spin up that identity's `Endpoint` on demand.


2. **On Desktop (Concurrent Endpoints):**
* Keep all 3 `Endpoint` instances running in parallel so the user remains instantly reachable across Personal, Work, and Private identities.

===

Yes, that is the exact core challenge. Because [iroh-relay](https://lib.rs/crates/iroh) servers act purely as encrypted packet forwarders, they do not inspect application payloads and cannot natively decide when or how to trigger mobile push notifications.

To wake an idle identity on demand, you need a mechanism to signal that a connection attempt is being made.

---

### How On-Demand Mobile Waking Works

There are two primary architectural patterns to handle this:

#### Pattern A: Centralized Signaling Server (Most Common)

Instead of relying on the relay to initiate push notifications, the dialing peer routes through a lightweight signaling API first:

1. **Dialing Request:** Peer A wants to connect to Peer B's "Work" identity. Peer A calls your central application API (or a serverless endpoint): `"Hey, wake up Work Identity X."`
2. **Push Delivery:** Your server dispatches a silent push notification via **APNs** (iOS) or **FCM** (Android) containing the request metadata.
3. **Background Wakeup:** The mobile operating system receives the silent push and briefly wakes your app in the background.
4. **Endpoint Initialization:** Your app instantiates the requested `Endpoint` for the "Work" identity, connects to its home relay, and listens.
5. **Connection Execution:** Peer A receives a success response from the signaling server (or retries dialing the target `EndpointId`) and establishes the QUIC stream via Iroh.

---

#### Pattern B: Custom Relay / Smart Gateway Integration

If you host your own custom relay infrastructure, you can extend it to trigger notifications when connection attempts fail:

1. **Relay Buffer:** Peer A sends an initial connection request packet through the custom relay destined for Peer B's `EndpointId`.
2. **Offline Detection:** The relay notices that Peer B's `EndpointId` is currently disconnected from the relay.
3. **Automated Push:** Instead of immediately dropping the packet, the custom relay sends a web hook to your push notification service.
4. **Wake & Connect:** The phone wakes up, re-establishes its `Endpoint` connection to the relay, and retrieves the pending connection request.

---

### Summary

An `Endpoint` cannot be dialed if it isn't currently running and connected to a relay. To support on-demand identity creation, **the connection attempt must be preceded by an out-of-band push notification** via standard mobile push services (APNs/FCM).

===

Both design patterns are proven industry standards used by real-world decentralized, P2P, and end-to-end encrypted mobile applications.

### Pattern A: Signaling Server + Native Push (Proven Standard)

This is the most common, robust, and production-tested pattern across mobile applications.

* **Real-World Examples:**
* **Signal & WhatsApp:** Signaling servers push APNs/FCM "wake" payloads to initiate WebRTC or custom peer-to-peer/relay calls before media streams connect.
* **Matrix Protocol:** Uses lightweight HTTP push gateways to notify mobile clients via native APNs/FCM, waking the app to open background connections to home servers or P2P nodes.
* **Syncthing (Mobile):** Uses central discovery/relay signaling to coordinate connections on mobile rather than continuously running background listeners.


* **Performance:**
* **Latency:** Modern silent push notifications typically arrive in **100ms to 800ms**.
* **Reliability:** APNs and FCM achieve higher than **99% delivery reliability** when the device has an active internet connection.


* **Why It Works:** Operating systems treat native push notifications with high CPU/network delivery priority, giving your application a guaranteed 10–30 second background execution window to instantiate the `Endpoint`, connect to its relay, and start receiving streams.

---

### Pattern B: Custom Relay + Push Hook (Proven in P2P Protocols)

This pattern is heavily used in specialized peer-to-peer and decentralized communication networks that avoid central application databases.

* **Real-World Examples:**
* **Session Messenger:** Uses "S Lokinet" / Service Node storage servers. When a node attempts to deliver a packet to an offline/sleeping public key, the service node triggers a push notification to wake the recipient's phone to collect messages.
* **Berty (IPFS-based messaging):** Uses external push gateways integrated directly with P2P relay infrastructure to alert offline mobile peers of pending connection requests.
* **Custom WebRTC Gateways:** Turn/Stun media servers integrated with push triggers when inbound call signaling reaches a disconnected peer ID.


* **Performance:**
* **Latency:** Slightly faster overall execution (typically **200ms–500ms**) because it removes the extra round-trip to an application-level API.
* **Reliability:** Requires maintaining reliable relay infrastructure (e.g., custom deployment of `iroh-relay` modified with a push notification webhook).



---

### Key Production Trade-offs

| Factor | Pattern A (Signaling API) | Pattern B (Custom Relay) |
| --- | --- | --- |
| **Setup Complexity** | **Low.** Works out-of-the-box with stock `iroh-relay` servers and standard Web APIs. | **Medium/High.** Requires deploying and maintaining custom-built `iroh-relay` instances. |
| **Privacy / Unlinkability** | **Medium.** The signaling server sees when Identity A calls Identity B (though payloads remain encrypted). | **High.** The signaling trigger is tightly bound to network layer `EndpointId` events. |
| **Mobile Reliability** | **Extremely High.** Standardized APNs/FCM delivery flows are natively optimized by iOS and Android. | **High.** Relies on the mobile client connecting to the relay quickly enough after being woken up. |

For most production apps built on Iroh, **Pattern A** is the recommended starting point due to its simplicity and zero need to modify the underlying network relay code.
