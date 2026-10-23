import UIKit

/// Person screen (§6, `docs/ios-ui-design.md`): ONE contact screen for every
/// contact — human peers, agent-backed peers (eve), and on-device agent
/// contacts (AFM 3, user-created agents alike).
///
/// It edits the **contact, not the agent** (`docs/voice-agent-modes.md`): the
/// settings here — name, speech engines (ASR/TTS), voice turns, call profile —
/// are per-contact parameters passed to the contact's agent at call time (an
/// on-device agent's picks resolve in `VoiceAgentSession` for its `local:` id;
/// a remote agent's selection rides the invite). The agent's own content lives
/// in the agent editor (`OnDeviceAgentEditorViewController`), entered from
/// here for agents the user has editor write to.
///
/// Two modes, iOS Contacts style: **view** shows the primary actions
/// (Call / Message / Shared Artifacts) plus read-only settings rows; **edit**
/// turns every setting into a control and commits on Save — one save path,
/// nothing applies mid-edit (the earlier screen mixed an instant-apply picker
/// with a Save button that also popped).
final class ContactDetailViewController: UIViewController {
    private let client = IdfonClient()
    /// The contact. On-device agents arrive as their `local:` peer
    /// (`OnDeviceAgent.peerId`).
    private let peer: Peer
    private var agent: OnDeviceAgent?
    /// Fired after save/remove so the list refreshes and the chat title follows.
    var onChanged: (() -> Void)?

    // MARK: Staged settings (edit mode)

    /// Everything the edit mode can change. Save applies it in one commit;
    /// Cancel drops it.
    private struct Draft {
        var name = ""
        var kind: ContactCallProfile.Kind = .human
        var voiceEnabled = true
        var instant = false
        var stt: SpeechChoice?
        var tts: SpeechChoice?
        var turnMode: VoiceTurnMode = .passive
        var turnModel: TurnTakerMode = .auto
    }

    private var draft = Draft()
    private var settingsEditing = false
    private var catalog: [VoiceOption] = []

    // MARK: Controls (reused across mode switches)

    private let stack = UIStackView()
    private let callButton = UIButton(configuration: .filled())
    private let messageButton = UIButton(configuration: .filled())
    private let artifactsButton = UIButton(configuration: .plain())
    private let nameField = UITextField()
    private let kindButton = UIButton(type: .system)
    private let instantSwitch = UISwitch()
    private let voiceSwitch = UISwitch()
    private let recognitionButton = UIButton(type: .system)
    private let generationButton = UIButton(type: .system)
    private let turnModeButton = UIButton(type: .system)
    private let turnModelButton = UIButton(type: .system)
    private let turnModeCaption = UILabel()
    private let turnModelCaption = UILabel()

    // MARK: Identity

    private var peerID: String { agent?.peerId ?? peer.id }
    /// Editor write: agents the user created. The built-in AFM 3's agent
    /// content is not user-editable ("don't go overboard with AFM 3").
    private var canEditAgent: Bool {
        guard let agent else { return false }
        return agent.id != OnDeviceAgents.builtInId
    }

