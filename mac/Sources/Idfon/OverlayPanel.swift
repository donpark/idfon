import AppKit

/// Window-level host for the Live Activity Bars (docs/ui-design-notes.md §6).
///
/// Unlike iOS there is no safe-area dance and no hit-test pass-through: the
/// panel is sized to exactly the bars, so it only ever receives clicks it should
/// and there is no transparent area to forward. It floats above the chat window,
/// docked just under the title bar, and reports the space it occupies so the
/// window can shift content down.
final class OverlayPanel: NSPanel {
    /// Emitted with the `peerId` of the bar that produced the intent.
    var onIntent: ((String, LiveActivityBarIntent) -> Void)?

    /// Vertical space the bars occupy below the title bar, including both
    /// gutters; 0 when hidden. The window adds this to its content top.
    private(set) var contentInset: CGFloat = 0 {
        didSet { if contentInset != oldValue { onContentInsetChange?(contentInset) } }
    }
    var onContentInsetChange: ((CGFloat) -> Void)?

    private let stack = NSStackView()
    private var bars: [LiveActivityBar] = []
    private weak var anchorWindow: NSWindow?
    private let gap: CGFloat = 8

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSView()
        stack.orientation = .vertical
        stack.spacing = gap
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        contentView = host
        orderOut(nil)
    }

    /// Anchors the panel under `window`'s title bar.
    func attach(to window: NSWindow) {
        anchorWindow = window
    }

    /// Renders one bar per model, in order; empty hides the panel.
    func render(_ models: [LiveActivityBarModel]) {
        while bars.count < models.count {
            let bar = LiveActivityBar()
            bar.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(bar)
            bars.append(bar)
        }
        for (index, bar) in bars.enumerated() {
            guard index < models.count else { bar.isHidden = true; continue }
            let model = models[index]
            bar.isHidden = false
            bar.onIntent = { [weak self] in self?.onIntent?(model.peerId, $0) }
            bar.apply(model)
        }
        guard !models.isEmpty else {
            contentInset = 0
            orderOut(nil)
            return
        }
        resizeAndPosition()
    }

    private func resizeAndPosition() {
        let fitting = stack.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        setContentSize(NSSize(width: max(fitting.width, 220), height: fitting.height))
        contentInset = fitting.height + 2 * gap
        guard let window = anchorWindow else { return }
        let contentHeight = window.contentRect(forFrameRect: window.frame).height
        let titleBar = window.frame.height - contentHeight
        setFrameOrigin(NSPoint(
            x: window.frame.midX - fitting.width / 2,
            y: window.frame.maxY - titleBar - fitting.height - gap))
        if !isVisible { orderFront(nil) }
    }
}
