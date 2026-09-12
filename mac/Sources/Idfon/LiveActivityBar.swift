import AppKit

/// Display model for one contact's Live Activity Bar (docs/ui-design-notes.md
/// §3 states, §4 tray, §6 densities). Pure value: the host maps call/transfer
/// state into it and re-renders on every change.
///
/// Same shape as `ios/Idfon/LiveActivityBar.swift`, with two mac differences:
/// `.watching` (the one-way video share, which publishes nothing so it has no
/// stream toggles), and no idle Ping chrome — the chat header owns idle actions.
struct LiveActivityBarModel: Equatable {
    enum Phase: Equatable { case idle, calling, incoming, inCall, watching }
    enum Density: Equatable { case expanded, compact }

    /// One Session Tray row (§4).
    struct Row: Equatable {
        enum Kind: Equatable {
            case transfer(fraction: Double, bytesPerSecond: Double)
            case stream(position: TimeInterval, duration: TimeInterval, paused: Bool)
        }
        let id: String
        var name: String
        var kind: Kind
    }

    let peerId: String
    var handle: String
    var phase: Phase = .idle
    var micOn = false
    var camOn = false
    /// What the session carries (§3 State 3): a toggle for an absent track is
    /// hidden rather than shown as if it worked. Watch-only sessions publish
    /// nothing, so both are false there.
    var audioAvailable = true
    var videoAvailable = true
    var elapsed: TimeInterval = 0
    var rows: [Row] = []
    var density: Density = .expanded

    /// Compact pill text, e.g. `03:42 @janedoe — 1 transfer`.
    var compactText: String {
        var parts: [String] = []
        switch phase {
        case .inCall: parts.append(LiveActivityBar.clock(elapsed))
        case .calling: parts.append("Calling…")
        case .incoming: parts.append("Incoming")
        case .watching: parts.append("Watching")
        case .idle: break
        }
        parts.append(handle)
        let transfers = rows.filter { if case .transfer = $0.kind { return true } else { return false } }.count
        let streams = rows.count - transfers
        var activity: [String] = []
        if transfers > 0 { activity.append("\(transfers) transfer\(transfers == 1 ? "" : "s")") }
        if streams > 0 { activity.append("\(streams) stream\(streams == 1 ? "" : "s")") }
        if !activity.isEmpty { parts.append("— " + activity.joined(separator: ", ")) }
        return parts.joined(separator: " ")
    }
}

enum LiveActivityBarIntent: Equatable {
    case toggleMic, toggleCam, ping, end, answer, decline
    case cancelRow(String), togglePauseRow(String)
    /// Compact pill clicked: reveal the owning thread.
    case open
}

/// The Bar surface (AppKit port of the iOS view). Renders both §6 densities
/// from one model; emits intents and owns no call/daemon state.
final class LiveActivityBar: NSView {
    var onIntent: ((LiveActivityBarIntent) -> Void)?

