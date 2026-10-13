import UIKit

/// Person screen (§6): the contact hub. Call and Message are the primary
/// actions (D1); the rest is the relationship's settings (rename, per-contact
/// speech engines, voice turns, remove).
final class ContactDetailViewController: UIViewController {
    private let client = DaemonClient()
    private let peer: Peer
    /// Fired after a successful rename/remove so the list refreshes.
    var onChanged: (() -> Void)?

    private let nameField = UITextField()
    private let recognitionButton = UIButton(type: .system)
    private let generationButton = UIButton(type: .system)
    private let turnModeButton = UIButton(type: .system)
    /// §5.1 contact metadata: tap the contact row → chat + auto-start the call.
    private let instantSwitch = UISwitch()
    private let turnModeCaption = UILabel()
    private var catalog: [VoiceOption] = []
    /// §6 primary actions: Call starts the call, Message opens the chat. Both
    /// push the chat (the room surface) so back returns here.
    private let callButton = UIButton(configuration: .filled())
    private let messageButton = UIButton(configuration: .filled())

    init(peer: Peer) {
        self.peer = peer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = peer.displayName
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(save))

        var callConfig = UIButton.Configuration.filled()
        callConfig.title = "Call"
        callConfig.image = UIImage(systemName: "phone")
        callConfig.baseBackgroundColor = .systemGreen
        callButton.configuration = callConfig
        callButton.addTarget(self, action: #selector(callTapped), for: .touchUpInside)
        var messageConfig = UIButton.Configuration.filled()
        messageConfig.title = "Message"
        messageConfig.image = UIImage(systemName: "message")
        messageButton.configuration = messageConfig
        messageButton.addTarget(self, action: #selector(messageTapped), for: .touchUpInside)
        let actionsRow = UIStackView(arrangedSubviews: [callButton, messageButton])
        actionsRow.axis = .horizontal
        actionsRow.spacing = 12
        actionsRow.distribution = .fillEqually

        nameField.text = peer.name ?? ""
        nameField.placeholder = "Name"
        nameField.borderStyle = .roundedRect
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .done
        nameField.addTarget(self, action: #selector(save), for: .editingDidEndOnExit)
        instantSwitch.isOn = peer.instantCall
        instantSwitch.addTarget(self, action: #selector(instantChanged), for: .valueChanged)
        let instantLabel = UILabel()
        instantLabel.text = "Instant Call"
        instantLabel.font = .preferredFont(forTextStyle: .body)
        let instantRow = UIStackView(arrangedSubviews: [instantLabel, instantSwitch])
        instantRow.axis = .horizontal
        instantRow.alignment = .center

        let nameLabel = sectionLabel("Name")
        let idLabel = UILabel()
        idLabel.text = peer.endpointId ?? peer.id
        idLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        idLabel.textColor = .secondaryLabel
        idLabel.numberOfLines = 0

        configureSpeech()
        turnModeCaption.font = .preferredFont(forTextStyle: .caption1)
        turnModeCaption.textColor = .secondaryLabel
        turnModeCaption.numberOfLines = 0
        rebuildTurnMode()
        turnModeButton.showsMenuAsPrimaryAction = true
        turnModeButton.contentHorizontalAlignment = .leading
        turnModeButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        turnModeButton.setTitleColor(.label, for: .normal)

        let delete = UIButton(type: .system)
        delete.setTitle("Delete Contact", for: .normal)
        delete.setTitleColor(.systemRed, for: .normal)
        delete.contentHorizontalAlignment = .leading
        delete.addTarget(self, action: #selector(confirmDelete), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            actionsRow,
            nameLabel, nameField, instantRow,
            sectionLabel("Endpoint"), idLabel,
            sectionLabel("Speech"),
            voiceRow("Recognition", recognitionButton),
            voiceRow("Generation", generationButton),
            sectionLabel("Voice turns"),
            voiceRow("Mode", turnModeButton),
            turnModeCaption,
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

    // MARK: - §6 primary actions

    @objc private func messageTapped() {
        pushChat(startCall: false)
    }

    @objc private func callTapped() {
        pushChat(startCall: true)
    }

    /// Pushes the chat surface; `startCall` runs the same routing the chat's
    /// call button would (on-device, delegated, live, or classic).
    private func pushChat(startCall: Bool) {
        let chat = ChatViewController(peer: peer)
        navigationController?.pushViewController(chat, animated: true)
        if startCall { chat.startCall() }
    }

    /// §5.1: the instant-call flag saves on flip (contact metadata, not the
    /// saved name field).
    @objc private func instantChanged() {
        Task { [weak self] in
            guard let self else { return }
            try? await self.client.updatePeerFlags(
                ref: self.peer.id, identity: self.peer.identity, instantCall: self.instantSwitch.isOn)
        }
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

    // MARK: - Voice turns

    /// Per-contact turn mode: who answers the caller (`docs/voice-agent-modes.md`).
    /// Passive is the default and costs nothing extra; proxy runs the on-device
    /// director in front of the agent, which can answer, delegate, or hold a tool.
    private func rebuildTurnMode() {
        let mode = ContactVoiceTurnModes.mode(for: peer.id)
        turnModeButton.setTitle(mode.title, for: .normal)
        turnModeButton.menu = UIMenu(title: "Voice turns", children: VoiceTurnMode.allCases.map { option in
            UIAction(title: option.title,
                     subtitle: option == .proxy ? "On-device director in front" : "The agent answers",
                     state: option == mode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                ContactVoiceTurnModes.set(option, for: self.peer.id)
                self.rebuildTurnMode()
            }
        })
        turnModeCaption.text = Self.caption(for: mode)
    }

    /// What the mode means for the call, in one line. Says what it costs, since
    /// proxy is the only per-contact setting that adds a model turn.
    private static func caption(for mode: VoiceTurnMode) -> String {
        switch mode {
        case .passive:
            return "The agent hears your words and answers. Nothing runs in front of it."
        case .proxy:
            return "The on-device director hears the turn first and either answers or forwards it. Adds an on-device turn to every remote one."
        }
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
                try await client.removePeer(ref: peer.id, identity: peer.identity)
                CapabilityTickets.remove(for: peer.id)
                ContactVoiceSelection.remove(for: peer.id)
                ContactOnDeviceEngines.remove(for: peer.id)
                ContactVoiceTurnModes.remove(for: peer.id)
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
