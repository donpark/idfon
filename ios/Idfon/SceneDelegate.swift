import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate, UITabBarControllerDelegate {
    var window: UIWindow?
    /// Strong scene-level reference: the Live Activity Bar's overlay window
    /// and the call-state coordinator (docs/ui-design-notes.md §6).
    private var liveActivity: LiveActivityController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Bar mode (the default call surface): the overlay is the in-app
        // incoming/active-call UI; content shifts down below it. Each tab is
        // its own nav stack; the Bar renders through whichever is selected.
        // §4 shell: one shell, three perspectives — Contacts / Messages /
        // Projects. Favorites/Recents live in the Contacts tab's D7 filter
        // strip (Favorites joins when pinned contacts exist).
        let contacts = Self.tab(PeerListViewController(), title: "Contacts", symbol: "person.crop.circle")
        let messages = Self.tab(ConversationsViewController(), title: "Messages", symbol: "message")
        let projects = Self.tab(RoomsViewController(), title: "Projects", symbol: "folder")

        let tabs = UITabBarController()
        tabs.viewControllers = [contacts, messages, projects]
        // §4: launch into the last used tab.
        tabs.delegate = self
        tabs.selectedIndex = min(UserDefaults.standard.integer(forKey: "idfon.lastTab"),
                                 (tabs.viewControllers?.count ?? 1) - 1)
        let identityButton = UIBarButtonItem(title: "Identity", style: .plain, target: self, action: #selector(showIdentityPicker))
        contacts.navigationItem.rightBarButtonItem = identityButton

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

        // On-device automation (scripts/ios-device-test.sh): drive the real
        // attachment path with no taps. Runs after a short delay so the scene
        // is active before the thread is pushed and the send begins.
        if let pending = Automation.pendingSendFile {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                Automation.mark("sendfile start peer=\(pending.peer) file=\(pending.file)")
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let url = documents.appendingPathComponent(pending.file)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    Automation.mark("sendfile FAIL missing Documents/\(pending.file)")
                    return
                }
                guard let chat = await activity.automateOpenThread(peerRef: pending.peer) else {
                    Automation.mark("sendfile FAIL no visible thread")
                    return
                }
                chat.automateSendFile(at: url)
            }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach(handleURL)
    }

    /// Scene-based apps do not receive `AppDelegate.applicationWillEnterForeground`,
    /// so this is where the P4 edge handoff is reconciled: pick up any background
    /// fetch that completed while suspended (docs/idfon-edge.md).
    func sceneWillEnterForeground(_ scene: UIScene) {
        _ = EdgeClient.shared.drainInbox()
        if EdgeClient.shared.isProbing { EdgeClient.shared.probeLog("scene willEnterForeground") }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        if EdgeClient.shared.isProbing { EdgeClient.shared.probeLog("scene didEnterBackground") }
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        UserDefaults.standard.set(tabBarController.selectedIndex, forKey: "idfon.lastTab")
    }

    /// §11: identity management lives behind the identity surfaces (P9).
    /// Nothing to gate — every identity is live at once (D20), there is no
    /// switch to protect a call from.
    @objc private func showIdentityPicker() {
        window?.rootViewController?.present(
            UINavigationController(rootViewController: IdentityPickerViewController()),
            animated: true)
    }

    /// One tab: a nav stack with a tab-bar item. Every tab is an
    /// `AppNavigationController` so the Bar's clearance/inset applies to all.
    private static func tab(_ root: UIViewController, title: String, symbol: String) -> AppNavigationController {
        let nav = AppNavigationController(rootViewController: root)
        nav.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), tag: 0)
        return nav
    }

    /// `idfon://` deep links (grammar: `IdfonURL`):
    ///   idfon://<peer-ref>[/path]  — open that peer's thread
    ///   idfon://dial/<peer-ref>    — dial a peer (streams the bundled WAV)
    ///   idfon://videodial/<ref>    — start a video call
    ///   idfon://answer             — arm auto-answer
    ///   idfon://add/<base64url>    — add the contact whose ticket rides in
    ///                                the link (vCard deep link)
    /// `idfon://<ref>/<path>` opens an `EdgeWebView` when the edge is
    /// configured, else the peer's thread. Non-`idfon://` opens are files:
    /// .vcf documents go to `contact.import`.
    private func handleURL(_ context: UIOpenURLContext) {
        guard let link = IdfonURL(context.url) else {
            handleDocument(context.url)
            return
        }
        idfonLog("idfon openURL: \(context.url)")
        switch link {
        case .dial(let ref):
            NotificationCenter.default.post(name: .init("idfon.dial"), object: nil, userInfo: ["ref": ref])
        case .videoDial(let ref):
            VideoCall.shared.dial(ref)
        case .answer:
            NotificationCenter.default.post(name: .init("idfon.answer"), object: nil)
        case .add(let payload):
            guard let ticketJSON = ContactExchange.ticketJSON(fromLink: payload),
                  let presenter = window?.rootViewController else { return }
            ContactExchange.confirmAdd(ticketJSON: ticketJSON, from: presenter) { [weak self] in
                (self?.window?.rootViewController as? UITabBarController)?.selectedIndex = 0
            }
        case .resource(let ref, let path):
            if EdgeClient.shared.isConfigured {
                presentEdgeResource(ref: ref, path: path)
            } else {
                liveActivity?.openThread(peerRef: ref)
            }
        }
    }

    /// A shared .vcf lands here (public.vcard, docs/contact-exchange.md); the
    /// daemon adds every idfon card in the file.
    private func handleDocument(_ url: URL) {
        guard url.pathExtension.lowercased() == "vcf" else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let presenter = window?.rootViewController else { return }
        ContactExchange.importVCard(text: text, from: presenter) { [weak self] in
            (self?.window?.rootViewController as? UITabBarController)?.selectedIndex = 0
        }
    }

    /// Opens a peer resource in a WebView at the edge HTTPS URL (P4). The
    /// requester ticket rides a cookie the edge reads; an unconfigured edge
    /// falls back to the peer's thread.
    private func presentEdgeResource(ref: String, path: [String]) {
        let resourcePath = "/" + path.joined(separator: "/")
        let controller = EdgeWebView(account: ref, resourcePath: resourcePath)
        var presenter = window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        if let presenter {
            presenter.present(UINavigationController(rootViewController: controller), animated: true)
        } else {
            liveActivity?.openThread(peerRef: ref)
        }
    }
}
