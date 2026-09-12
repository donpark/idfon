// Runnable check for the tabbed peer lists (not part of the app target).
// The tabs are dependency-free (peer/recent sources are injected), so this
// builds and runs on the host with plain swiftc:
//
//   swiftc -o /tmp/mac-tabscheck mac/Sources/Idfon/Models.swift \
//     mac/Sources/Idfon/PeerTabsViewController.swift mac/Checks/PeerTabsCheck/main.swift
//   /tmp/mac-tabscheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import AppKit

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

// Models.swift's `Event` needs the type/conformance; the check never decodes one.
struct AnyEncodable: Decodable { let value: Any
    init(from decoder: Decoder) throws { value = NSNull() }
}

MainActor.assumeIsolated {
    let peers = [
        Peer(id: "p1", name: "Ada", endpointId: "ep1", aliases: nil),
        Peer(id: "p2", name: "Bob", endpointId: "ep2", aliases: nil),
        Peer(id: "p3", name: nil, endpointId: nil, aliases: nil),
    ]
    var selected: [String] = []
    let tabs = PeerTabsViewController(
        peersProvider: { peers },
        recentPeerIds: { ["p3", "p1"] },
        onSelect: { selected.append($0.id) })
    _ = tabs.view // load the view hierarchy
    _ = selected // selection forwarding is exercised in the app

    check(tabs.tabLabels == ["Favorites", "Recents", "Contacts"], "tab labels: \(tabs.tabLabels)")
    check(tabs.tabStyle == .segmentedControlOnTop, "segmented tabs on top: \(tabs.tabStyle.rawValue)")

    let sections = tabs.sections
    check(sections.count == 3, "three sections: \(sections.count)")
    let favorites = sections[0], recents = sections[1], contacts = sections[2]

    // Contacts holds everything; Favorites is still a placeholder.
    contacts.reload()
    check(contacts.displayedPeers.map(\.id) == ["p1", "p2", "p3"], "contacts lists all: \(contacts.displayedPeers.map(\.id))")
    favorites.reload()
    check(favorites.displayedPeers.isEmpty, "favorites is a placeholder: \(favorites.displayedPeers.map(\.id))")

    // Recents follows the injected order (newest first), not the peer order.
    recents.reload()
    check(recents.displayedPeers.map(\.id) == ["p3", "p1"], "recents order: \(recents.displayedPeers.map(\.id))")

    // Search is per-section, matching name or id, and falls back to text only.
    contacts.search("ada")
    check(contacts.displayedPeers.map(\.id) == ["p1"], "name match: \(contacts.displayedPeers.map(\.id))")
    contacts.search("ep2")
    check(contacts.displayedPeers.map(\.id) == ["p2"], "endpoint-id match: \(contacts.displayedPeers.map(\.id))")
    contacts.search("p3")
    check(contacts.displayedPeers.map(\.id) == ["p3"], "bare id match (unnamed peer): \(contacts.displayedPeers.map(\.id))")
    contacts.search("nobody")
    check(contacts.displayedPeers.isEmpty, "no matches yields empty")
    contacts.search("") // cleared

    // A query in one tab must not filter another.
    recents.search("bob") // Bob is not in Recents
    check(recents.displayedPeers.isEmpty, "recents has no Bob: \(recents.displayedPeers.map(\.id))")
    recents.search("ada") // Ada is in Recents
    check(recents.displayedPeers.map(\.id) == ["p1"], "recents filters within itself: \(recents.displayedPeers.map(\.id))")
    contacts.reload()
    check(contacts.displayedPeers.count == 3, "contacts unaffected by the recents query: \(contacts.displayedPeers.count)")

    print("ALL OK")
}
