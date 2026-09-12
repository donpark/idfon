import UIKit

/// Window-level host for Live Activity Bars (docs/ui-design-notes.md §6).
/// One per `UIWindowScene`; the scene delegate must hold a strong reference
/// (an unreferenced window deallocates silently). Sits above content, below
/// alerts and the keyboard. Touches outside the bars pass through.
///
/// Bars dock at the top, **below navigation chrome** (WhatsApp/Telegram
/// "return to call" style): the host reports the nav bar's bottom edge via
/// `topClearance`, and the overlay reports the height it occupies via
/// `contentInset` / `onContentInsetChange` so the host can shift content
/// down (`additionalSafeAreaInsets.top` on the visible content controller).
/// The overlay never moves another window's content itself.
///
/// Multiple models = owning thread's expanded Bar (full width, capped at
/// 560pt on regular widths) plus other contacts' pills (hugging, centered).
final class OverlayWindow: UIWindow {
    /// Emitted with the `peerId` of the bar that produced the intent.
    var onIntent: ((String, LiveActivityBarIntent) -> Void)?

    /// Bottom edge of the top screen's navigation chrome, in window points
    /// (`navigationBar.frame.maxY` of a full-screen nav controller). The bar
    /// stack starts `gutter` below it; never above the safe area. Re-set it
    /// whenever the nav bar height changes (large-title collapse, push/pop).
    var topClearance: CGFloat = 0 {
        didSet { below.constant = topClearance + gutter }
    }

    /// Vertical space the bars occupy below `topClearance`, including both
    /// gutters; 0 when hidden. The host adds this to the visible content
    /// controller's `additionalSafeAreaInsets.top`.
    private(set) var contentInset: CGFloat = 0 {
        didSet { if contentInset != oldValue { onContentInsetChange?(contentInset) } }
    }
    /// Fires on every `contentInset` change (bar appears/disappears, rows
    /// added, Dynamic Type, rotation).
    var onContentInsetChange: ((CGFloat) -> Void)?

    private let gutter: CGFloat = 8
    private let stack = UIStackView()
    private var below: NSLayoutConstraint!
    private var bars: [LiveActivityBar] = []
    private var fullWidth: [NSLayoutConstraint] = []

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .normal + 1
        backgroundColor = .clear
        isHidden = true

        let host = HostController()
        host.view.backgroundColor = .clear
        host.onLayout = { [weak self] in self?.measure() }
        rootViewController = host

        stack.axis = .vertical
        stack.spacing = gutter
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(stack)
        let safe = host.view.safeAreaLayoutGuide
        below = stack.topAnchor.constraint(equalTo: host.view.topAnchor, constant: gutter)
        below.priority = .defaultHigh
        let fill = stack.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -2 * gutter)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            below,
            stack.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: gutter),
            stack.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            fill,
        ])
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    /// Renders one bar per model, in order; empty hides the window.
    func render(_ models: [LiveActivityBarModel]) {
        isHidden = models.isEmpty
        while bars.count < models.count {
            let bar = LiveActivityBar()
            bar.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(bar)
            bars.append(bar)
            fullWidth.append(bar.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        for (index, bar) in bars.enumerated() {
            guard index < models.count else { bar.isHidden = true; continue }
            let model = models[index]
            bar.isHidden = false
            bar.onIntent = { [weak self] in self?.onIntent?(model.peerId, $0) }
            bar.apply(model)
            fullWidth[index].isActive = model.density == .expanded
        }
        if models.isEmpty { contentInset = 0 }   // no layout pass while hidden
    }

    private func measure() {
        guard !isHidden else { return }
        contentInset = stack.frame.height + 2 * gutter
    }

    /// Pass-through: anything that lands on the transparent host view (i.e.
    /// outside every bar) is not ours.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit == rootViewController?.view ? nil : hit
    }
}

/// The stack's frame is applied during its superview's layout pass, so this
/// is the one place every height change (rows, Dynamic Type, rotation) lands.
private final class HostController: UIViewController {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}
