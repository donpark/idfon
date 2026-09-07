import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DaemonBootstrap.start()
        ChatStore.shared.start()

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UINavigationController(rootViewController: PeerListViewController())
        window?.makeKeyAndVisible()

        smokeCheckStatus()
        return true
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
