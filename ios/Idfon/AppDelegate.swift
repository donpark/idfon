import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DaemonBootstrap.start()
        waitForDaemonThenShowStatus()
        return true
    }

    /// M1 smoke check: poll `status` until the in-process daemon answers.
    private func waitForDaemonThenShowStatus() {
        let client = DaemonClient()
        Task {
            for _ in 0..<50 {
                if let result = try? await client.request(method: "status") {
                    NSLog("idfon daemon ready: \(result)")
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}
