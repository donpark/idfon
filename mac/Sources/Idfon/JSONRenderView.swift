import AppKit

/// Draws a normalized [`JSONRenderSpec`] with native AppKit views from the
/// app-owned catalog (`docs/idfon-edge.md`, P5). Every interactive
/// node fires `onAction`; the remote agent never supplies code.
final class JSONRenderView: NSView {
    private let spec: JSONRenderSpec
    /// `Button` action: the registered action name and its arguments.
    var onAction: ((String, [String: JSONValue]) -> Void)?
    private var buttonActions: [(String, [String: JSONValue])] = []

    init(spec: JSONRenderSpec) {
        self.spec = spec
        super.init(frame: .zero)
        let root = build(spec.root)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(_ id: String) -> NSView {
        guard let element = spec.elements[id] else { return NSView() }
        switch element.type {
        case "Text":
            return Self.label(element.props?["value"]?.string ?? "")

        case "Metric":
            let stack = vstack(spacing: 2)
            let value = Self.label(element.props?["value"]?.string ?? "")
            value.font = .preferredFont(forTextStyle: .title2)
            let label = Self.label(element.props?["label"]?.string ?? "")
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(value)
            stack.addArrangedSubview(label)
            return stack

        case "Card":
            let card = NSView()
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            card.layer?.cornerRadius = 12
            let stack = vstack(spacing: 8)
            if let title = element.props?["title"]?.string {
                let label = Self.label(title)
                label.font = .preferredFont(forTextStyle: .headline)
                stack.addArrangedSubview(label)
            }
            for child in element.children ?? [] {
                stack.addArrangedSubview(build(child))
            }
            stack.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            ])
            return card

        case "Row":
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 12
            for child in element.children ?? [] {
                stack.addArrangedSubview(build(child))
            }
            return stack

        case "Button":
            let title = element.props?["label"]?.string
                ?? element.props?["title"]?.string
                ?? "Action"
            let button = NSButton(title: title, target: self, action: #selector(buttonTapped(_:)))
            button.bezelStyle = .rounded
            button.setButtonType(.momentaryPushIn)
            buttonActions.append((
                element.props?["action"]?.string ?? "",
                element.props?["args"]?.object ?? [:]
            ))
            button.tag = buttonActions.count - 1
            return button

        case "Divider":
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.separatorColor.cgColor
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return line

        case "Spacer":
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return spacer

        default:
            // `normalized()` already dropped unknown types; belt and suspenders.
            return NSView()
        }
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        guard buttonActions.indices.contains(sender.tag) else { return }
        let (action, args) = buttonActions[sender.tag]
        onAction?(action, args)
    }

    private func vstack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = spacing
        return stack
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        return label
    }
}
