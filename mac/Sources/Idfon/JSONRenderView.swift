import AppKit

/// Draws a normalized [`JSONRenderSpec`] with native AppKit views from the
/// app-owned catalog (`docs/idfon-edge.md`, P5). Every interactive
/// node fires `onAction`; the remote agent never supplies code.
final class JSONRenderView: NSView {
    private let spec: JSONRenderSpec
    /// `Button` action: the registered action name and its arguments.
    var onAction: ((String, [String: JSONValue]) -> Void)?
    private var buttonActions: [(String, [String: JSONValue])] = []
    /// `Input` rows: the field, the action to submit to, the arg the typed
    /// text fills, and the fixed args merged into every dispatch.
    private var inputRows: [(NSTextField, String, String, [String: JSONValue])] = []

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

        case "Menu":
            // A list of choices: each child is an item; tapping one dispatches
            // the menu's action with the item's payload under `value` (the
            // label shown is not necessarily the payload sent).
            let stack = vstack(spacing: 4)
            if let title = element.props?["title"]?.string {
                let label = Self.label(title)
                label.font = .preferredFont(forTextStyle: .headline)
                stack.addArrangedSubview(label)
            }
            let action = element.props?["action"]?.string ?? ""
            let fixed = element.props?["args"]?.object ?? [:]
            for child in element.children ?? [] {
                guard let item = spec.elements[child] else { continue }
                let name = item.props?["label"]?.string ?? item.props?["value"]?.string ?? ""
                let payload = item.props?["payload"]?.string ?? name
                if action.isEmpty {
                    stack.addArrangedSubview(Self.label(name))
                    continue
                }
                let button = NSButton(title: name, target: self, action: #selector(buttonTapped(_:)))
                button.bezelStyle = .rounded
                button.setButtonType(.momentaryPushIn)
                button.alignment = .left
                var args = fixed
                args["value"] = .string(payload)
                buttonActions.append((action, args))
                button.tag = buttonActions.count - 1
                stack.addArrangedSubview(button)
            }
            return stack

        case "Input":
            // One inline line of typed input: submit (Send or Return) dispatches
            // the action with the typed text under the `arg` name (default `value`).
            let stack = vstack(spacing: 4)
            if let label = element.props?["label"]?.string {
                let labelView = Self.label(label)
                labelView.font = .preferredFont(forTextStyle: .caption1)
                stack.addArrangedSubview(labelView)
            }
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let field = NSTextField()
            field.placeholderString = element.props?["placeholder"]?.string
            field.target = self
            field.action = #selector(inputSubmitted(_:))
            let submit = NSButton(title: "Send", target: self, action: #selector(inputSubmitted(_:)))
            submit.bezelStyle = .rounded
            submit.setButtonType(.momentaryPushIn)
            inputRows.append((
                field,
                element.props?["action"]?.string ?? "",
                element.props?["arg"]?.string ?? "value",
                element.props?["args"]?.object ?? [:]
            ))
            field.tag = inputRows.count - 1
            submit.tag = field.tag
            row.addArrangedSubview(field)
            row.addArrangedSubview(submit)
            stack.addArrangedSubview(row)
            return stack

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

    @objc private func inputSubmitted(_ sender: NSControl) {
        guard inputRows.indices.contains(sender.tag) else { return }
        let (field, action, arg, args) = inputRows[sender.tag]
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !action.isEmpty else { return }
        var merged = args
        merged[arg] = .string(text)
        onAction?(action, merged)
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
