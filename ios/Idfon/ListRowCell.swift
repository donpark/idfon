import UIKit

/// §5.2 "one row template app-wide": avatar · title · secondary · trailing
/// time, shared by Contacts, Messages, and Projects.
final class ListRowCell: UITableViewCell {
    static let reuseID = "list-row"

    private let avatarView = UIImageView()
    private let titleLabel = UILabel()
    private let secondaryLabel = UILabel()
    private let timeLabel = UILabel()

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

    /// Row timestamp: clock time today, date otherwise.
    static func time(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .omitted)
    }
}
