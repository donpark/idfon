import UIKit

/// Display model for one contact's Live Activity Bar (docs/ui-design-notes.md
/// §3 states, §4 tray, §6 densities). Pure value: the host maps call/transfer
/// state into it and re-renders on every change; the view holds no other state.
struct LiveActivityBarModel: Equatable {
    /// §3 phases. There is no staging phase: a call is started from the
    /// idle chrome's `Call` button and always begins mic-only, so idle has no
    /// stream toggles to derive a staging state from.
    /// `.incoming` is only ever set on the Bar path — when CallKit owns the
    /// ring the host never produces it (§6 "must not double-present").
    enum Phase: Equatable { case idle, calling, incoming, inCall }
    enum Density: Equatable { case expanded, compact }

    /// One Session Tray row (§4).
    struct Row: Equatable {
        enum Kind: Equatable {
            case transfer(fraction: Double, bytesPerSecond: Double)
            case stream(position: TimeInterval, duration: TimeInterval, paused: Bool)
        }
        let id: String
        var name: String // "Archive.zip"
        var kind: Kind
    }

    let peerId: String
    var handle: String // "@janedoe"
    var phase: Phase = .idle
    var micOn = false
    var camOn = false
    var speakerOn = false
    /// Stream set the session actually carries (§3 State 3): a call can only
    /// toggle the tracks it was started with, so a toggle for an absent track
    /// is hidden rather than shown as if it worked. Calls publish both, so
    /// both default true.
    var audioAvailable = true
    var videoAvailable = true
    var elapsed: TimeInterval = 0 // in-call timer; host advances and re-renders
    /// Subtle live readout for the active call, e.g. "Whistle 100 ms ·
    /// Kokoro 0.7 s". Voice (client-cascade) calls only; nil hides it.
    var stats: String?
    /// True for the client-cascade voice call: shows a subtle on-device
    /// provenance glyph that explains where the audio is processed.
    var onDevice = false
    /// The visible thread's own call carries its identity and controls in the
    /// nav bar, so the panel drops them and keeps only the call stats and the
    /// activity (tray) rows.
    var statusOnly = false
    var rows: [Row] = []
    var density: Density = .expanded

    /// Compact pill text, e.g. `03:42 @janedoe — 1 transfer` (dot is a view).
    var compactText: String {
        var parts: [String] = []
        switch phase {
        case .inCall: parts.append(LiveActivityBar.clock(elapsed))
        case .calling: parts.append("Calling…")
        case .incoming: parts.append("Incoming")
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
    case toggleMic, toggleCam, toggleSpeaker, end, answer, decline
    case cancelRow(String), togglePauseRow(String)
    /// Compact pill tapped: navigate to the owning thread.
    case open
}

/// The Live Activity Bar surface. Renders both §6 densities from one model;
/// emits intents, owns no call/daemon/store state.
///
/// Hierarchy:
///   rootStack (V)
///     headerStack (H; V at accessibility sizes)
///       identityStack (H): dot · textStack (V): titleLabel / statusLabel
///       controlsStack (H): mic · cam · decline · answer · verb
///     separator
///     trayStack (V): TrayRowView…
final class LiveActivityBar: UIView {
    var onIntent: ((LiveActivityBarIntent) -> Void)?
    private(set) var model = LiveActivityBarModel(peerId: "", handle: "")

    private let dot = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let micButton = UIButton(configuration: .tinted())
    private let camButton = UIButton(configuration: .tinted())
    private let speakerButton = UIButton(configuration: .tinted())
    private let declineButton = UIButton(configuration: .filled())
    private let answerButton = UIButton(configuration: .filled())
    private let verbButton = UIButton(configuration: .filled())
    private let onDeviceButton = UIButton(configuration: .plain())
    private let textStack = UIStackView()
    private let identityStack = UIStackView()
    private let controlsStack = UIStackView()
    private let headerStack = UIStackView()
    private let separator = UIView()
    private let trayStack = UIStackView()
    private let rootStack = UIStackView()
    private let openTap = UITapGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    // MARK: - Build

    private func build() {
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (bar: LiveActivityBar, _) in
            bar.applyAxis()
        }
        backgroundColor = .secondarySystemBackground
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        dot.layer.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .regular))
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel

