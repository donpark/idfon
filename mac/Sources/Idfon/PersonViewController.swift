import AppKit

/// Person screen (§6; mac adaptation `docs/ios-ui-design.md` §13): ONE contact
/// screen for every contact — humans, agent-backed peers, on-device agents —
/// as a real detail surface in the right pane, never a popover or a sheet.
/// Twin of `ios/Idfon/ContactDetailViewController.swift`.
///
/// It edits the contact, not the agent (`docs/voice-agent-modes.md`): the
/// settings here (speech engines, voice turns, name) are per-contact
/// parameters passed to the contact's agent at call time. The agent's own
/// content lives in the agent editor, entered from the `Edit Agent` row for
/// agents the user has editor write to (user-created agents only).
///
/// View mode shows the actions plus read-only rows; edit mode turns every
/// setting into a control and commits on Save — one save path, Cancel
/// discards.
final class PersonViewController: NSViewController {
    private let peer: Peer
    private let app: AppModel
    private let client = DaemonClient()
    private var agent: OnDeviceAgent?
    private var voiceCatalog: [VoiceOption] = []

    /// Message / Back: the detail pane shows the chat again.
    var onOpenChat: (() -> Void)?
    /// Call: the detail pane shows the chat and dials.
    var onCall: (() -> Void)?
    /// Save/delete landed: refresh the sidebar and titles.
    var onChanged: (() -> Void)?

    // MARK: Staged settings (edit mode)

    private struct Draft {
        var name = ""
        var stt: SpeechChoice?
        var tts: SpeechChoice?
        var turnMode: VoiceTurnMode = .passive
        var turnModel: TurnTakerMode = .auto
    }

    private var draft = Draft()
    private var settingsEditing = false

    // MARK: Controls (reused across mode switches)

    private let titleLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let nameField = NSTextField()
    private let recognitionPopup = NSPopUpButton()
    private let generationPopup = NSPopUpButton()
    private let turnModePopup = NSPopUpButton()
    private let turnModelPopup = NSPopUpButton()
    private let turnModeCaption = NSTextField(wrappingLabelWithString: "")
    private let turnModelCaption = NSTextField(wrappingLabelWithString: "")
    private let bodyStack = NSStackView()

    // MARK: Identity

    private var peerID: String { agent?.peerId ?? peer.id }
    /// Editor write: agents the user created. The built-in AFM 3's agent
    /// content is not user-editable.
    private var canEditAgent: Bool {
        guard let agent else { return false }
        return agent.id != OnDeviceAgents.builtInId
    }

    init(peer: Peer, app: AppModel) {
        self.peer = peer
        self.app = app
        self.agent = OnDeviceAgents.shared.agent(forPeerId: peer.id)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let backButton = NSButton(title: "Chat", target: self, action: #selector(backTapped))
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back to chat")
        backButton.imagePosition = .imageLeading
        titleLabel.font = NSFont.boldSystemFont(ofSize: 15)
        editButton.target = self
        editButton.action = #selector(beginEditing)
        cancelButton.target = self
        cancelButton.action = #selector(cancelEditing)
        saveButton.target = self
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save)

        nameField.font = NSFont.systemFont(ofSize: 13)
        nameField.placeholderString = "Name"
        for popup in [recognitionPopup, generationPopup, turnModePopup, turnModelPopup] {
            popup.target = self
            popup.font = NSFont.systemFont(ofSize: 13)
        }
        recognitionPopup.action = #selector(speechChanged(_:))
        recognitionPopup.identifier = NSUserInterfaceItemIdentifier("recognition")
        generationPopup.action = #selector(speechChanged(_:))
        generationPopup.identifier = NSUserInterfaceItemIdentifier("generation")
        turnModePopup.action = #selector(turnModeChanged(_:))
        turnModelPopup.action = #selector(turnModelChanged(_:))
        for caption in [turnModeCaption, turnModelCaption] {
            caption.font = NSFont.systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
        }

        let rightControls = NSStackView(views: [cancelButton, saveButton, editButton])
        rightControls.orientation = .horizontal
        rightControls.spacing = 8
        let topBar = NSStackView(views: [backButton, titleLabel])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        topBar.setViews([rightControls], in: .trailing)

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 8
        bodyStack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 20, right: 12)
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(bodyStack)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            bodyStack.topAnchor.constraint(equalTo: document.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        loadDraft()
        rebuild()
        // The catalog is a fetched resource (`idfon://<peer>/idfon.json`); the
        // rows refill once it lands. On-device agents advertise none.
        if agent == nil {
            Task { @MainActor in
                voiceCatalog = await VoiceCatalog.options(for: peer.id, client: client)
                rebuild()
            }
        }
    }

