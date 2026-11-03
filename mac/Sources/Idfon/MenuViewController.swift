import AppKit

/// A menu contact's navigation surface (mac): the OPML outline in a sheet
/// (docs/live-radio.md "Menu contact"). The screen carries the choices;
/// picking a playable show hands its `show=` path to `onPlay`, which dials the
/// call that plays it. Sections expand in place (disclosure triangles).
final class MenuViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// MenuEntry is a struct and NSOutlineView items need identity, so the
    /// tree is boxed once — each node carries its own `show=` path.
    private final class Node {
        let entry: MenuEntry
        let path: String
        let children: [Node]

        init(entry: MenuEntry, prefix: String, index: Int) {
            self.entry = entry
            let segment = MenuDocument.segment(entry, at: index)
            let path = prefix.isEmpty ? segment : "\(prefix)/\(segment)"
            self.path = path
            self.children = entry.children.enumerated()
                .map { Node(entry: $0.element, prefix: path, index: $0.offset) }
        }
    }

    private let roots: [Node]
    private let onPlay: (String) -> Void
    private let outline = NSOutlineView()

    init(entries: [MenuEntry], onPlay: @escaping (String) -> Void) {
        self.roots = entries.enumerated()
            .map { Node(entry: $0.element, prefix: "", index: $0.offset) }
        self.onPlay = onPlay
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MenuViewController is built in code") }

    override func loadView() {
        view = NSView()
        let column = NSTableColumn(identifier: .init("entry"))
        column.title = "Menu"
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = 40
        outline.style = .plain
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        preferredContentSize = NSSize(width: 380, height: 420)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? roots.count : (item as! Node).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !(item as! Node).children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? roots[index] : (item as! Node).children[index]
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! Node
        let cell = outlineView.makeView(withIdentifier: .init("menuCell"), owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = .init("menuCell")
        let labels: [NSTextField]
        if cell.subviews.isEmpty {
            let name = NSTextField(labelWithString: "")
            let source = NSTextField(labelWithString: "")
            cell.addSubview(name)
            cell.addSubview(source)
            cell.textField = name
            for subview in cell.subviews { subview.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([
                name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
                name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                source.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
                source.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                source.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            ])
            labels = [name, source]
        } else {
            labels = cell.subviews.compactMap { $0 as? NSTextField }
        }
        labels[0].stringValue = node.entry.title
        labels[0].font = NSFont.systemFont(ofSize: 13, weight: .medium)
        // The source is data to show (what would play), never a link to open.
        labels[1].stringValue = node.entry.source ?? ""
        labels[1].font = NSFont.systemFont(ofSize: 11)
        labels[1].textColor = .secondaryLabelColor
        return cell
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node,
              node.entry.isPlayable else { return }
        onPlay(node.path)
        dismiss(self)
    }
}
