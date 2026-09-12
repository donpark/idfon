import AppKit
import CIdfon

/// Left pane: daemon status, identity switching, the tabbed peer lists, and the
/// action buttons (add connection, create identity, capability ticket, audio
/// settings).
final class SidebarViewController: NSViewController {
    private let app: AppModel
    private let tabs: PeerTabsViewController
    private let statusLabel = NSTextField(labelWithString: "Connecting")
    private let identityPopup = NSPopUpButton()
    private var suppressPopupSync = false

    init(app: AppModel) {
        self.app = app
        self.tabs = PeerTabsViewController(
            peersProvider: { [weak app] in app?.peers ?? [] },
            recentPeerIds: { ChatStore.shared.recentPeerIds },
            onSelect: { [weak app] peer in app?.select(peer) })
        super.init(nibName: nil, bundle: nil)
        app.onUpdate = { [weak self] in self?.sync() }
        ChatStore.shared.addObserver(self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))

        // Header: identity picker + daemon status
        identityPopup.translatesAutoresizingMaskIntoConstraints = false
        identityPopup.target = self
        identityPopup.action = #selector(identityPicked)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Favorites / Recents / Contacts tabs, each with its own search field.
        addChild(tabs)
        tabs.view.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [
            button("Add Connection…", #selector(addConnectionTapped)),
            button("Create Identity…", #selector(createIdentityTapped)),
            button("Issue Receive Ticket…", #selector(issueTicketTapped)),
            button("Audio Settings…", #selector(audioSettingsTapped)),
        ])
        actions.orientation = .vertical
        actions.spacing = 4
        actions.alignment = .leading
        actions.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(identityPopup)
        view.addSubview(statusLabel)
        view.addSubview(tabs.view)
        view.addSubview(actions)
        NSLayoutConstraint.activate([
            identityPopup.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            identityPopup.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            identityPopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: identityPopup.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: identityPopup.leadingAnchor),
            // The tabbed lists stretch between the status line and the actions.
            tabs.view.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            tabs.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabs.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabs.view.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        refreshData()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    // MARK: - Data

    private func sync() {
        refreshData()
    }

    private func refreshData() {
        statusLabel.stringValue = app.statusText
        suppressPopupSync = true
        identityPopup.removeAllItems()
        for identity in app.identities {
            identityPopup.addItem(withTitle: identity.name)
        }
        if let active = app.identities.first(where: { $0.active }) {
            identityPopup.selectItem(withTitle: active.name)
        }
        suppressPopupSync = false
        tabs.refresh()
    }

    @objc private func identityPicked() {
        guard !suppressPopupSync, let name = identityPopup.titleOfSelectedItem else { return }
        Task { await app.useIdentity(name) }
    }

    // MARK: - Actions

    @objc private func addConnectionTapped() {
        let name = NSTextField(string: "")
        name.placeholderString = "Name"
        let ticketScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
        let ticket = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
        ticket.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        ticket.isRichText = false
        ticket.isEditable = true
        ticketScroll.documentView = ticket
        ticketScroll.hasVerticalScroller = true
        ticketScroll.borderType = .bezelBorder
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 170))
        name.frame = NSRect(x: 0, y: 140, width: 320, height: 24)
        accessory.addSubview(name)
        accessory.addSubview(ticketScroll)
        presentAlert(title: "Add Connection",
                     message: "Paste the peer's endpoint-addr ticket (the \"id\" field identifies the peer).",
                     accessory: accessory, okTitle: "Add") {
            Task {
                let error = await self.app.addConnection(name: name.stringValue, ticketJSON: ticket.string)
                if let error { await MainActor.run { self.plainSheet(title: "Add Connection Failed", message: error) } }
            }
        }
    }

    @objc private func createIdentityTapped() {
        let name = NSTextField(string: "")
        name.placeholderString = "Identity name"
        presentAlert(title: "Create Identity", message: "Creates the identity and switches to it.", accessory: name, okTitle: "Create") {
            let value = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }
            Task { await self.app.createIdentity(value) }
        }
    }

    @objc private func issueTicketTapped() {
        Task {
            guard let ticket = await app.issueCapabilityTicket() else { return }
            await MainActor.run {
                let field = NSTextField(wrappingLabelWithString: ticket)
                field.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
                field.isSelectable = true
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
                scroll.documentView = field
                scroll.hasVerticalScroller = true
                scroll.borderType = .bezelBorder
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ticket, forType: .string)
                self.plainSheet(title: "Receive Ticket (copied)",
                                message: "Paste this into the peer's capability-ticket field, or send it to them.",
                                accessory: scroll)
            }
        }
    }

    @objc private func audioSettingsTapped() {
        let settings = AudioSettingsViewController()
        if let window = view.window {
            let alert = NSAlert()
            alert.messageText = "Audio Settings"
            alert.informativeText = "Volume and Opus bitrate apply to the daemon's media pipeline."
            alert.accessoryView = settings.view
            alert.addButton(withTitle: "Apply")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { settings.apply() }
            }
        }
    }

    /// Simple informational sheet (no OK handler).
    private func plainSheet(title: String, message: String, accessory: NSView? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let accessory { alert.accessoryView = accessory }
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    /// NSAlert sheet with an OK handler; Cancel does nothing.
    private func presentAlert(title: String, message: String, accessory: NSView?, okTitle: String, okHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let accessory { alert.accessoryView = accessory }
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: "Cancel")
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { okHandler() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            okHandler()
        }
    }
}

/// Volume / bitrate / device-probe sheet (GUI's advanced audio panel).
final class AudioSettingsViewController: NSViewController {
    private let volumeLabel = NSTextField(labelWithString: "Output volume: 100%")
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let bitrate = NSTextField(string: "32")
    private let probeLabel = NSTextField(labelWithString: "")

    override func loadView() {
        slider.target = self
        slider.action = #selector(volumeMoved(_:))
        let bitrateRow = NSStackView(views: [NSTextField(labelWithString: "Audio bitrate (kbps, 8–510):"), bitrate])
        let probe = NSButton(title: "Probe microphone (1s)", target: self, action: #selector(probeTapped(_:)))
        probe.bezelStyle = .rounded
        probeLabel.font = NSFont.systemFont(ofSize: 10)
        probeLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [volumeLabel, slider, bitrateRow, probe, probeLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view = stack
    }

    @objc private func volumeMoved(_ sender: NSSlider) {
        volumeLabel.stringValue = "Output volume: \(Int(sender.doubleValue))%"
    }

    @objc private func probeTapped(_ sender: NSButton) {
        Task.detached(priority: .userInitiated) {
            let samples = media_audio_probe(1000)
            let inputs = media_audio_input_count()
            let outputs = media_audio_output_count()
            await MainActor.run {
                self.probeLabel.stringValue = "Inputs: \(inputs) · Outputs: \(outputs) · probe captured \(samples) samples"
            }
        }
    }

    func apply() {
        let volume = UInt8(max(0, min(100, slider.integerValue)))
        let kbps = Int(bitrate.stringValue) ?? 32
        Task.detached(priority: .userInitiated) {
            _ = media_audio_set_volume(volume)
            if (8...510).contains(kbps) {
                _ = media_audio_set_bitrate(UInt32(kbps) * 1000)
            }
            await MainActor.run { ChatStore.shared.onBanner?("Audio settings applied") }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Recents is derived from message history, so the lists re-read when the store
/// changes (newest-first ordering).
extension SidebarViewController: ChatStoreObserver {
    func chatStoreDidUpdate() {
        tabs.refresh()
    }
}