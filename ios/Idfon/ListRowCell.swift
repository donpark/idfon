import UIKit

/// §5.2 "one row template app-wide": avatar · title · secondary · trailing
/// time, shared by Contacts, Messages, and Projects.
final class ListRowCell: UITableViewCell {
    static let reuseID = "list-row"

    private let avatarView = UIImageView()
    private let titleLabel = UILabel()
    private let secondaryLabel = UILabel()
    private let timeLabel = UILabel()
    /// §5.1: the row's optional Call verb — a button left of the chevron.
    private let callButton = UIButton(type: .system)
    private let accessoryStack = UIStackView()
    private var onCall: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.layer.cornerRadius = 18
        avatarView.clipsToBounds = true
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        secondaryLabel.textColor = .secondaryLabel
        secondaryLabel.adjustsFontForContentSizeCategory = true
        secondaryLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = .preferredFont(forTextStyle: .caption1)
        timeLabel.textColor = .secondaryLabel
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        let textStack = UIStackView(arrangedSubviews: [titleLabel, secondaryLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        let row = UIStackView(arrangedSubviews: [avatarView, textStack, timeLabel])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),
        ])
        // §5.1: accessory area = [Call] · chevron; `setCallAction` swaps it in.
        callButton.translatesAutoresizingMaskIntoConstraints = false
        callButton.setImage(UIImage(systemName: "phone.fill"), for: .normal)
        callButton.tintColor = .systemGreen
        callButton.accessibilityLabel = "Call"
        callButton.addTarget(self, action: #selector(callTapped), for: .touchUpInside)
        callButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        callButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        accessoryStack.axis = .horizontal
        accessoryStack.spacing = 4
        accessoryStack.alignment = .center
        accessoryStack.addArrangedSubview(callButton)
        accessoryStack.addArrangedSubview(chevron)
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    func configure(avatar: String?, title: String, secondary: String?, time: String?) {
        avatarView.image = avatar.map { Avatar.image($0) }
        avatarView.isHidden = avatar == nil
        titleLabel.text = title
        secondaryLabel.text = secondary
        secondaryLabel.isHidden = (secondary ?? "").isEmpty
        timeLabel.text = time
    }

    /// §5.1 row Call verb: shown left of the chevron; nil restores the plain
    /// disclosure chevron (other lists reuse this row template).
    func setCallAction(_ action: (() -> Void)?) {
        onCall = action
        accessoryView = action == nil ? nil : accessoryStack
        accessoryType = action == nil ? .disclosureIndicator : .none
    }

    @objc private func callTapped() { onCall?() }

    /// Row timestamp: clock time today, date otherwise.
    static func time(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .omitted)
    }
}
