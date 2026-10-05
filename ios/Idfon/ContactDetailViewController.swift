import UIKit

/// Contact detail: rename the contact, choose its per-contact voice engines
/// (STT/TTS, from the agent's fetched `idfon.json` catalog), and remove it.
/// Pushed from the contact list's ⓘ accessory so tapping the row still opens
/// the chat.
final class ContactDetailViewController: UIViewController {
    private let client = DaemonClient()
    private let peer: Peer
    /// Fired after a successful rename/remove so the list refreshes.
    var onChanged: (() -> Void)?

    private let nameField = UITextField()
    private let sttButton = UIButton(type: .system)
    private let ttsButton = UIButton(type: .system)
    private let voiceCaption = UILabel()
    private var catalog: [VoiceOption] = []

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

        configureVoiceControls()

        let delete = UIButton(type: .system)
        delete.setTitle("Delete Contact", for: .normal)
        delete.setTitleColor(.systemRed, for: .normal)
        delete.contentHorizontalAlignment = .leading
        delete.addTarget(self, action: #selector(confirmDelete), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            nameLabel, nameField,
            sectionLabel("Endpoint"), idLabel,
            sectionLabel("Voice"),
            voiceRow("Speech to text", sttButton),
            voiceRow("Text to speech", ttsButton),
            voiceCaption,
            delete,
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(24, after: idLabel)
        stack.setCustomSpacing(24, after: voiceCaption)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - Voice engines

    private func configureVoiceControls() {
        for button in [sttButton, ttsButton] {
            button.showsMenuAsPrimaryAction = true
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.setTitleColor(.label, for: .normal)
        }
        voiceCaption.font = .preferredFont(forTextStyle: .footnote)
        voiceCaption.textColor = .secondaryLabel
        voiceCaption.numberOfLines = 0
        rebuildVoice()
        // The catalog is a fetched resource (`idfon://<peer>/idfon.json`), so
        // the menus fill in once it lands; nothing blocks on it.
        Task { @MainActor in
            catalog = await VoiceCatalog.options(for: peer.id, client: client)
            rebuildVoice()
        }
    }

    private func rebuildVoice() {
        let (stt, tts) = ContactVoiceSelection.selection(for: peer.id)
        sttButton.setTitle(optionLabel(stt), for: .normal)
        ttsButton.setTitle(optionLabel(tts), for: .normal)
        sttButton.menu = voiceMenu(kind: .stt, selected: stt)
        ttsButton.menu = voiceMenu(kind: .tts, selected: tts)
        voiceCaption.text = catalog.isEmpty
            ? "No voice catalog advertised by this agent."
            : "Engines the agent advertises. A full-duplex model fills both."
    }

    private func optionLabel(_ id: String?) -> String {
        guard let id, let option = catalog.first(where: { $0.id == id }) else { return "Automatic" }
        return option.label
    }

    private func voiceMenu(kind: VoiceOption.Kind, selected: String?) -> UIMenu {
        var actions = [UIAction(title: "Automatic", state: selected == nil ? .on : .off) { [weak self] _ in
            self?.choose(kind: kind, id: nil)
        }]
        for option in catalog where option.kind == kind || option.fillsBothSlots {
            actions.append(UIAction(title: option.label, state: option.id == selected ? .on : .off) { [weak self] _ in
                self?.choose(kind: kind, id: option.id)
            })
        }
        return UIMenu(title: kind == .stt ? "Speech to text" : "Text to speech", children: actions)
    }

    private func choose(kind: VoiceOption.Kind, id: String?) {
        var (stt, tts) = ContactVoiceSelection.selection(for: peer.id)
        if let id, let option = catalog.first(where: { $0.id == id }), option.fillsBothSlots {
            // Full-duplex fills both slots.
            stt = id
            tts = id
        } else if kind == .stt {
            stt = id
        } else {
            tts = id
        }
        ContactVoiceSelection.set(stt: stt, tts: tts, for: peer.id)
        rebuildVoice()
    }

    private func voiceRow(_ title: String, _ button: UIButton) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .firstBaseline
        return stack
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
                ContactVoiceSelection.remove(for: peer.id)
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
