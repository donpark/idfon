import UIKit

/// Identity management (D20/§11): every identity is live at once, so there is
/// no switcher — only the rare management verbs (create, rename, delete) and
/// the pairing action: tapping a row shares that identity's contact ticket.
final class IdentityPickerViewController: UITableViewController {
    private let client = DaemonClient()
    private var identities: [IdentityInfo] = []
    /// Called after a management change (create / rename / delete).
    var onChanged: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Identities"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "identity")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addIdentity))
        navigationItem.backButtonDisplayMode = .generic
        Task { await reload() }
    }

    private func reload() async {
        let result = (try? await client.identities()) ?? []
        await MainActor.run {
            identities = result
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        identities.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "identity", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = identities[indexPath.row].name
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    /// Tap = the pairing action: share this identity's contact ticket.
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let identity = identities[indexPath.row]
        Task {
            guard let ticket = try? await client.contactTicket(identity: identity.id) else { return }
            await MainActor.run {
                let sheet = UIActivityViewController(activityItems: [ticket], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView =
                    tableView.cellForRow(at: indexPath) ?? tableView
                self.present(sheet, animated: true)
            }
        }
    }

    // MARK: - Management (§11)

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration? {
        let identity = identities[indexPath.row]
        let rename = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, done in
            self?.promptRename(identity)
            done(true)
        }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.confirmDelete(identity)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete, rename])
    }

    private func promptRename(_ identity: IdentityInfo) {
        let alert = UIAlertController(title: "Rename Identity", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = identity.name }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let name = alert?.textFields?.first?.text?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            Task {
                do {
                    try await self.client.renameIdentity(identity.id, name: name)
                    await self.reload()
                    await MainActor.run { self.onChanged?() }
                } catch {
                    await MainActor.run { self.presentError(error.localizedDescription) }
                }
            }
        })
        present(alert, animated: true)
    }

    /// Deleting an identity takes its contacts and chats with it (A9); the
    /// daemon gates deleting the active or last identity.
    private func confirmDelete(_ identity: IdentityInfo) {
        let alert = UIAlertController(
            title: "Delete \(identity.name)?",
            message: "Its contacts and chats are removed from this device.",
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            Task {
                guard let self else { return }
                do {
                    try await self.client.deleteIdentity(identity.id)
                    await self.reload()
                    await MainActor.run { self.onChanged?() }
                } catch {
                    await MainActor.run { self.presentError(error.localizedDescription) }
                }
            }
        })
        alert.popoverPresentationController?.sourceView = tableView
        present(alert, animated: true)
    }

    @objc private func addIdentity() {
        let alert = UIAlertController(title: "New Identity", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Work or Personal" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let name = alert?.textFields?.first?.text?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            Task {
                do {
                    try await self.client.createIdentity(name)
                    await self.reload()
                    await MainActor.run { self.onChanged?() }
                } catch {
                    await MainActor.run { self.presentError(error.localizedDescription) }
                }
            }
        })
        present(alert, animated: true)
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: "Identity Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
