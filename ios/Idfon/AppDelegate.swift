import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DaemonBootstrap.start()
        ChatStore.shared.start()
        smokeCheckStatus()
        handleLaunchArguments()
        return true
    }

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
                    try await LiveCall.dial(peer: ref, seconds: 8, client: client)
                    NSLog("idfon dial done: \(ref)")
                } catch {
                    NSLog("idfon dial failed: \(error.localizedDescription)")
                }
            }
        }
        if args.contains("-answer") {
            Task {
                do {
                    let out = try await LiveCall.armAutoAnswer(waitSeconds: 120, captureSeconds: 8, client: client)
                    NSLog("idfon call recorded to \(out)")
                } catch {
                    NSLog("idfon answer failed: \(error.localizedDescription)")
                }
            }
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
