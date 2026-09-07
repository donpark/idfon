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