    init(peer: Peer) {
        self.peer = peer
        self.agent = OnDeviceAgents.shared.agent(forPeerId: peer.id)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

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

        artifactsButton.setTitle("Shared Artifacts", for: .normal)
        artifactsButton.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
        artifactsButton.contentHorizontalAlignment = .leading
        artifactsButton.addTarget(self, action: #selector(openGallery), for: .touchUpInside)

        nameField.borderStyle = .roundedRect
        nameField.placeholder = "Name"
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .done
        nameField.addTarget(self, action: #selector(save), for: .editingDidEndOnExit)

        for button in [kindButton, recognitionButton, generationButton, turnModeButton, turnModelButton] {
            button.showsMenuAsPrimaryAction = true
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.setTitleColor(.label, for: .normal)
        }
        instantSwitch.addTarget(self, action: #selector(pickChanged), for: .valueChanged)
        voiceSwitch.addTarget(self, action: #selector(pickChanged), for: .valueChanged)
        for caption in [turnModeCaption, turnModelCaption] {
            caption.font = .preferredFont(forTextStyle: .caption1)
            caption.textColor = .secondaryLabel
            caption.numberOfLines = 0
        }

        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        loadDraft()
        rebuild()
        // The catalog is a fetched resource (`idfon://<peer>/idfon.json`); the
        // rows refill once it lands. On-device agents advertise none.
        if agent == nil {
            Task { @MainActor in
                catalog = await VoiceCatalog.options(for: peer.id, client: client)
                rebuild()
            }
        }
    }

    // MARK: - Modes

    private func setEditingSettings(_ on: Bool) {
        settingsEditing = on
        if on {
            loadDraft()
            nameField.text = draft.name
        }
        rebuild()
    }

    @objc private func beginEditing() { setEditingSettings(true) }

    @objc private func cancelEditing() {
        loadDraft()
        setEditingSettings(false)
    }

    /// Rebuilds the rows for the current mode. The controls are long-lived
    /// properties; only their arrangement changes.
    private func rebuild() {
        title = draft.name
        if settingsEditing {
            navigationItem.leftBarButtonItems = nil
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancelEditing))
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .save, target: self, action: #selector(save))
        } else {
            // The overflow menu rides with the back button, not instead of it.
            navigationItem.leftItemsSupplementBackButton = true
            navigationItem.leftBarButtonItem = agent == nil
                ? UIBarButtonItem(
                    image: UIImage(systemName: "ellipsis.circle"),
                    menu: UIMenu(children: [
                        UIAction(title: "Share Contact Card",
                                 image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                            guard let self else { return }
                            ContactExchange.shareCard(ref: self.peer.id, from: self, sourceView: self.view)
                        },
                        UIAction(title: "Save to Contacts",
                                 image: UIImage(systemName: "person.crop.circle.badge.plus")) { [weak self] _ in
                            self?.saveToSystemContacts()
                        },
                    ]))
                : nil
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Edit", style: .plain, target: self, action: #selector(beginEditing))
        }

        rebuildRows()
    }

    private func rebuildRows() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var rows: [UIView] = []
        if settingsEditing {
            nameField.text = draft.name
            rows += [sectionLabel("Name"), nameField]
            if agent == nil {
                rebuildKind()
                rows += [labeledRow("Kind", kindButton)]
                instantSwitch.isOn = draft.instant
                rows += [labeledRow("Instant Call", instantSwitch, alignment: .center)]
                voiceSwitch.isOn = draft.voiceEnabled
                rows += [labeledRow("Voice Calls", voiceSwitch, alignment: .center)]
            }
        } else {
            callButton.isHidden = agent == nil && !ContactCallProfiles.isCallable(peer.id)
            rows += [
                horizontalRow([callButton, messageButton], spacing: 12),
                artifactsButton,
                valueRow("Name", draft.name),
                valueRow("Kind", agent != nil ? "Agent" : (draft.kind == .agent ? "Agent" : "Human")),
            ]
            if agent == nil {
                rows += [
                    valueRow("Instant Call", draft.instant ? "On" : "Off"),
                    valueRow("Voice Calls", draft.voiceEnabled ? "On" : "Off"),
                ]
            }
        }

        rows += [sectionLabel("Endpoint"), endpointLabel()]

        rebuildSpeech()
        rows += [
            sectionLabel("Speech"),
            labeledRow("Recognition", settingsEditing ? recognitionButton : valueLabel(speechTitle(.recognition))),
            labeledRow("Generation", settingsEditing ? generationButton : valueLabel(speechTitle(.generation))),
        ]

        rebuildTurns()
        rows += [sectionLabel("Voice turns")]
        if agent == nil {
            rows += [labeledRow("Mode", settingsEditing ? turnModeButton : valueLabel(draft.turnMode.title))]
            if settingsEditing { rows += [turnModeCaption] }
        }
        rows += [labeledRow("Turn model", settingsEditing ? turnModelButton : valueLabel(draft.turnModel.title))]
        if settingsEditing { rows += [turnModelCaption] }

        if !settingsEditing && canEditAgent {
            let editAgent = UIButton(type: .system)
            editAgent.setTitle("Edit Agent", for: .normal)
            editAgent.setImage(UIImage(systemName: "chevron.right"), for: .normal)
            editAgent.contentHorizontalAlignment = .leading
            editAgent.addTarget(self, action: #selector(openAgentEditor), for: .touchUpInside)
            rows += [sectionLabel("Agent"), editAgent]
        }

        if settingsEditing && (agent == nil || agent?.id != OnDeviceAgents.builtInId) {
            let delete = UIButton(type: .system)
            delete.setTitle(agent == nil ? "Delete Contact" : "Delete Agent", for: .normal)
            delete.setTitleColor(.systemRed, for: .normal)
            delete.contentHorizontalAlignment = .leading
            delete.addTarget(self, action: #selector(confirmDelete), for: .touchUpInside)
            rows += [delete]
        }
        rows.forEach(stack.addArrangedSubview)
    }

    private func endpointLabel() -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        if let agent {
            label.text = "On-device"
            label.font = .preferredFont(forTextStyle: .body)
        } else {
            label.text = peer.endpointId ?? peer.id
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabel
        }
        return label
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

    /// The agent editor (`docs/voice-agent-modes.md`: contact ≠ agent) — the
    /// agent's own content. Its Save renames the agent, so the screen follows.
    @objc private func openAgentEditor() {
        guard let agent else { return }
        let editor = OnDeviceAgentEditorViewController(agent: agent) { [weak self] in
            guard let self else { return }
            self.agent = OnDeviceAgents.shared.agent(id: agent.id)
            self.loadDraft()
            self.rebuild()
            self.onChanged?()
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    // MARK: - Draft

    private func loadDraft() {
        draft = Draft()
        draft.name = agent?.name ?? peer.name ?? peer.displayName
        let profile = ContactCallProfiles.profile(for: peerID)
        draft.kind = profile.kind
        draft.voiceEnabled = profile.voiceEnabled
        draft.instant = peer.instantCall
        draft.stt = ContactSpeech.stored(for: peerID, slot: .recognition)
        draft.tts = ContactSpeech.stored(for: peerID, slot: .generation)
        draft.turnMode = ContactVoiceTurnModes.mode(for: peerID)
        draft.turnModel = TurnTakerSetting.mode(for: peerID)
    }

    @objc private func pickChanged() {
        draft.instant = instantSwitch.isOn
        draft.voiceEnabled = voiceSwitch.isOn
    }

    // MARK: - Speech pickers

    /// On-device backends first, then the agent's catalog options (remote
    /// agents only). The picker always names a real engine — never "Automatic".
    private func choices(for slot: SpeechSlot) -> [SpeechChoice] {
        let onDevice: [SpeechChoice] = slot == .recognition
            ? AsrBackend.allCases.map { SpeechChoice(store: .onDevice, id: $0.rawValue, title: $0.title) }
            : TtsBackend.allCases.filter { $0.isBuilt }.map { SpeechChoice(store: .onDevice, id: $0.rawValue, title: $0.title) }
        guard agent == nil else { return onDevice }
        let kind: VoiceOption.Kind = slot == .recognition ? .stt : .tts
        let advertised = catalog
            .filter { $0.kind == kind || $0.fillsBothSlots }
            .map { SpeechChoice(store: .catalog, id: $0.id, title: $0.label) }
        return onDevice + advertised
    }

    private func effective(_ slot: SpeechSlot) -> SpeechChoice {
        let stored = slot == .recognition ? draft.stt : draft.tts
        if let stored { return stored }
        return SpeechChoice(
            store: .onDevice,
            id: slot == .recognition ? SpeechEngines.asrBackend.rawValue : SpeechEngines.backend.rawValue,
            title: "")
    }

    private func speechTitle(_ slot: SpeechSlot) -> String {
        let effective = effective(slot)
        return choices(for: slot).first { $0.store == effective.store && $0.id == effective.id }?.title
            ?? (slot == .recognition ? SpeechEngines.asrBackend.title : SpeechEngines.backend.title)
    }

    private func rebuildSpeech() {
        for slot in [SpeechSlot.recognition, .generation] {
            let effective = effective(slot)
            let button = slot == .recognition ? recognitionButton : generationButton
            button.setTitle(speechTitle(slot), for: .normal)
            button.menu = UIMenu(title: slot == .recognition ? "Recognition" : "Generation",
                                 children: choices(for: slot).map { choice in
                UIAction(title: choice.title,
                         state: effective.store == choice.store && effective.id == choice.id ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    if slot == .recognition {
                        // A full-duplex catalog option fills both halves.
                        if choice.store == .catalog,
                           self.catalog.first(where: { $0.id == choice.id })?.fillsBothSlots == true {
                            self.draft.stt = choice
                            self.draft.tts = choice
                        } else {
                            self.draft.stt = choice
                        }
                    } else {
                        if choice.store == .catalog,
                           self.catalog.first(where: { $0.id == choice.id })?.fillsBothSlots == true {
                            self.draft.stt = choice
                            self.draft.tts = choice
                        } else {
                            self.draft.tts = choice
                        }
                    }
                    self.rebuildSpeech()
                }
            })
        }
    }

    // MARK: - Voice turns

    private func rebuildTurns() {
        turnModeButton.setTitle(draft.turnMode.title, for: .normal)
        turnModeButton.menu = UIMenu(title: "Voice turns", children: VoiceTurnMode.allCases.map { option in
            UIAction(title: option.title,
                     subtitle: option == .proxy ? "On-device director in front" : "The agent answers",
                     state: option == draft.turnMode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.draft.turnMode = option
                self.rebuildTurns()
            }
        })
        turnModeCaption.text = Self.modeCaption(for: draft.turnMode)
        turnModelButton.setTitle(draft.turnModel.title, for: .normal)
        turnModelButton.menu = UIMenu(title: "Turn model", children: TurnTakerMode.allCases.map { option in
            UIAction(title: option.title,
                     subtitle: option.subtitle,
                     state: option == draft.turnModel ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.draft.turnModel = option
                self.rebuildTurns()
            }
        })
        turnModelCaption.text = draft.turnModel.caption
    }

    /// What the mode means for the call, in one line. Says what it costs, since
    /// proxy is the only per-contact setting that adds a model turn.
    private static func modeCaption(for mode: VoiceTurnMode) -> String {
        switch mode {
        case .passive:
            return "The agent hears your words and answers. Nothing runs in front of it."
        case .proxy:
            return "The on-device director hears the turn first and either answers or forwards it. Adds an on-device turn to every remote one."
        }
    }

    // MARK: - Save / delete

    /// One commit for everything edit mode staged. What the form shows is what
    /// persists: kind/voice become explicit overrides of the derived defaults.
    @objc private func save() {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return showError("Name cannot be empty.")
        }
        draft.name = name
        ContactSpeech.set(draft.stt, catalog: catalog, for: peerID, slot: .recognition)
        ContactSpeech.set(draft.tts, catalog: catalog, for: peerID, slot: .generation)
        ContactVoiceTurnModes.set(draft.turnMode, for: peerID)
        TurnTakerSetting.setOverride(draft.turnModel == .auto ? nil : draft.turnModel, for: peerID)
        Task {
            do {
                if var agent {
                    agent.name = name
                    OnDeviceAgents.shared.update(agent)
                    self.agent = agent
                } else {
                    ContactCallProfiles.set(kind: draft.kind, voice: draft.voiceEnabled, for: peerID)
                    try await client.renamePeer(ref: peer.id, name: name)
                    if draft.instant != peer.instantCall {
                        try await client.updatePeerFlags(
                            ref: peer.id, identity: peer.identity, instantCall: draft.instant)
                    }
                }
                await MainActor.run {
                    self.title = name
                    self.setEditingSettings(false)
                    self.onChanged?()
                }
            } catch {
                await MainActor.run { self.showError(error.localizedDescription) }
            }
        }
    }

    @objc private func confirmDelete() {
        let alert = UIAlertController(
            title: "Delete \(agent?.name ?? peer.displayName)?",
            message: agent == nil
                ? "This removes the contact on this device."
                : "This removes the agent and its contact on this device.",
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
                if let agent {
                    OnDeviceAgents.shared.remove(id: agent.id)
                } else {
                    try await client.removePeer(ref: peer.id, identity: peer.identity)
                    CapabilityTickets.remove(for: peer.id)
                }
                clearContactStores()
                await MainActor.run {
                    self.onChanged?()
                    self.navigationController?.popViewController(animated: true)
                }
            } catch {
                await MainActor.run { self.showError(error.localizedDescription) }
            }
        }
    }

    /// Every per-contact setting dies with the contact.
    private func clearContactStores() {
        ContactVoiceSelection.remove(for: peerID)
        ContactOnDeviceEngines.remove(for: peerID)
        ContactVoiceTurnModes.remove(for: peerID)
        ContactCallProfiles.remove(for: peerID)
        TurnTakerSetting.setOverride(nil, for: peerID)
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

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Couldn’t update contact", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Row chrome

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        return label
    }

    private func valueLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        return label
    }

    /// Title label + value/control on one row.
    private func labeledRow(
        _ title: String, _ value: UIView,
        alignment: UIStackView.Alignment = .firstBaseline
    ) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, value])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = alignment
        return row
    }

    private func valueRow(_ title: String, _ value: String) -> UIStackView {
        labeledRow(title, valueLabel(value))
    }

    private func horizontalRow(_ views: [UIView], spacing: CGFloat) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.spacing = spacing
        row.distribution = .fillEqually
        return row
    }

    private func rebuildKind() {
        kindButton.setTitle(draft.kind == .agent ? "Agent" : "Human", for: .normal)
        kindButton.menu = UIMenu(title: "Kind", children: ContactCallProfile.Kind.allCases.map { option in
            UIAction(title: option == .agent ? "Agent" : "Human",
                     state: option == draft.kind ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.draft.kind = option
                self.rebuildKind()
            }
        })
    }
}
