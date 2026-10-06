import UIKit

/// Contact detail: rename the contact, choose its per-contact speech engines
/// (on-device backends plus the agent's fetched `idfon.json` options) from one
/// "Speech" section, and remove it. Pushed from the contact list's ⓘ accessory
/// so tapping the row still opens the chat.
final class ContactDetailViewController: UIViewController {
    private let client = DaemonClient()
    private let peer: Peer
    /// Fired after a successful rename/remove so the list refreshes.
    var onChanged: (() -> Void)?

    private let nameField = UITextField()
    private let recognitionButton = UIButton(type: .system)
    private let generationButton = UIButton(type: .system)
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

        configureSpeech()

        let delete = UIButton(type: .system)
        delete.setTitle("Delete Contact", for: .normal)
        delete.setTitleColor(.systemRed, for: .normal)
        delete.contentHorizontalAlignment = .leading
        delete.addTarget(self, action: #selector(confirmDelete), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            nameLabel, nameField,
            sectionLabel("Endpoint"), idLabel,
            sectionLabel("Speech"),
            voiceRow("Recognition", recognitionButton),
            voiceRow("Generation", generationButton),
            delete,
        ])
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

    // MARK: - Speech engines

    /// One "Speech" section with two pickers. Each spans the app's on-device
    /// backends and the agent's fetched `idfon.json` options; the value shown is
    /// the effective engine (the stored pick, else the app default), never
    /// "Automatic".
    private func configureSpeech() {
        for button in [recognitionButton, generationButton] {
            button.showsMenuAsPrimaryAction = true
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.setTitleColor(.label, for: .normal)
        }
        rebuildSpeech()
        // The catalog is a fetched resource (`idfon://<peer>/idfon.json`), so
        // the menus fill in once it lands; nothing blocks on it.
        Task { @MainActor in
            catalog = await VoiceCatalog.options(for: peer.id, client: client)
            rebuildSpeech()
        }
    }

    private func rebuildSpeech() {
        for slot in [SpeechSlot.recognition, .generation] {
            let choices = choices(for: slot)
            let effective = effectiveChoice(for: slot)
            let button = button(for: slot)
            button.setTitle(resolvedTitle(effective, in: choices, slot: slot), for: .normal)
            button.menu = speechMenu(choices: choices, effective: effective, slot: slot)
        }
    }

    private func button(for slot: SpeechSlot) -> UIButton {
        slot == .recognition ? recognitionButton : generationButton
    }

    /// The effective pick: the stored choice, else the app-global backend for
    /// the slot, so the picker always shows a real engine (never "Automatic").
    private func effectiveChoice(for slot: SpeechSlot) -> SpeechChoice {
        ContactSpeech.stored(for: peer.id, slot: slot) ?? SpeechChoice(
            store: .onDevice,
            id: slot == .recognition ? SpeechEngines.asrBackend.rawValue : SpeechEngines.backend.rawValue,
            title: "")
    }

    /// On-device backends first, then the agent's catalog options for the slot.
    private func choices(for slot: SpeechSlot) -> [SpeechChoice] {
        let onDevice: [SpeechChoice] = slot == .recognition
            ? AsrBackend.allCases.map { SpeechChoice(store: .onDevice, id: $0.rawValue, title: $0.title) }
            : TtsBackend.allCases.map { SpeechChoice(store: .onDevice, id: $0.rawValue, title: $0.title) }
        let kind: VoiceOption.Kind = slot == .recognition ? .stt : .tts
        let advertised = catalog
            .filter { $0.kind == kind || $0.fillsBothSlots }
            .map { SpeechChoice(store: .catalog, id: $0.id, title: $0.label) }
        return onDevice + advertised
    }

    private func resolvedTitle(_ effective: SpeechChoice, in choices: [SpeechChoice], slot: SpeechSlot) -> String {
        choices.first { $0.store == effective.store && $0.id == effective.id }?.title
            ?? (slot == .recognition ? SpeechEngines.asrBackend.title : SpeechEngines.backend.title)
    }

    private func speechMenu(choices: [SpeechChoice], effective: SpeechChoice, slot: SpeechSlot) -> UIMenu {
        let actions = choices.map { choice in
            UIAction(
                title: choice.title,
                state: effective.store == choice.store && effective.id == choice.id ? .on : .off
            ) { [weak self] _ in
                self?.choose(choice, slot: slot)
            }
        }
        return UIMenu(title: slot == .recognition ? "Recognition" : "Generation", children: actions)
    }

    private func choose(_ choice: SpeechChoice, slot: SpeechSlot) {
        ContactSpeech.set(choice, catalog: catalog, for: peer.id, slot: slot)
        rebuildSpeech()
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
                ContactOnDeviceEngines.remove(for: peer.id)
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