    private var model = LiveActivityBarModel(peerId: "", handle: "")

    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let micButton = NSButton()
    private let camButton = NSButton()
    private let declineButton = NSButton()
    private let answerButton = NSButton()
    private let verbButton = NSButton()
    private let separator = NSBox()
    private let trayStack = NSStackView()
    private var rootStack: NSStackView!

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `m:ss`, or `h:mm:ss` past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - Layout

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        for label in [titleLabel, statusLabel] {
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
        }
        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [titleLabel, statusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 0

        configure(micButton, symbol: "mic.slash.fill", id: "mic", label: "Microphone", action: #selector(micTapped))
        configure(camButton, symbol: "video.slash.fill", id: "cam", label: "Camera", action: #selector(camTapped))
        configure(declineButton, symbol: "phone.down.fill", id: "decline", label: "Decline", action: #selector(declineTapped))
        configure(answerButton, symbol: "phone.fill", id: "answer", label: "Answer", action: #selector(answerTapped))
        configure(verbButton, symbol: "bell", id: "verb", label: "Ping", action: #selector(verbTapped))
        verbButton.wantsLayer = true
        verbButton.layer?.cornerRadius = 6
        declineButton.contentTintColor = .systemRed
        answerButton.contentTintColor = .systemGreen

        let header = NSStackView(views: [dot, titleStack, micButton, camButton, declineButton, answerButton, verbButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        separator.boxType = .separator

        trayStack.orientation = .vertical
        trayStack.alignment = .leading
        trayStack.spacing = 0

        rootStack = NSStackView(views: [header, separator, trayStack])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 6
        rootStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        apply(model)
    }

    private func configure(_ button: NSButton, symbol: String, id: String, label: String, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Render

    func apply(_ model: LiveActivityBarModel) {
        let previous = self.model
        self.model = model
        let compact = model.density == .compact

        switch model.phase {
        case .inCall: dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        case .calling, .incoming: dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        case .watching: dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        case .idle: dot.layer?.backgroundColor = NSColor.systemGray.cgColor
        }
        dot.isHidden = compact

        if compact {
            titleLabel.stringValue = model.compactText
            statusLabel.isHidden = true
        } else {
            titleLabel.stringValue = model.handle
            switch model.phase {
            case .idle: statusLabel.stringValue = ""
            case .calling: statusLabel.stringValue = "Calling…"
            case .incoming: statusLabel.stringValue = "Incoming call"
            case .inCall: statusLabel.stringValue = Self.clock(model.elapsed)
            case .watching: statusLabel.stringValue = "Watching video"
            }
            statusLabel.isHidden = statusLabel.stringValue.isEmpty
        }

        // Stream toggles exist only once a call does: idle has nothing to stage
        // and the ringing Bar has nothing to answer with (§3 State 3).
        let togglesActive = model.phase == .calling || model.phase == .inCall
        micButton.isHidden = compact || !togglesActive || !model.audioAvailable
        camButton.isHidden = compact || !togglesActive || !model.videoAvailable
        micButton.image = NSImage(systemSymbolName: model.micOn ? "mic.fill" : "mic.slash.fill", accessibilityDescription: "Microphone")
        camButton.image = NSImage(systemSymbolName: model.camOn ? "video.fill" : "video.slash.fill", accessibilityDescription: "Camera")
        micButton.contentTintColor = model.micOn ? .controlAccentColor : .secondaryLabelColor
        camButton.contentTintColor = model.camOn ? .controlAccentColor : .secondaryLabelColor
        micButton.setAccessibilityValue(model.micOn ? "on" : "off")
        camButton.setAccessibilityValue(model.camOn ? "on" : "off")

        let incoming = model.phase == .incoming
        declineButton.isHidden = !incoming
        answerButton.isHidden = !incoming
        verbButton.isHidden = incoming || compact
        switch model.phase {
        case .idle:
            setVerb("bell", "Ping", .controlAccentColor)
        case .calling, .inCall:
            // Icon only: the label wrapped and broke the row.
            setVerb("phone.down.fill", "End", .systemRed)
        case .watching:
            setVerb("stop.fill", "Stop", .systemRed)
        case .incoming:
            break
        }

        separator.isHidden = compact || model.rows.isEmpty
        trayStack.isHidden = compact || model.rows.isEmpty
        if model.rows != previous.rows || trayStack.arrangedSubviews.count != model.rows.count {
            trayStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for row in model.rows {
                let view = TrayRowView()
                view.onIntent = { [weak self] in self?.onIntent?($0) }
                view.apply(row)
                trayStack.addArrangedSubview(view)
            }
        }
    }

    private func setVerb(_ symbol: String, _ label: String, _ color: NSColor) {
        verbButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        verbButton.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        verbButton.setAccessibilityLabel(label)
    }

    /// Identifiers of the buttons currently on screen — used by the check to
    /// assert per-state visibility without reaching into private views.
    func visibleActions() -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, !button.isHidden, let id = button.identifier?.rawValue {
                found.append(id)
            }
            view.subviews.forEach(walk)
        }
        walk(self)
        return found
    }

    // MARK: - Intents

    @objc private func micTapped() { onIntent?(.toggleMic) }
    @objc private func camTapped() { onIntent?(.toggleCam) }
    @objc private func declineTapped() { onIntent?(.decline) }
    @objc private func answerTapped() { onIntent?(.answer) }
    @objc private func verbTapped() {
        switch model.phase {
        case .idle: onIntent?(.ping)
        case .calling, .inCall, .watching: onIntent?(.end)
        case .incoming: break
        }
    }
}

/// One Session Tray row (§4): icon · text · [pause] · Cancel/Stop.
private final class TrayRowView: NSView {
    var onIntent: ((LiveActivityBarIntent) -> Void)?
    private var rowId = ""
    private let label = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let actionButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = NSFont.systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (button, action) in [(pauseButton, #selector(pauseTapped)), (actionButton, #selector(actionTapped))] {
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.target = self
            button.action = action
            button.imagePosition = .imageOnly
        }
        pauseButton.identifier = NSUserInterfaceItemIdentifier("rowPause")
        actionButton.identifier = NSUserInterfaceItemIdentifier("rowAction")
        pauseButton.setAccessibilityLabel("Pause")
        actionButton.setAccessibilityLabel("Cancel")

        let stack = NSStackView(views: [label, pauseButton, actionButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ row: LiveActivityBarModel.Row) {
        rowId = row.id
        switch row.kind {
        case .transfer(let fraction, let rate):
            let percent = Int((fraction * 100).rounded())
            let speed = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file)
            label.stringValue = "Transferring \"\(row.name)\" (\(percent)%) - \(speed)/s"
            pauseButton.isHidden = true
            actionButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")
        case .stream(let position, let duration, let paused):
            label.stringValue = "Streaming \"\(row.name)\" (\(LiveActivityBar.clock(position)) / \(LiveActivityBar.clock(duration)))"
            pauseButton.isHidden = false
            pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? "Play" : "Pause")
            actionButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop")
        }
        actionButton.contentTintColor = .systemRed
    }

    @objc private func pauseTapped() { onIntent?(.togglePauseRow(rowId)) }
    @objc private func actionTapped() { onIntent?(.cancelRow(rowId)) }
}