    // MARK: - Modes

    @objc private func backTapped() { onOpenChat?() }

    @objc private func beginEditing() { setEditing(true) }

    @objc private func cancelEditing() {
        loadDraft()
        setEditing(false)
    }

    private func setEditing(_ on: Bool) {
        settingsEditing = on
        if on {
            loadDraft()
            nameField.stringValue = draft.name
        }
        rebuild()
    }

    private func rebuild() {
        titleLabel.stringValue = draft.name
        editButton.isHidden = settingsEditing
        cancelButton.isHidden = !settingsEditing
        saveButton.isHidden = !settingsEditing

        for row in bodyStack.arrangedSubviews {
            bodyStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        var rows: [NSView] = []
        if settingsEditing {
            nameField.stringValue = draft.name
            rows += [controlRow("Name", nameField)]
        } else {
            let call = NSButton(title: "Call", target: self, action: #selector(callTapped))
            call.image = NSImage(systemSymbolName: "phone", accessibilityDescription: "Call")
            call.imagePosition = .imageLeading
            let message = NSButton(title: "Message", target: self, action: #selector(backTapped))
            message.image = NSImage(systemSymbolName: "message", accessibilityDescription: "Message")
            message.imagePosition = .imageLeading
            let actions = NSStackView(views: [call, message])
            actions.orientation = .horizontal
            actions.spacing = 8
            rows += [actions, valueRow("Name", draft.name)]
        }

        let endpoint = NSTextField(wrappingLabelWithString: agent == nil ? (peer.endpointId ?? peer.id) : "On-device")
        if agent == nil {
            endpoint.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            endpoint.textColor = .secondaryLabelColor
        }
        endpoint.maximumNumberOfLines = 0
        let copy = NSButton(title: "Copy Endpoint ID", target: self, action: #selector(copyEndpointTapped))
        rows += [valueRow("Endpoint", endpoint)]
        if agent == nil { rows += [copy] }

        rebuildSpeech()
        rows += [
            sectionLabel("Speech"),
            settingsEditing
                ? controlRow("Recognition", recognitionPopup)
                : valueRow("Recognition", speechTitle(.recognition)),
            settingsEditing
                ? controlRow("Generation", generationPopup)
                : valueRow("Generation", speechTitle(.generation)),
        ]

        rebuildTurns()
        rows += [sectionLabel("Voice turns")]
        if agent == nil {
            rows += [settingsEditing
                ? controlRow("Mode", turnModePopup)
                : valueRow("Mode", draft.turnMode.title)]
            if settingsEditing { rows += [turnModeCaption] }
        }
        rows += [settingsEditing
            ? controlRow("Turn model", turnModelPopup)
            : valueRow("Turn model", draft.turnModel.title)]
        if settingsEditing { rows += [turnModelCaption] }

        if !settingsEditing && canEditAgent {
            let editAgent = NSButton(title: "Edit Agent", target: self, action: #selector(openAgentEditor))
            editAgent.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            editAgent.imagePosition = .imageTrailing
            rows += [sectionLabel("Agent"), editAgent]
        }

        if settingsEditing && (agent == nil || agent?.id != OnDeviceAgents.builtInId) {
            let delete = NSButton(
                title: agent == nil ? "Delete Contact" : "Delete Agent",
                target: self, action: #selector(confirmDelete))
            delete.contentTintColor = .systemRed
            rows += [delete]
        }
        rows.forEach(bodyStack.addArrangedSubview)
    }

    // MARK: - Actions

    @objc private func callTapped() { onCall?() }

    @objc private func copyEndpointTapped() {
        guard agent == nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(peer.endpointId ?? peer.id, forType: .string)
    }

    /// The agent editor (`docs/voice-agent-modes.md`: contact ≠ agent) — the
    /// agent's own content. A sheet today; the likely end state is an ACP
    /// window with a coding agent (fx `acp`, pi-pocket).
    @objc private func openAgentEditor() {
        guard let agent else { return }
        OnDeviceAgentEditor.present(agent: agent, in: view.window) { [weak self] in
            guard let self else { return }
            self.agent = OnDeviceAgents.shared.agent(id: agent.id)
            self.loadDraft()
            self.rebuild()
            self.onChanged?()
        }
    }

    // MARK: - Draft

    private func loadDraft() {
        draft = Draft()
        draft.name = agent?.name ?? peer.name ?? peer.displayName
        draft.stt = ContactSpeech.stored(for: peerID, slot: .recognition)
        draft.tts = ContactSpeech.stored(for: peerID, slot: .generation)
        draft.turnMode = ContactVoiceTurnModes.mode(for: peerID)
        draft.turnModel = TurnTakerSetting.mode(for: peerID)
    }

    // MARK: - Speech pickers

    /// On-device backends first, then the agent's catalog options (remote
    /// agents only). The picker always names a real engine — never "Automatic".
    private func choices(for slot: SpeechSlot) -> [SpeechChoice] {
        let onDevice: [SpeechChoice] = slot == .recognition
            ? AsrBackend.allCases.map { SpeechChoice(store: .onDevice, id: $0.rawValue, title: $0.title) }
            : TtsBackend.allCases.map { SpeechChoice(store: .onDevice, id: $0.rawValue, title: $0.title) }
        guard agent == nil else { return onDevice }
        let kind: VoiceOption.Kind = slot == .recognition ? .stt : .tts
        let advertised = voiceCatalog
            .filter { $0.kind == kind || $0.fillsBothSlots }
            .map { SpeechChoice(store: .catalog, id: $0.id, title: $0.label) }
        return onDevice + advertised
    }

    private func effective(_ slot: SpeechSlot) -> SpeechChoice {
        let stored = slot == .recognition ? draft.stt : draft.tts
        if let stored { return stored }
        return SpeechChoice(
            store: .onDevice,
            id: slot == .recognition ? SpeechEngines.asrBackend.rawValue : SpeechEngines.ttsBackend.rawValue,
            title: "")
    }

    private func speechTitle(_ slot: SpeechSlot) -> String {
        let effective = effective(slot)
        return choices(for: slot).first { $0.store == effective.store && $0.id == effective.id }?.title
            ?? (slot == .recognition ? SpeechEngines.asrBackend.title : SpeechEngines.ttsBackend.title)
    }

    private func rebuildSpeech() {
        for slot in [SpeechSlot.recognition, .generation] {
            let effective = effective(slot)
            let popup = slot == .recognition ? recognitionPopup : generationPopup
            popup.removeAllItems()
            var selectedIndex = 0
            for (index, choice) in choices(for: slot).enumerated() {
                popup.addItem(withTitle: choice.title)
                popup.lastItem?.representedObject = choice
                if effective.store == choice.store && effective.id == choice.id { selectedIndex = index }
            }
            popup.selectItem(at: selectedIndex)
        }
    }

    @objc private func speechChanged(_ sender: NSPopUpButton) {
        guard let choice = sender.selectedItem?.representedObject as? SpeechChoice,
              let slot: SpeechSlot = sender.identifier?.rawValue == "recognition" ? .recognition : .generation
        else { return }
        if choice.store == .catalog,
           voiceCatalog.first(where: { $0.id == choice.id })?.fillsBothSlots == true {
            // A full-duplex catalog option fills both halves.
            draft.stt = choice
            draft.tts = choice
        } else if slot == .recognition {
            draft.stt = choice
        } else {
            draft.tts = choice
        }
        rebuildSpeech()
    }

    // MARK: - Voice turns

    private func rebuildTurns() {
        turnModePopup.removeAllItems()
        turnModePopup.addItems(withTitles: VoiceTurnMode.allCases.map(\.title))
        turnModePopup.selectItem(at: VoiceTurnMode.allCases.firstIndex(of: draft.turnMode) ?? 0)
        turnModeCaption.stringValue = Self.modeCaption(for: draft.turnMode)
        turnModelPopup.removeAllItems()
        turnModelPopup.addItems(withTitles: TurnTakerMode.allCases.map(\.title))
        turnModelPopup.selectItem(at: TurnTakerMode.allCases.firstIndex(of: draft.turnModel) ?? 0)
        turnModelCaption.stringValue = draft.turnModel.caption
    }

    @objc private func turnModeChanged(_ sender: NSPopUpButton) {
        let modes = VoiceTurnMode.allCases
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < modes.count else { return }
        draft.turnMode = modes[sender.indexOfSelectedItem]
        turnModeCaption.stringValue = Self.modeCaption(for: draft.turnMode)
    }

    @objc private func turnModelChanged(_ sender: NSPopUpButton) {
        let modes = TurnTakerMode.allCases
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < modes.count else { return }
        draft.turnModel = modes[sender.indexOfSelectedItem]
        turnModelCaption.stringValue = draft.turnModel.caption
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

    /// One commit for everything edit mode staged.
    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return showError("Name cannot be empty.")
        }
        draft.name = name
        ContactSpeech.set(draft.stt, catalog: voiceCatalog, for: peerID, slot: .recognition)
        ContactSpeech.set(draft.tts, catalog: voiceCatalog, for: peerID, slot: .generation)
        ContactVoiceTurnModes.set(draft.turnMode, for: peerID)
        TurnTakerSetting.setOverride(draft.turnModel == .auto ? nil : draft.turnModel, for: peerID)
        Task { @MainActor in
            do {
                if var agent {
                    agent.name = name
                    OnDeviceAgents.shared.update(agent)
                    self.agent = agent
                } else {
                    try await self.client.renamePeer(ref: self.peer.id, name: name)
                }
                self.titleLabel.stringValue = name
                self.setEditing(false)
                self.onChanged?()
            } catch {
                self.showError(error.localizedDescription)
            }
        }
    }

    @objc private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete \(agent?.name ?? peer.displayName)?"
        alert.informativeText = agent == nil
            ? "This removes the contact on this device."
            : "This removes the agent and its contact on this device."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        delete()
    }

    private func delete() {
        Task { @MainActor in
            do {
                if let agent {
                    OnDeviceAgents.shared.remove(id: agent.id)
                } else {
                    try await client.removePeer(ref: peer.id)
                    CapabilityTickets.remove(for: peer.id)
                }
                clearContactStores()
                onChanged?()
                app.select(nil as Peer?)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    /// Every per-contact setting dies with the contact.
    private func clearContactStores() {
        ContactVoiceSelection.remove(for: peerID)
        ContactOnDeviceEngines.remove(for: peerID)
        ContactVoiceTurnModes.remove(for: peerID)
        TurnTakerSetting.setOverride(nil, for: peerID)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t update contact"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Row chrome

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Title label + value/control on one row.
    private func row(_ title: String, _ value: NSView, center: Bool) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let row = NSStackView(views: [label, value])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = center ? .centerY : .firstBaseline
        return row
    }

    private func valueRow(_ title: String, _ text: String) -> NSStackView {
        valueRow(title, NSTextField(wrappingLabelWithString: text))
    }

    private func valueRow(_ title: String, _ value: NSTextField) -> NSStackView {
        value.font = NSFont.systemFont(ofSize: 13)
        value.maximumNumberOfLines = 0
        value.lineBreakMode = .byWordWrapping
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row(title, value, center: false)
    }

    private func controlRow(_ title: String, _ control: NSView) -> NSStackView {
        row(title, control, center: true)
    }
}
