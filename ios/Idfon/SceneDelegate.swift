import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = UINavigationController(rootViewController: PeerListViewController())
        window?.makeKeyAndVisible()

        // Present/dismiss the call screen with call state; forward frames.
        VideoCall.shared.onState = { [weak self] in self?.syncCallScreen() }
        VideoCall.shared.onFrame = { image in
            NotificationCenter.default.post(name: .idfonVideoFrame, object: image)
        }

        connectionOptions.urlContexts.forEach(handleURL)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach(handleURL)
    }

    /// Presents the full-screen call UI whenever a call is active.
    private func syncCallScreen() {
        guard let window else { return }
        let root = window.rootViewController
        var top = root
        while let next = top?.presentedViewController { top = next }
        let call = VideoCall.shared
        if call.state != .idle {
            if !(top is CallViewController) {
                let callVC = CallViewController()
                callVC.modalPresentationStyle = .fullScreen
                top?.present(callVC, animated: true)
            }
        } else if let callVC = top as? CallViewController, !(callVC.isBeingDismissed) {
            callVC.dismiss(animated: true)
        }
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
        case "videodial":
            if let ref = parts.dropFirst().first {
                VideoCall.shared.dial(ref)
            }
        case "answer":
            NotificationCenter.default.post(name: .init("idfon.answer"), object: nil)
        default:
            break
        }
    }
}
