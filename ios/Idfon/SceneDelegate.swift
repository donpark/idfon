import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = UINavigationController(rootViewController: PeerListViewController())
        window?.makeKeyAndVisible()
        connectionOptions.urlContexts.forEach(handleURL)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach(handleURL)
    }

    /// Deep links for call testing/automation:
    ///   idfon://dial/<peer-ref>  — dial a peer (streams the bundled WAV)
    ///   idfon://answer           — arm auto-answer
    private func handleURL(_ context: UIOpenURLContext) {
        let url = context.url
        guard url.scheme == "idfon" else { return }
        NSLog("idfon openURL: \(url)")
        let parts = url.host.map { [$0] + url.pathComponents } ?? url.pathComponents
        switch parts.first {
        case "dial":
            if let ref = parts.dropFirst().first {
                NotificationCenter.default.post(name: .init("idfon.dial"), object: nil, userInfo: ["ref": ref])
            }
        case "answer":
            NotificationCenter.default.post(name: .init("idfon.answer"), object: nil)
        default:
            break
        }
    }
}