        // Subtitle provenance: a small, ignorable lock that explains where the
        // voice is processed. Shown only on the on-device voice call.
        onDeviceButton.configuration?.image = UIImage(systemName: "lock.fill")
        onDeviceButton.configuration?.baseForegroundColor = .tertiaryLabel
        onDeviceButton.accessibilityLabel = "On-device voice"
        onDeviceButton.accessibilityHint = "Where your voice is processed"
        onDeviceButton.addTarget(self, action: #selector(onDeviceTapped), for: .touchUpInside)
        onDeviceButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        onDeviceButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        // Handle over status: the two never compete for width, and
        // headline + subheadline (≈42pt) fits inside the 44pt controls row.
        textStack.axis = .vertical
        textStack.alignment = .leading
        [titleLabel, statusLabel].forEach(textStack.addArrangedSubview)

        identityStack.axis = .horizontal
        identityStack.spacing = 8
        identityStack.alignment = .center
        [dot, textStack, onDeviceButton].forEach(identityStack.addArrangedSubview)
        openTap.addTarget(self, action: #selector(openTapped))
        identityStack.addGestureRecognizer(openTap)

        func control(_ button: UIButton, _ symbol: String, _ label: String, _ action: Selector) {
            button.configuration?.image = UIImage(systemName: symbol)
            button.configuration?.cornerStyle = .capsule
            button.accessibilityLabel = label
            button.addTarget(self, action: action, for: .touchUpInside)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        control(micButton, "mic.slash.fill", "Microphone", #selector(micTapped))
        control(camButton, "video.slash.fill", "Camera", #selector(camTapped))
        control(speakerButton, "ear", "Phone earpiece", #selector(speakerTapped))
        control(declineButton, "phone.down.fill", "Decline", #selector(declineTapped))
        control(answerButton, "phone.fill", "Answer", #selector(answerTapped))
        control(verbButton, "phone.down.fill", "End", #selector(verbTapped))
        declineButton.configuration?.baseBackgroundColor = .systemRed
        answerButton.configuration?.baseBackgroundColor = .systemGreen
        controlsStack.axis = .horizontal
        controlsStack.spacing = 8
        controlsStack.alignment = .center
        [micButton, camButton, speakerButton, declineButton, answerButton, verbButton]
            .forEach(controlsStack.addArrangedSubview)

        headerStack.axis = .horizontal
        headerStack.spacing = 12
        headerStack.alignment = .center
        headerStack.isLayoutMarginsRelativeArrangement = true
        [identityStack, controlsStack].forEach(headerStack.addArrangedSubview)

        separator.backgroundColor = .separator
        separator.heightAnchor.constraint(equalToConstant: 1 / traitCollection.displayScale).isActive = true

        trayStack.axis = .vertical
        trayStack.spacing = 0

        rootStack.axis = .vertical
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        [headerStack, separator, trayStack].forEach(rootStack.addArrangedSubview)
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        apply(model)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = model.density == .compact ? bounds.height / 2 : 16
    }

    // MARK: - Render

    func apply(_ model: LiveActivityBarModel) {
        let previous = self.model
        self.model = model
        let compact = model.density == .compact
        let statusOnly = model.statusOnly && !compact

        // Identity
        switch model.phase {
        case .inCall: dot.backgroundColor = .systemRed
        case .calling, .incoming: dot.backgroundColor = .systemOrange
        case .idle: dot.backgroundColor = .systemGray
        }
        dot.isHidden = statusOnly || (model.phase == .idle && !compact)
        if compact {
            titleLabel.text = model.compactText
            statusLabel.isHidden = true
        } else {
            titleLabel.text = model.handle
            titleLabel.isHidden = statusOnly
            switch model.phase {
            case .idle: statusLabel.text = nil
            case .calling: statusLabel.text = "Calling…"
            case .incoming: statusLabel.text = "Incoming call"
            case .inCall:
                statusLabel.text = [Self.clock(model.elapsed), model.stats]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            }
            statusLabel.isHidden = statusLabel.text == nil
        }
        onDeviceButton.isHidden = compact || statusOnly || !model.onDevice
        headerStack.directionalLayoutMargins = compact
            ? NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 4)
            : NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8)
        openTap.isEnabled = compact
        titleLabel.accessibilityTraits = compact ? .button : .staticText

        // Controls. Stream toggles appear only once a call exists (calling /
        // inCall): an idle Bar has nothing to stage, and the ringing Bar has
        // nothing to answer with — calls always begin mic-only. A toggle for
        // an absent track is hidden too (compact hides both anyway).
        let togglesActive = model.phase == .calling || model.phase == .inCall
        controlsStack.isHidden = statusOnly
        micButton.isHidden = compact || !togglesActive || !model.audioAvailable
        camButton.isHidden = compact || !togglesActive || !model.videoAvailable
        speakerButton.isHidden = compact || model.phase != .inCall || !model.audioAvailable
        speakerButton.configuration?.image = UIImage(systemName: model.speakerOn ? "speaker.wave.2.fill" : "ear")
        speakerButton.configuration?.baseForegroundColor = model.speakerOn ? .tintColor : .secondaryLabel
        speakerButton.accessibilityLabel = model.speakerOn ? "Speakerphone" : "Phone earpiece"
        speakerButton.accessibilityValue = model.speakerOn ? "on" : "off"
        micButton.configuration?.image = UIImage(systemName: model.micOn ? "mic.fill" : "mic.slash.fill")
        camButton.configuration?.image = UIImage(systemName: model.camOn ? "video.fill" : "video.slash.fill")
        micButton.configuration?.baseForegroundColor = model.micOn ? .tintColor : .secondaryLabel
        camButton.configuration?.baseForegroundColor = model.camOn ? .tintColor : .secondaryLabel
        micButton.accessibilityValue = model.micOn ? "on" : "off"
        camButton.accessibilityValue = model.camOn ? "on" : "off"

        let incoming = model.phase == .incoming
        declineButton.isHidden = !incoming
        answerButton.isHidden = !incoming
        verbButton.isHidden = incoming
        switch model.phase {
        case .idle:
            verbButton.isHidden = true
        case .calling, .inCall, .incoming:
            // Icon only: the "End" label wrapped and broke the control row (#2).
            setVerb("phone.down.fill", "End", .systemRed, showsTitle: false)
        }
        // Idle pill (rows only, no call) has no verb: its rows are the activity.
        if compact && model.phase == .idle { verbButton.isHidden = true }

        // Tray
        trayStack.isHidden = compact || model.rows.isEmpty
        separator.isHidden = trayStack.isHidden
        if model.rows != previous.rows || trayStack.arrangedSubviews.count != model.rows.count {
            trayStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for row in model.rows {
                let view = TrayRowView()
                view.onIntent = { [weak self] in self?.onIntent?($0) }
                view.apply(row)
                trayStack.addArrangedSubview(view)
            }
        }
        applyAxis()
        setNeedsLayout()
    }

    private func setVerb(_ symbol: String, _ title: String, _ color: UIColor, showsTitle: Bool = true) {
        verbButton.configuration?.image = UIImage(systemName: symbol)
        let titled = showsTitle && model.density == .expanded
        verbButton.configuration?.title = titled ? title : nil
        verbButton.configuration?.imagePadding = titled ? 6 : 0
        verbButton.configuration?.baseBackgroundColor = color
        verbButton.accessibilityLabel = title
    }

    /// Accessibility text sizes: identity and controls stack vertically so
    /// four 44pt controls never truncate the handle.
    private func applyAxis() {
        let stacked = model.density == .expanded && traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        headerStack.axis = stacked ? .vertical : .horizontal
        headerStack.alignment = stacked ? .leading : .center
    }

    // MARK: - Intents

    @objc private func micTapped() { onIntent?(.toggleMic) }
    @objc private func camTapped() { onIntent?(.toggleCam) }
    @objc private func speakerTapped() { onIntent?(.toggleSpeaker) }
    @objc private func declineTapped() { onIntent?(.decline) }
    @objc private func answerTapped() { onIntent?(.answer) }
    @objc private func openTapped() { onIntent?(.open) }

    /// One-line provenance explainer, presented from the bar's own window so
    /// the caller needs no extra plumbing.
    @objc private func onDeviceTapped() {
        let host = window ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
        guard let host, var top = host.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let alert = UIAlertController(
            title: "On-device voice",
            message: "Transcribed and spoken on this iPhone. Your audio is never uploaded — it stays between you and your peer.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
    }
    @objc private func verbTapped() {
        switch model.phase {
        case .idle: break
        case .calling, .inCall: onIntent?(.end)
        case .incoming: break
        }
    }

    // MARK: - Formatting

    /// `m:ss`, or `h:mm:ss` past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// One Session Tray row (§4): icon · text · [pause] · Cancel/Stop.
private final class TrayRowView: UIView {
    var onIntent: ((LiveActivityBarIntent) -> Void)?
    private var rowId = ""
    private let icon = UIImageView()
    private let label = UILabel()
    private let pauseButton = UIButton(configuration: .plain())
    private let actionButton = UIButton(configuration: .plain())

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.preferredSymbolConfiguration = .init(textStyle: .footnote)
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        for button in [pauseButton, actionButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }

        let stack = UIStackView(arrangedSubviews: [icon, label, pauseButton, actionButton])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    func apply(_ row: LiveActivityBarModel.Row) {
        rowId = row.id
        switch row.kind {
        case .transfer(let fraction, let rate):
            icon.image = UIImage(systemName: "arrow.up.doc")
            let percent = Int((fraction * 100).rounded())
            let speed = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file)
            label.text = "Transferring \"\(row.name)\" (\(percent)%) - \(speed)/s"
            pauseButton.isHidden = true
            actionButton.configuration?.title = "Cancel"
        case .stream(let position, let duration, let paused):
            icon.image = UIImage(systemName: "waveform")
            label.text = "Streaming \"\(row.name)\" (\(LiveActivityBar.clock(position)) / \(LiveActivityBar.clock(duration)))"
            pauseButton.isHidden = false
            pauseButton.configuration?.image = UIImage(systemName: paused ? "play.fill" : "pause.fill")
            pauseButton.accessibilityLabel = paused ? "Play" : "Pause"
            actionButton.configuration?.title = "Stop"
        }
        actionButton.configuration?.baseForegroundColor = .systemRed
    }

    @objc private func pauseTapped() { onIntent?(.togglePauseRow(rowId)) }
    @objc private func actionTapped() { onIntent?(.cancelRow(rowId)) }
}
