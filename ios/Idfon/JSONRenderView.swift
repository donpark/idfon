import UIKit

/// Draws a normalized [`JSONRenderSpec`] with native views from the app-owned
/// catalog. Every interactive node fires `onAction` with a declarative action
/// name; the remote agent never supplies code (`docs/idfon-edge.md`,
/// P5).
final class JSONRenderView: UIView {
    private let spec: JSONRenderSpec
    /// `Button` action: the registered action name and its arguments.
    var onAction: ((String, [String: JSONValue]) -> Void)?

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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(_ id: String) -> UIView {
        guard let element = spec.elements[id] else { return UIView() }
        switch element.type {
        case "Text":
            let label = UILabel()
            label.numberOfLines = 0
            label.text = element.props?["value"]?.string ?? ""
            return label

        case "Metric":
            let stack = vstack(spacing: 2)
            let value = UILabel()
            value.font = .preferredFont(forTextStyle: .title2)
            value.numberOfLines = 0
            value.text = element.props?["value"]?.string ?? ""
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel
            label.text = element.props?["label"]?.string ?? ""
            stack.addArrangedSubview(value)
            stack.addArrangedSubview(label)
            return stack

        case "Card":
            let card = UIView()
            card.backgroundColor = .secondarySystemBackground
            card.layer.cornerRadius = 12
            let stack = vstack(spacing: 8)
            if let title = element.props?["title"]?.string {
                let label = UILabel()
                label.font = .preferredFont(forTextStyle: .headline)
                label.numberOfLines = 0
                label.text = title
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
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 12
            for child in element.children ?? [] {
                stack.addArrangedSubview(build(child))
            }
            return stack

        case "Button":
            var config = UIButton.Configuration.filled()
            config.title = element.props?["label"]?.string
                ?? element.props?["title"]?.string
                ?? "Action"
            let action = element.props?["action"]?.string ?? ""
            let args = element.props?["args"]?.object ?? [:]
            return UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.onAction?(action, args)
            })

        case "Menu":
            // A list of choices: each child is an item; tapping one dispatches
            // the menu's action with the item's payload under `value` (the
            // label shown is not necessarily the payload sent).
            let stack = vstack(spacing: 4)
            if let title = element.props?["title"]?.string {
                let label = UILabel()
                label.font = .preferredFont(forTextStyle: .headline)
                label.numberOfLines = 0
                label.text = title
                stack.addArrangedSubview(label)
            }
            let action = element.props?["action"]?.string ?? ""
            let fixed = element.props?["args"]?.object ?? [:]
            for child in element.children ?? [] {
                guard let item = spec.elements[child] else { continue }
                let name = item.props?["label"]?.string ?? item.props?["value"]?.string ?? ""
                let payload = item.props?["payload"]?.string ?? name
                if action.isEmpty {
                    let label = UILabel()
                    label.numberOfLines = 0
                    label.text = name
                    stack.addArrangedSubview(label)
                    continue
                }
                var config = UIButton.Configuration.filled()
                config.title = name
                var args = fixed
                args["value"] = .string(payload)
                let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                    self?.onAction?(action, args)
                })
                button.contentHorizontalAlignment = .leading
                stack.addArrangedSubview(button)
            }
            return stack

        case "Input":
            // One inline line of typed input: submit (Send or Return) dispatches
            // the action with the typed text under the `arg` name (default `value`).
            let stack = vstack(spacing: 4)
            if let label = element.props?["label"]?.string {
                let labelView = UILabel()
                labelView.font = .preferredFont(forTextStyle: .caption1)
                labelView.numberOfLines = 0
                labelView.text = label
                stack.addArrangedSubview(labelView)
            }
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            let field = UITextField()
            field.borderStyle = .roundedRect
            field.placeholder = element.props?["placeholder"]?.string
            let action = element.props?["action"]?.string ?? ""
            let arg = element.props?["arg"]?.string ?? "value"
            let args = element.props?["args"]?.object ?? [:]
            let submit: () -> Void = { [weak self] in
                guard let self else { return }
                let text = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !action.isEmpty else { return }
                var merged = args
                merged[arg] = .string(text)
                self.onAction?(action, merged)
            }
            field.addAction(UIAction { _ in submit() }, for: .editingDidEndOnExit)
            var config = UIButton.Configuration.filled()
            config.title = "Send"
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in submit() })
            row.addArrangedSubview(field)
            row.addArrangedSubview(button)
            stack.addArrangedSubview(row)
            return stack

        case "Divider":
            let line = UIView()
            line.backgroundColor = .separator
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return line

        case "Spacer":
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return spacer

        default:
            // `normalized()` already dropped unknown types; belt and suspenders.
            return UIView()
        }
    }

    private func vstack(spacing: CGFloat) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = spacing
        return stack
    }
}
