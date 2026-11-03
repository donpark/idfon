import Foundation

/// One outline entry in a menu contact's OPML resource (docs/live-radio.md
/// "Menu contact"). OPML is data: the app renders it as a nested list, never
/// as content to execute.
struct MenuEntry: Equatable {
    /// The `text` attribute (or `title`), trimmed.
    var title: String
    /// The source the agent plays (`url`/`xmlUrl`) — a far-end URL or a path
    /// in the agent's local download cache. Shown, not interpreted.
    var source: String?
    var children: [MenuEntry]

    var isPlayable: Bool { source != nil }
}

/// The menu document: the OPML body's top-level outline entries.
struct MenuDocument: Equatable {
    var entries: [MenuEntry]

    /// Parse an OPML document; nil when the XML is not well-formed.
    static func parse(_ data: Data) -> MenuDocument? {
        let parser = XMLParser(data: data)
        let outline = OutlineDelegate()
        parser.delegate = outline
        guard parser.parse() else { return nil }
        return MenuDocument(entries: outline.root)
    }

    /// The `show=` selection segment for the entry at `index` in this list:
    /// its title, or its 1-based index when the title contains the path
    /// separator. The agent resolves segments by title or index either way.
    static func segment(_ entry: MenuEntry, at index: Int) -> String {
        entry.title.contains("/") ? "\(index + 1)" : entry.title
    }
}

/// Outline-only parser: nested `<outline>` tags become the tree, everything
/// else (head, other elements) is ignored. Self-closing tags are reported as
/// a start/end pair, so one code path builds the tree.
private final class OutlineDelegate: NSObject, XMLParserDelegate {
    var root: [MenuEntry] = []
    private var stack: [MenuEntry] = []

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes attributeDict: [String: String]
    ) {
        guard name == "outline" else { return }
        let title = (attributeDict["text"] ?? attributeDict["title"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        let source = (attributeDict["url"] ?? attributeDict["xmlUrl"])?
            .trimmingCharacters(in: .whitespaces)
        stack.append(MenuEntry(title: title, source: (source?.isEmpty ?? true) ? nil : source, children: []))
    }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard name == "outline", let entry = stack.popLast() else { return }
        if stack.isEmpty {
            root.append(entry)
        } else {
            stack[stack.count - 1].children.append(entry)
        }
    }
}
