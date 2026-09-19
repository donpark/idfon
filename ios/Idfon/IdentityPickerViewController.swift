import UIKit

/// Local persona selector. Each identity has its own peers, history, and
/// transport endpoint; switching never changes the device's other identities.
final class IdentityPickerViewController: UITableViewController {
    private let client = DaemonClient()
    private var identities: [IdentityInfo] = []
    var onChanged: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Identity"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "identity")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addIdentity))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Share", style: .plain, target: self, action: #selector(shareIdentity))
        Task { await reload() }
    }

    private func reload() async {
        let result = (try? await client.identities()) ?? []
        await MainActor.run {
            identities = result
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { identities.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "identity", for: indexPath)
        let identity = identities[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = identity.name
        content.secondaryText = identity.active ? "Current identity" : nil
        cell.contentConfiguration = content
        cell.accessoryType = identity.active ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let identity = identities[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)
        guard !identity.active else { dismiss(animated: true); return }
        Task {
            do {
                try await ChatStore.shared.switchIdentity(to: identity.name)
                await MainActor.run {
                    self.onChanged?()
                    self.dismiss(animated: true)
                }
            } catch {
                await MainActor.run { self.presentError(error.localizedDescription) }
            }
        }
    }

    @objc private func shareIdentity() {
        Task {
            guard let ticket = try? await client.contactTicket() else { return }
            await MainActor.run {
                let sheet = UIActivityViewController(activityItems: [ticket], applicationActivities: nil)
                self.present(sheet, animated: true)
            }
        }
    }

    @objc private func addIdentity() {
        let alert = UIAlertController(title: "New Identity", message: "Create a separate persona on this device.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Work or Personal" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            Task {
                do {
                    try await self.client.createIdentity(name)
                    try await ChatStore.shared.switchIdentity(to: name)
                    await self.reload()
                    await MainActor.run { self.onChanged?(); self.dismiss(animated: true) }
                } catch { await MainActor.run { self.presentError(error.localizedDescription) } }
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
