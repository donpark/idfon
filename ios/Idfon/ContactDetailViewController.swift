import UIKit

/// Person screen (§6): the contact hub. Call and Message are the primary
/// actions (D1); the rest is the relationship's settings (rename, per-contact
/// speech engines, voice turns, remove).
final class ContactDetailViewController: UIViewController {
    private let client = IdfonClient()
    private let peer: Peer
    /// Fired after a successful rename/remove so the list refreshes.
    var onChanged: (() -> Void)?

    private let nameField = UITextField()
    private let recognitionButton = UIButton(type: .system)
    private let generationButton = UIButton(type: .system)
    private let turnModeButton = UIButton(type: .system)
    /// §5.1 contact metadata: tap the contact row → chat + auto-start the call.
    private let instantSwitch = UISwitch()
    /// §5.1 call profile overrides: who the contact is (human vs agent) and
    /// whether calls to them are possible at all (see ContactCallProfiles).
    private let kindButton = UIButton(type: .system)
    private let voiceSwitch = UISwitch()
    private let turnModeCaption = UILabel()
    private let turnModelButton = UIButton(type: .system)
    private let turnModelCaption = UILabel()
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
        // Contact exchange (docs/contact-exchange.md): forward this contact's
        // card or drop it into the system Contacts app.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [
                UIAction(title: "Share Contact Card", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    guard let self else { return }
                    ContactExchange.shareCard(ref: self.peer.id, from: self, sourceView: self.view)
                },
                UIAction(title: "Save to Contacts", image: UIImage(systemName: "person.crop.circle.badge.plus")) { [weak self] _ in
                    self?.saveToSystemContacts()
                },
            ]))

        var callConfig = UIButton.Configuration.filled()
        callConfig.title = "Call"
        callConfig.image = UIImage(systemName: "phone")
        callConfig.baseBackgroundColor = .systemGreen
        callButton.configuration = callConfig
        callButton.addTarget(self, action: #selector(callTapped), for: .touchUpInside)
        callButton.isHidden = !ContactCallProfiles.isCallable(peer.id)
        var messageConfig = UIButton.Configuration.filled()
        messageConfig.title = "Message"
        messageConfig.image = UIImage(systemName: "message")
        messageButton.configuration = messageConfig
        messageButton.addTarget(self, action: #selector(messageTapped), for: .touchUpInside)
        let actionsRow = UIStackView(arrangedSubviews: [callButton, messageButton])
        actionsRow.axis = .horizontal
        actionsRow.spacing = 12
        actionsRow.distribution = .fillEqually
        // §6: shared artifacts/transfers are reachable from here (§14 gallery).
        let artifactsButton = UIButton(configuration: .plain())
        artifactsButton.setTitle("Shared Artifacts", for: .normal)
        artifactsButton.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
        artifactsButton.contentHorizontalAlignment = .leading
        artifactsButton.addTarget(self, action: #selector(openGallery), for: .touchUpInside)

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
        kindButton.showsMenuAsPrimaryAction = true
        kindButton.contentHorizontalAlignment = .trailing
        kindButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        kindButton.setTitleColor(.label, for: .normal)
        rebuildKind()
        voiceSwitch.isOn = ContactCallProfiles.profile(for: peer.id).voiceEnabled
        voiceSwitch.addTarget(self, action: #selector(voiceChanged), for: .valueChanged)
        let kindLabel = UILabel()
        kindLabel.text = "Kind"
        kindLabel.font = .preferredFont(forTextStyle: .body)
        let kindRow = UIStackView(arrangedSubviews: [kindLabel, kindButton])
        kindRow.axis = .horizontal
        kindRow.alignment = .center
        let voiceCallsLabel = UILabel()
        voiceCallsLabel.text = "Voice Calls"
        voiceCallsLabel.font = .preferredFont(forTextStyle: .body)
        let voiceCallsRow = UIStackView(arrangedSubviews: [voiceCallsLabel, voiceSwitch])
        voiceCallsRow.axis = .horizontal
        voiceCallsRow.alignment = .center

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
        turnModelCaption.font = .preferredFont(forTextStyle: .caption1)
        turnModelCaption.textColor = .secondaryLabel
        turnModelCaption.numberOfLines = 0
        rebuildTurnModel()
        turnModelButton.showsMenuAsPrimaryAction = true
        turnModelButton.contentHorizontalAlignment = .leading
        turnModelButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
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
            actionsRow, artifactsButton,
            nameLabel, nameField, instantRow, kindRow, voiceCallsRow,
            sectionLabel("Endpoint"), idLabel,
            sectionLabel("Speech"),
            voiceRow("Recognition", recognitionButton),
            voiceRow("Generation", generationButton),
            sectionLabel("Voice turns"),
            voiceRow("Mode", turnModeButton),
            turnModeCaption,
            voiceRow("Turn model", turnModelButton),
            turnModelCaption,
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
        Automation.mark("call: person screen peer=\(peer.id) dial=\(startCall)")
        let chat = ChatViewController(peer: peer)
        navigationController?.pushViewController(chat, animated: true)
        if startCall { chat.startCall() }
    }

    /// §14: the per-contact artifact gallery.
    @objc private func openGallery() {
        navigationController?.pushViewController(
            ArtifactGalleryViewController(conversation: Conversation(peer: peer)), animated: true)
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

    /// §5.1 call profile overrides also save on change; each control shows the
    /// effective value (the stored override, else the derived default), the
    /// same contract as the speech pickers.
    private func rebuildKind() {
        let kind = ContactCallProfiles.profile(for: peer.id).kind
        kindButton.setTitle(kind == .agent ? "Agent" : "Human", for: .normal)
        kindButton.menu = UIMenu(title: "Kind", children: ContactCallProfile.Kind.allCases.map { option in
            UIAction(title: option == .agent ? "Agent" : "Human",
                     state: option == kind ? .on : .off) { [weak self] _ in
                guard let self else { return }
                ContactCallProfiles.set(kind: option, voice: nil, for: self.peer.id)
                self.rebuildKind()
                self.refreshCallAvailability()
            }
        })
    }

    @objc private func voiceChanged() {
        ContactCallProfiles.set(kind: nil, voice: voiceSwitch.isOn, for: peer.id)
        refreshCallAvailability()
    }

    /// The person screen's Call verb follows the profile the same way the
    /// contacts list's row Call verb does; the list refreshes on return.
    private func refreshCallAvailability() {
        callButton.isHidden = !ContactCallProfiles.isCallable(peer.id)
        onChanged?()
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

    /// Per-contact turn model (the tyger option, `docs/voice-tyger-option.md`):
    /// how turns are decided. `auto` = tyger when the model is available, and
    /// is the default (an override of `auto` clears back to the global).
    private func rebuildTurnModel() {
        let mode = TurnTakerSetting.mode(for: peer.id)
        turnModelButton.setTitle(modelName(mode), for: .normal)
        turnModelButton.menu = UIMenu(title: "Turn model", children: TurnTakerMode.allCases.map { option in
            UIAction(title: self.modelName(option),
                     subtitle: self.modelSubtitle(option),
                     state: option == mode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                TurnTakerSetting.setOverride(option == .auto ? nil : option, for: self.peer.id)
                self.rebuildTurnModel()
            }
        })
        turnModelCaption.text = modelCaption(mode)
    }

    private func modelName(_ mode: TurnTakerMode) -> String {
        switch mode {
        case .auto: return "Auto"
        case .classic: return "Classic"
        case .tyger: return "Tyger"
        }
    }

    private func modelSubtitle(_ mode: TurnTakerMode) -> String {
        switch mode {
        case .auto: return "Tyger when its model is available"
        case .classic: return "The segmenter's timing (always available)"
        case .tyger: return "The turn model's decisions"
        }
    }

    private func modelCaption(_ mode: TurnTakerMode) -> String {
        switch mode {
        case .auto:
            return "The turn model decides turns when it is loaded; the classic segmenter is the fallback."
        case .classic:
            return "Turns commit on recognizer finals or the 1.2 s gap. No model needed."
        case .tyger:
            return "Turns commit at the model's endpoint. Without a loaded model the call falls back to classic."
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

    /// Saves this contact's card (name + `idfon://add/` URL) to the system
    /// Contacts app — the handoff point for AirDrop/NameDrop onward.
    private func saveToSystemContacts() {
        Task {
            do {
                let card = try await ContactExchange.export(ref: peer.id)
                try ContactExchange.saveToSystemContacts(link: card.link)
                await MainActor.run {
                    let alert = UIAlertController(
                        title: "Saved", message: "The card is in your Contacts app.",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            } catch {
                await MainActor.run { self.showError(error.localizedDescription) }
            }
        }
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
