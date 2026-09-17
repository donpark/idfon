import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DaemonBootstrap.start()
        ChatStore.shared.start()
        setVideoRotation()
        smokeCheckStatus()
        handleLaunchArguments()
        return true
    }

    /// Legacy nokhwa rotation hook; the Swift CameraPusher path rotates
    /// natively via connection.videoOrientation. No-op kept for the bridging
    /// header until the legacy path is deleted.
    private func setVideoRotation() {}

    /// Automation channel (simctl launch app.idfon -dial <ref> / -answer);
    /// launch arguments bypass the system "Open in app?" confirmation that
    /// `simctl openurl` shows for URL schemes.
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        let client = DaemonClient()
        if let i = args.firstIndex(of: "-dial"), args.count > i + 1 {
            let ref = args[i + 1]
            Task {
                do {
                    try await LiveCallHarness.dial(peer: ref, seconds: 8, client: client)
                    NSLog("idfon dial done: \(ref)")
                } catch {
                    NSLog("idfon dial failed: \(error.localizedDescription)")
                }
            }
        }
        if args.contains("-answer") {
            Task {
                do {
                    let out = try await LiveCallHarness.armAutoAnswer(waitSeconds: 120, captureSeconds: 8, client: client)
                    NSLog("idfon call recorded to \(out)")
                } catch {
                    NSLog("idfon answer failed: \(error.localizedDescription)")
                }
            }
        }
        if let i = args.firstIndex(of: "-videodial"), args.count > i + 1 {
            VideoCall.shared.dial(args[i + 1])
        }
        if args.contains("-camprobe") {
            CameraPusher.shared.start()
        }
        if let i = args.firstIndex(of: "-pair"), args.count > i + 1 {
            pairPeer(ticketJSON: args[i + 1], name: args.count > i + 2 ? args[i + 2] : "mac")
        }
        if let i = args.firstIndex(of: "-pair-ticket"), args.count > i + 2 {
            storeCapabilityTicket(peer: args[i + 1], jsonOrPath: args[i + 2])
        }
        // Debug: NSLog the tail of the daemon tracing log (see iroh_enable_tracing).
        if args.contains("-dumplog") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Self.dumpLog() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { Self.dumpLog() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { Self.dumpLog() }
        }
        if let i = args.firstIndex(of: "-memo"), args.count > i + 2, let seconds = TimeInterval(args[i + 1]) {
            let ref = args[i + 2]
            VoiceMemo.requestPermission { granted in
                guard granted else { NSLog("idfon memo: no mic permission"); return }
                let memoClient = DaemonClient()
                let memo = VoiceMemo()
                do { _ = try memo.start() } catch {
                    NSLog("idfon memo start failed: \(error.localizedDescription)")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    guard let result = memo.stop() else { return }
                    Task {
                        do {
                            let data = try Data(contentsOf: result.url)
                            let ticket = try await memoClient.putData(data, resourceId: "memo-\(UUID().uuidString)")
                            let envelope = """
                            IDFON-RECORDING/1
                            id=\(UUID().uuidString)
                            codec=pcm
                            sample_rate=16000
                            duration_ms=\(Int(result.duration * 1000))
                            sender_id=ios-sim
                            ticket=\(ticket)
                            """
                            try await memoClient.sendText(to: ref, envelope)
                            NSLog("idfon memo sent: \(result.duration)s, ticket \(ticket.prefix(16))...")
                        } catch {
                            NSLog("idfon memo send failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    /// Device pairing automation (no peer-add UI on iOS): launch with
    /// `-pair <endpointAddrJSON> [name]`. Adds the peer, grants message
    /// send/receive both ways, and logs this daemon's own channel ticket
    /// (`idfon self ticket:`) so the remote side can be paired from console
    /// output.
    private func pairPeer(ticketJSON: String, name: String) {
        Task {
            let client = DaemonClient()
            do {
                // Canonical identity id (name may differ, e.g. id "default"
                // vs name "Default" — grants and peer.add must use the id).
                let identity: String
                if let raw = try? await client.request(method: "status") {
                    identity = raw["identity"]?["id"]?.stringValue ?? raw["identity"]?["name"]?.stringValue ?? "default"
                } else {
                    identity = "default"
                }
                // Log our own ticket so `devicectl launch --console` captures it.
                if let raw = try? await client.request(method: "status"),
                   let ticketBytes = raw["ticket"]?.asArray {
                    let data = Data(ticketBytes.compactMap { enc -> UInt8? in
                        guard let v = enc.intValue, v > 0, v < 256 else { return nil }
                        return UInt8(v)
                    })
                    NSLog("idfon self ticket: \(String(data: data, encoding: .utf8) ?? "?")")
                }
                guard let ticket = try JSONSerialization.jsonObject(with: Data(ticketJSON.utf8)) as? [String: Any] else {
                    NSLog("idfon pair failed: invalid ticket JSON")
                    return
                }
                let transport = (ticket["endpoint_addr"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? ticket
                guard let endpointId = (ticket["endpoint_id"] as? String) ?? (transport["id"] as? String), !endpointId.isEmpty else {
                    NSLog("idfon pair failed: ticket has no endpoint_id")
                    return
                }
                let accountId = (ticket["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? endpointId
                let endpointAddr = (ticket["endpoint_addr"] as? String) ?? ticketJSON
                _ = try await client.request(method: "peer.add", params: [
                    "id": AnyEncodable(accountId),
                    "name": AnyEncodable(name),
                    "endpoint_id": AnyEncodable(endpointId),
                    "endpoint_addr": AnyEncodable(endpointAddr),
                    "identity": AnyEncodable(identity),
                ])
                for capability in ["message.send", "message.receive", "live.audio.subscribe"] {
                    _ = try await client.request(method: "access.grant", params: [
                        "identity": AnyEncodable(identity),
                        "subject": AnyEncodable(accountId),
                        "capability": AnyEncodable(capability),
                    ])
                }
                NSLog("idfon paired: peer \(endpointId.prefix(16)) as \(name), identity \(identity)")
            } catch {
                NSLog("idfon pair failed: \(error.localizedDescription)")
            }
        }
    }

    /// `-pair-ticket <agent-peer-id> <ticket-json|ticket-file>`: persist a
    /// ticket minted by the peer's holder (`eve-idfon-channel ticket --subject
    /// <this-app's-peer-id>`) so outbound turns pass its ingress gate. The id
    /// must be the one the app paired the agent under — the `id` field of the
    /// `-pair` EndpointAddr JSON, which is what `sendText` passes as `to`.
    private func storeCapabilityTicket(peer: String, jsonOrPath: String) {
        let json: String
        if jsonOrPath.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            json = jsonOrPath
        } else if let contents = try? String(contentsOfFile: jsonOrPath, encoding: .utf8) {
            json = contents
        } else {
            NSLog("idfon ticket failed: not JSON or a readable file")
            return
        }
        guard CapabilityTickets.store(json, for: peer) else {
            NSLog("idfon ticket failed: not a JSON object")
            return
        }
        NSLog("idfon ticket stored for peer \(peer.prefix(16))")
    }

    private static func dumpLog() {
        // Rust's /tmp resolves to the app sandbox tmp on iOS (std::env::temp_dir).
        let tmp = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        NSLog("idfon dumplog: tmp has \(files.sorted())")
        let path = tmp.appendingPathComponent("idfon-\(ProcessInfo.processInfo.processIdentifier).log").path
        guard let lines = try? String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") else {
            NSLog("idfon dumplog: no log at \(path)")
            return
        }
        NSLog("idfon dumplog: \(lines.count) lines total, tail:")
        for line in lines.suffix(40) { NSLog("| \(line)") }
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    /// M1 smoke check (kept for console diagnostics): log daemon readiness.
    private func smokeCheckStatus() {
        let client = DaemonClient()
        Task {
            for _ in 0..<50 {
                if let status = try? await client.status(), status.ready {
                    NSLog("idfon daemon ready, identity: \(status.identityName)")
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}
