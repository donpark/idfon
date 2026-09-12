import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// Strong scene-level reference: the Live Activity Bar's overlay window
    /// and the call-state coordinator (docs/ui-design-notes.md §6).
    private var liveActivity: LiveActivityController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Bar mode (the default call surface): the overlay is the in-app
        // incoming/active-call UI; content shifts down below it. Each tab is
        // its own nav stack; the Bar renders through whichever is selected.
        let favorites = Self.tab(
            PlaceholderViewController(title: "Favorites", symbol: "star",
                                      message: "Favorites you add will appear here."),
            title: "Favorites", symbol: "star")
        let recents = Self.tab(
            PlaceholderViewController(title: "Recents", symbol: "clock",
                                      message: "People you talk to will appear here."),
            title: "Recents", symbol: "clock")
        let contacts = Self.tab(PeerListViewController(), title: "Contacts", symbol: "person.crop.circle")

        let tabs = UITabBarController()
        tabs.viewControllers = [favorites, recents, contacts]

        let activity = LiveActivityController(windowScene: windowScene)
        activity.tabBarController = tabs
        liveActivity = activity

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = tabs
        window?.makeKeyAndVisible()

        // Forward decoded peer frames to the inline video surfaces.
        VideoCall.shared.onFrame = { image in
            NotificationCenter.default.post(name: .idfonVideoFrame, object: image)
        }

        connectionOptions.urlContexts.forEach(handleURL)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach(handleURL)
    }

    /// One tab: a nav stack with a tab-bar item. Every tab is an
    /// `AppNavigationController` so the Bar's clearance/inset applies to all.
    private static func tab(_ root: UIViewController, title: String, symbol: String) -> AppNavigationController {
        let nav = AppNavigationController(rootViewController: root)
        nav.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), tag: 0)
        return nav
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
