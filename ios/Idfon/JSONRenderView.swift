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
