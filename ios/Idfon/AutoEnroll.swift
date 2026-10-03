import Foundation

/// Peers whose `IDFON-INVITE/1` contact invites may be enrolled without a
/// confirmation prompt. This is an explicit, revocable trust decision — being a
/// known contact is not enough, or any agent could add contacts on your behalf.
/// The transport already authenticates and signature-binds the inviter, so this
/// list is the policy layer on top of that.
enum AutoEnroll {
    private static let defaultsKey = "idfon.autoEnrollPeers"

    static func isTrusted(_ peer: String) -> Bool {
        peers().contains(peer)
    }

    static func trust(_ peer: String) {
        guard !peer.isEmpty else { return }
        save(peers().union([peer]))
    }

    static func revoke(_ peer: String) {
        save(peers().subtracting([peer]))
    }

    private static func peers() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    private static func save(_ peers: Set<String>) {
        UserDefaults.standard.set(Array(peers).sorted(), forKey: defaultsKey)
    }
}
