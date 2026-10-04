import UIKit

/// Contact detail: rename the contact and remove it. Pushed from the contact
/// list's ⓘ accessory so tapping the row still opens the chat.
final class ContactDetailViewController: UIViewController {
    private let client = DaemonClient()
    private let peer: Peer
    /// Fired after a successful rename/remove so the list refreshes.
    var onChanged: (() -> Void)?

    private let nameField = UITextField()

    init(peer: Peer) {
        self.peer = peer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Contact"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(save))

        nameField.text = peer.name ?? ""
        nameField.placeholder = "Name"
        nameField.borderStyle = .roundedRect
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .done
        nameField.addTarget(self, action: #selector(save), for: .editingDidEndOnExit)

        let nameLabel = sectionLabel("Name")
        let idLabel = UILabel()
        idLabel.text = peer.endpointId ?? peer.id
        idLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        idLabel.textColor = .secondaryLabel
        idLabel.numberOfLines = 0

        let delete = UIButton(type: .system)
        delete.setTitle("Delete Contact", for: .normal)
        delete.setTitleColor(.systemRed, for: .normal)
        delete.contentHorizontalAlignment = .leading
        delete.addTarget(self, action: #selector(confirmDelete), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [nameLabel, nameField, sectionLabel("Endpoint"), idLabel, delete])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(24, after: idLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        return label
    }

    @objc private func save() {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return showError("Name cannot be empty.")
        }
        Task {
            do {
                try await client.renamePeer(ref: peer.id, name: name)
                await MainActor.run {
                    self.onChanged?()
                    self.navigationController?.popViewController(animated: true)
                }
            } catch {
                await MainActor.run { self.showError(error.localizedDescription) }
            }
        }
    }

    @objc private func confirmDelete() {
        let alert = UIAlertController(
            title: "Delete \(peer.displayName)?",
            message: "This removes the contact on this device.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.delete()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func delete() {
        Task {
            do {
                try await client.removePeer(ref: peer.id)
                CapabilityTickets.remove(for: peer.id)
                await MainActor.run {
                    self.onChanged?()
                    self.navigationController?.popViewController(animated: true)
                }
            } catch {
                await MainActor.run { self.showError(error.localizedDescription) }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Couldn’t update contact", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
