import AppKit
import AVFoundation
import CIdfon

/// Chat detail (AppKit port of the GUI's chat window + the iOS
/// ChatViewController): message history, voice memos, live audio calls,
/// video calls, one-way video shares, in-call recording.
final class ChatViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, AVAudioPlayerDelegate {
    private let peer: Peer
    private let app: AppModel

    private let store = ChatStore.shared
    private let live = LiveCall.shared
    private let video = VideoCall.shared
    private let client = DaemonClient()

    // message table
    private let table = NSTableView()
    private var history: [ChatMessage] = []
    private var textHeights: [String: CGFloat] = [:]
    private var lastCount = 0

    // header
    private let callLabel = NSTextField(labelWithString: "")
    private var headerRow: NSStackView!

    // banner
    private let bannerBox = NSView()
    private let bannerLabel = NSTextField(labelWithString: "")
    private var bannerTimer: Timer?

    // video panel
    private var videoPanel: NSView?
    private let videoView = NSImageView()
    private let videoSpinner = NSProgressIndicator()

    // live call UI (hybrid: inline stage under the header, tap to expand)
    private var liveBar: NSStackView?
    private var liveWaveView: WaveformView?
    private var callMeter: AudioMeter?
    private var fullscreenOverlay: NSView?
    private let fullscreenVideoView = NSImageView()
    private var fullscreenWaveView: WaveformView?
    private var fullscreenStatusLabel: NSTextField?
    private var fullscreenControls: NSStackView?
    private var isLiveFullscreen = false

    // composer
    private var composerMode: Mode = .normal
    enum Mode {
        case normal
        case memoRecording
        case memoReview(url: URL)
        case callReview(durationMs: Int, ticket: String)
    }
    private var composerTextView: NSTextView?

    // memo state
    private var memo: VoiceMemo?
    private var memoURL: URL?
    private var memoDuration: TimeInterval = 0
    private var memoStartDate = Date()
    private var memoTimer: Timer?
    private var memoMeter: AudioMeter?
    private var reviewWave: WaveformView?
    private var reviewSamples: [Float] = []
    private var recordingElapsedLabel: NSTextField?

    // in-call recording state (daemon-side opus)
    private var callRecordingActive = false
    private var callRecordingWaveView: WaveformView?
    private var pendingCallRecording: (durationMs: Int, ticket: String)?

    // playback
    private var player: AVAudioPlayer?
    private var playingMessageId: String?
    private var progressTimer: Timer?
    private var staticWaves: [String: WaveformView] = [:]

    // composer
    private var composer: NSStackView!

    // popovers
    private var peerPopover: NSPopover?

    init(peer: Peer, app: AppModel) {
        self.peer = peer
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.spacing = 8
        headerRow.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        buildCallLabel()

        buildBanner()
        buildVideoPanel()
        buildLiveBar()
        buildMessageTable()

        composer = NSStackView()
        composer.orientation = .horizontal
        composer.spacing = 8
        composer.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        rebuildComposer()

        let outer = NSStackView(views: [headerRow, liveBar ?? NSView(), bannerBox, videoPanel ?? NSView(), tableScrollView, composer])
        outer.orientation = .vertical
        outer.spacing = 0
        outer.edgeInsets = NSEdgeInsets()
        // The message list absorbs all extra height; the fixed-height rows
        // (header/banner/video/composer) keep their own constraints.
        tableScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        headerRow.setContentCompressionResistancePriority(.required, for: .vertical)
        liveBar?.setContentCompressionResistancePriority(.required, for: .vertical)
        composer.setContentCompressionResistancePriority(.required, for: .vertical)
        // Container as the VC's view; the stack fills it.
        let container = NSView()
        container.addSubview(outer)
        outer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outer.topAnchor.constraint(equalTo: container.topAnchor),
            outer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        // Overlay rides above the chat stack; built AFTER view exists — it
        // must never touch self.view itself (lazy view would re-enter
        // loadView and recurse: buildFullscreenOverlay -> view -> loadView).
        buildFullscreenOverlay(container: container)
    }

    

    // MARK: - Header

    private func buildCallLabel() {
        callLabel.font = NSFont.systemFont(ofSize: 12)
        callLabel.textColor = .secondaryLabelColor
    }

    private func headerSymbolButton(_ symbol: String, _ action: Selector, _ desc: String) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        button.target = self
        button.action = action
        return button
    }

    private func headerButton(_ title: String, _ action: Selector, prominent: Bool = false, destructive: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if destructive { button.hasDestructiveAction = true }
        if prominent { button.bezelColor = .controlAccentColor; button.keyEquivalent = "\r" }
        return button
    }

    /// Rebuilds the header for the current call state (GUI's
    /// Answer/Decline/End-call swaps).
    private func refreshHeader() {
        var buttons: [NSButton] = []
        var status = ""
        switch live.state {
        case .incoming(let p) where p == peer.id:
            buttons = [headerButton("Answer", #selector(liveAnswerTapped), prominent: true),
                       headerButton("Decline", #selector(liveDeclineTapped))]
            status = "Incoming call"
        case .inCall(let p) where p == peer.id:
            buttons = [headerButton("End call", #selector(liveHangUpTapped), destructive: true),
                       headerButton(callRecordingActive ? "Stop rec" : "Record", #selector(callRecordTapped))]
            status = "In call"
        case .calling(let p) where p == peer.id:
            buttons = [headerButton("Cancel", #selector(liveHangUpTapped))]
            status = "Calling…"
        default:
            switch video.state {
            case .incoming where video.pendingPeer == peer.id:
                buttons = [headerButton(video.pendingWatchOnly ? "Watch" : "Answer video", #selector(videoAnswerTapped), prominent: true),
                           headerButton("Decline", #selector(videoDeclineTapped))]
                status = video.pendingWatchOnly ? "Incoming video" : "Incoming video call"
            case .inCall where video.activePeer == peer.id:
                buttons = [headerButton("End call", #selector(videoHangUpTapped), destructive: true),
                           headerButton(callRecordingActive ? "Stop rec" : "Record", #selector(callRecordTapped))]
                status = "In video call"
            case .watching where video.activePeer == peer.id:
                buttons = [headerButton("Stop watching", #selector(videoHangUpTapped), destructive: true)]
                status = "Watching video"
            case .calling where video.activePeer == peer.id:
                buttons = [headerButton("Cancel", #selector(videoHangUpTapped))]
                status = "Calling…"
            default:
                buttons = [headerSymbolButton("phone", #selector(liveCallTapped), "Start audio call"),
                           headerSymbolButton("video", #selector(videoCallTapped), "Start video call"),
                           headerSymbolButton("arrow.down.doc", #selector(shareVideoTapped), "Share a video file"),
                           headerSymbolButton("person.crop.circle", #selector(peerDetailsTapped), "Peer details")]
            }
        }
        callLabel.stringValue = status
        headerRow.arrangedSubviews.filter { $0 is NSButton }.forEach { headerRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        buttons.forEach { headerRow.insertView($0, at: 0, in: .leading) }
    }

    // MARK: - Banner

    private func buildBanner() {
        bannerBox.wantsLayer = true
        bannerBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        bannerBox.layer?.cornerRadius = 6
        bannerLabel.font = NSFont.systemFont(ofSize: 12)
        bannerBox.addSubview(bannerLabel)
        bannerBox.translatesAutoresizingMaskIntoConstraints = false
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bannerBox.heightAnchor.constraint(equalToConstant: 30),
            bannerLabel.leadingAnchor.constraint(equalTo: bannerBox.leadingAnchor, constant: 10),
            bannerLabel.trailingAnchor.constraint(lessThanOrEqualTo: bannerBox.trailingAnchor, constant: -10),
            bannerLabel.centerYAnchor.constraint(equalTo: bannerBox.centerYAnchor),
        ])
        bannerBox.isHidden = true
    }

    /// Markdown rendering for message/banner text; falls back to plain on parse failure.
    /// inline-only so block syntax and embedded images can't mangle chat bubbles.
    private func renderText(_ text: String, font: NSFont = NSFont.systemFont(ofSize: 13)) -> NSAttributedString {
        if let attr = try? NSAttributedString(
            markdown: Data(text.utf8),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            let full = NSMutableAttributedString(attributedString: attr)
            full.addAttribute(.font, value: font, range: NSRange(location: 0, length: full.length))
            return full
        }
        return NSAttributedString(string: text, attributes: [.font: font])
    }

    private func showBanner(_ text: String) {
        guard !text.isEmpty else { return }
        bannerLabel.attributedStringValue = renderText(text, font: NSFont.systemFont(ofSize: 12))
        bannerBox.isHidden = false
        bannerTimer?.invalidate()
        bannerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.bannerBox.isHidden = true }
        }
    }

    // MARK: - Video panel

    private func buildVideoPanel() {
        videoView.imageScaling = .scaleProportionallyUpOrDown
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoSpinner.isIndeterminate = true
        videoSpinner.style = .spinning
        videoSpinner.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(videoView)
        panel.addSubview(videoSpinner)
        // Inline video stage: tap anywhere (or the expand button) to go fullscreen.
        let expand = headerSymbolButton("arrow.up.left.and.arrow.down.right", #selector(liveExpandTapped), "Expand call")
        expand.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(expand)
        panel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(liveExpandTapped)))
        NSLayoutConstraint.activate([
            panel.heightAnchor.constraint(equalToConstant: 180),
            videoView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: panel.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            videoSpinner.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            videoSpinner.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            expand.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            expand.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
        ])
        videoPanel = panel
        panel.isHidden = true
    }

    private func updateVideoPanelVisibility() {
        updateLiveUI()
    }

    // MARK: - Live call stage (inline bar + fullscreen overlay)

    private func videoActive() -> Bool {
        (video.state == .inCall || video.state == .watching || video.state == .calling)
            && video.activePeer == peer.id
    }

    private func audioActive() -> Bool {
        live.state == .inCall(peer: peer.id) || live.state == .calling(peer: peer.id)
    }

    /// Single updater for the hybrid live stage: inline audio bar under the
    /// header, inline video panel, and the fullscreen overlay swap by state.
    private func updateLiveUI() {
        let active = videoActive() || audioActive()
        guard active else {
            isLiveFullscreen = false
            liveBar?.isHidden = true
            videoPanel?.isHidden = true
            fullscreenOverlay?.isHidden = true
            stopCallMeter()
            return
        }
        videoPanel?.isHidden = !(videoActive() && !isLiveFullscreen)
        if videoActive(), video.lastFrame == nil { videoSpinner.startAnimation(nil) }
        else { videoSpinner.stopAnimation(nil) }
        // Audio pill only when there is no video stage taking the inline slot.
        let showBar = audioActive() && !videoActive()
        liveBar?.isHidden = !showBar
        if showBar {
            _ = ensureCallMeter()
            if let wave = liveWaveView, wave.superview == nil {
                wave.translatesAutoresizingMaskIntoConstraints = false
                liveBar?.insertView(wave, at: 0, in: .leading)
                NSLayoutConstraint.activate([
                    wave.heightAnchor.constraint(equalToConstant: 22),
                    wave.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
                ])
            }
            liveStatusLabel()?.stringValue = live.state == .calling(peer: peer.id) ? "Calling…" : "In call"
        }
        rebuildFullscreenContent()
        fullscreenOverlay?.isHidden = !isLiveFullscreen
    }

    /// Shared mic meter for the live bar + in-call recording waveform.
    private func ensureCallMeter() -> AudioMeter {
        if let callMeter { return callMeter }
        let wave = liveWaveView ?? WaveformView(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
        wave.startLive()
        liveWaveView = wave
        let meter = AudioMeter(view: wave)
        if let fullscreenWaveView { meter.add(view: fullscreenWaveView) }
        meter.start()
        callMeter = meter
        return meter
    }

    private func stopCallMeter() {
        callMeter?.stop()
        callMeter = nil
        liveWaveView?.removeFromSuperview()
        liveWaveView = nil
    }

    private func buildLiveBar() {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.identifier = NSUserInterfaceItemIdentifier("liveStatus")
        let expand = headerSymbolButton("arrow.up.left.and.arrow.down.right", #selector(liveExpandTapped), "Expand call")
        bar.addArrangedSubview(status)
        bar.addArrangedSubview(expand)
        liveBar = bar
        bar.isHidden = true
    }

    private func liveStatusLabel() -> NSTextField? {
        liveBar?.arrangedSubviews.first(where: { $0.identifier?.rawValue == "liveStatus" }) as? NSTextField
    }

    private func buildFullscreenOverlay(container: NSView) {
        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        status.textColor = .white
        fullscreenStatusLabel = status
        let collapse = headerSymbolButton("chevron.down", #selector(liveCollapseTapped), "Back to chat")
        let top = NSStackView(views: [status, collapse])
        top.orientation = .horizontal
        top.spacing = 8

        fullscreenVideoView.imageScaling = .scaleProportionallyUpOrDown
        fullscreenVideoView.translatesAutoresizingMaskIntoConstraints = false
        let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: 400, height: 72))
        wave.translatesAutoresizingMaskIntoConstraints = false
        fullscreenWaveView = wave

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 8
        fullscreenControls = controls

        overlay.addSubview(top)
        overlay.addSubview(fullscreenVideoView)
        overlay.addSubview(wave)
        overlay.addSubview(controls)
        for sub in [top, fullscreenVideoView, wave, controls] {
            sub.translatesAutoresizingMaskIntoConstraints = false
        }
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            top.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
            top.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 12),
            fullscreenVideoView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            fullscreenVideoView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            fullscreenVideoView.topAnchor.constraint(equalTo: top.bottomAnchor),
            fullscreenVideoView.bottomAnchor.constraint(equalTo: controls.topAnchor),
            wave.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            wave.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            wave.widthAnchor.constraint(equalToConstant: 420),
            wave.heightAnchor.constraint(equalToConstant: 72),
            controls.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -20),
        ])
        fullscreenOverlay = overlay
    }

    /// Rebuilds the fullscreen stage contents for the current call state.
    private func rebuildFullscreenContent() {
        let showVideo = videoActive()
        fullscreenVideoView.isHidden = !showVideo
        fullscreenVideoView.image = showVideo ? videoView.image : nil
        fullscreenWaveView?.isHidden = showVideo
        var buttons: [NSButton] = []
        var title = ""
        if audioActive() {
            switch live.state {
            case .inCall:
                title = "In call"
                buttons = [headerButton("End call", #selector(liveHangUpTapped), destructive: true),
                           headerButton(callRecordingActive ? "Stop rec" : "Record", #selector(callRecordTapped))]
            case .calling:
                title = "Calling…"
                buttons = [headerButton("Cancel", #selector(liveHangUpTapped))]
            default: break
            }
        } else if showVideo {
            switch video.state {
            case .inCall:
                title = "In video call"
                buttons = [headerButton("End call", #selector(videoHangUpTapped), destructive: true),
                           headerButton(callRecordingActive ? "Stop rec" : "Record", #selector(callRecordTapped))]
            case .watching:
                title = "Watching video"
                buttons = [headerButton("Stop watching", #selector(videoHangUpTapped), destructive: true)]
            case .calling:
                title = "Calling…"
                buttons = [headerButton("Cancel", #selector(videoHangUpTapped))]
            default: break
            }
        }
        fullscreenStatusLabel?.stringValue = title
        fullscreenControls?.arrangedSubviews.forEach { fullscreenControls?.removeArrangedSubview($0); $0.removeFromSuperview() }
        buttons.forEach { fullscreenControls?.addArrangedSubview($0) }
    }

    // MARK: - Message table

    private func buildMessageTable() {
        let column = NSTableColumn(identifier: .init("message"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 6)
        tableScrollView.documentView = table
        tableScrollView.hasVerticalScroller = true
        tableScrollView.autohidesScrollers = true
    }

    private let tableScrollView: NSScrollView = {
        let scroll = NSScrollView()
        return scroll
    }()

    private func syncMessages() {
        history = store.messages.filter { $0.peerId == peer.id }
        table.reloadData()
        if history.count > lastCount, history.count > 0 {
            table.scrollRowToVisible(history.count - 1)
        }
        lastCount = history.count
        refreshHeader()
        updateVideoPanelVisibility()
    }

    // MARK: - Composer

    private func rebuildComposer() {
        composer.arrangedSubviews.forEach { composer.removeArrangedSubview($0); $0.removeFromSuperview() }
        composerTextView = nil
        switch composerMode {
        case .normal:
            let scroll = NSScrollView()
            let text = ComposerTextView()
            text.isRichText = false
            text.font = NSFont.systemFont(ofSize: 13)
            text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
            text.onEnter = { [weak self] in self?.sendTapped() }
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            composerTextView = text

            let mic = NSButton(image: NSImage(systemSymbolName: "waveform", accessibilityDescription: "Record voice message")!,
                               target: self, action: #selector(micTapped))
            mic.bezelStyle = .regularSquare
            mic.isBordered = false
            let send = NSButton(image: NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send message")!,
                                target: self, action: #selector(sendTapped))
            send.bezelStyle = .regularSquare
            send.isBordered = false

            text.delegate = self
            composer.addArrangedSubview(scroll)
            composer.addArrangedSubview(mic)
            composer.addArrangedSubview(send)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scroll.heightAnchor.constraint(equalToConstant: 36),
                scroll.widthAnchor.constraint(equalTo: composer.widthAnchor, constant: -90),
            ])
        case .memoRecording:
            let dot = NSTextField(labelWithString: "●")
            dot.textColor = .systemRed
            let elapsed = NSTextField(labelWithString: "0:00")
            elapsed.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            recordingElapsedLabel = elapsed
            let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
            wave.startLive()
            let meter = AudioMeter(view: wave)
            meter.start()
            memoMeter = meter
            let stop = NSButton(title: "Stop", target: self, action: #selector(stopMemoTapped))
            stop.bezelStyle = .rounded
            stop.hasDestructiveAction = true
            composer.addArrangedSubview(dot)
            composer.addArrangedSubview(elapsed)
            composer.addArrangedSubview(wave)
            composer.addArrangedSubview(stop)
            wave.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                wave.heightAnchor.constraint(equalToConstant: 28),
                wave.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            ])
        case .memoReview(let url):
            let play = NSButton(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Preview")!,
                                target: self, action: #selector(previewMemoTapped))
            play.bezelStyle = .regularSquare
            play.isBordered = false
            let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
            wave.style = .playback
            reviewSamples = WaveformView.amplitudes(url: url)
            wave.setStatic(samples: reviewSamples, progress: 0)
            reviewWave = wave
            let label = NSTextField(labelWithString: "Voice message · \(durationLabel(Int(memoDuration * 1000)))")
            label.textColor = .secondaryLabelColor
            let discard = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Discard")!,
                                   target: self, action: #selector(discardMemoTapped))
            discard.bezelStyle = .regularSquare
            discard.isBordered = false
            let send = NSButton(title: "Send", target: self, action: #selector(sendMemoTapped))
            send.bezelStyle = .rounded
            send.keyEquivalent = "\r"
            composer.addArrangedSubview(play)
            composer.addArrangedSubview(wave)
            composer.addArrangedSubview(label)
            composer.addArrangedSubview(send)
            composer.addArrangedSubview(discard)
            wave.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                wave.heightAnchor.constraint(equalToConstant: 28),
                wave.widthAnchor.constraint(equalToConstant: 180),
            ])
        case .callReview(let durationMs, _):
            let label = NSTextField(labelWithString: "Call recording · \(durationLabel(durationMs))")
            label.textColor = .secondaryLabelColor
            let discard = NSButton(title: "Discard", target: self, action: #selector(discardCallRecordingTapped))
            discard.bezelStyle = .rounded
            let send = NSButton(title: "Send", target: self, action: #selector(sendCallRecordingTapped))
            send.bezelStyle = .rounded
            send.keyEquivalent = "\r"
            composer.addArrangedSubview(label)
            composer.addArrangedSubview(discard)
            composer.addArrangedSubview(send)
        }
    }

    private func durationLabel(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        store.onUpdate = { [weak self] in self?.syncMessages() }
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.composerTextView)
        }
        store.onBanner = { [weak self] text in self?.showBanner(text) }
        LiveCall.shared.onState = { [weak self] in self?.refreshHeaderSoon() }
        VideoCall.shared.onState = { [weak self] in self?.refreshHeaderSoon() }
        VideoCall.shared.onFrame = { [weak self] image in self?.updateVideoFrame(image) }
        syncMessages()
        // Media artifacts (video-frame.jpg, recordings) for this conversation.
        let scope = peer.endpointId ?? peer.id
        Task.detached(priority: .userInitiated) { _ = media_set_scope(scope) }
    }

    override func viewDidDisappear() {
        store.onUpdate = nil
        store.onBanner = nil
        VideoCall.shared.onFrame = nil
        VideoCall.shared.onState = nil
        LiveCall.shared.onState = nil
        stopCallMeter()
        memoTimer?.invalidate()
        bannerTimer?.invalidate()
        player?.stop()
    }

    private func refreshHeaderSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshHeader()
            self?.updateLiveUI()
        }
    }

    private func updateVideoFrame(_ image: NSImage?) {
        videoSpinner.stopAnimation(nil)
        videoView.image = image
        fullscreenVideoView.image = image
        updateLiveUI()
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { history.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let message = history[row]
        switch message.kind {
        case .recording:
            return 46
        case .text(let text):
            return textHeight(for: message, text: text)
        }
    }

    /// Cached bubble row height; measured from the same attributed string the
    /// text view renders, so markdown line wraps can't clip.
    private func textHeight(for message: ChatMessage, text: String) -> CGFloat {
        if let cached = textHeights[message.id] { return cached }
        let width = max(view.bounds.width - 140, 120)
        let size = renderText(text).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil).size
        let height = ceil(size.height) + 22
        textHeights[message.id] = height
        return height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        messageRow(history[row])
    }

    private func messageRow(_ message: ChatMessage) -> NSView {
        let row = NSView()
        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.layer?.backgroundColor = message.outgoing
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : NSColor.controlBackgroundColor.cgColor

        switch message.kind {
        case .text(let text):
            let tv = NSTextView()
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textColor = .labelColor // theme-aware (NSTextView defaults to black)
            tv.textContainerInset = .zero
            tv.textContainer?.lineFragmentPadding = 0
            tv.textStorage?.setAttributedString(renderText(text))
            tv.translatesAutoresizingMaskIntoConstraints = false
            bubble.addSubview(tv)
            // row height cache includes 12pt padding (6 top + 6 bottom); the
            // remaining 10 was label slack, now explicit so links don't clip
            NSLayoutConstraint.activate([
                tv.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 6),
                tv.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -6),
                tv.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
                tv.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
                tv.heightAnchor.constraint(equalToConstant: textHeight(for: message, text: text) - 18),
                bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            ])
        case .recording(let ticket, let durationMs):
            let play = NSButton(image: NSImage(systemSymbolName: playingMessageId == message.id ? "pause.fill" : "play.fill",
                                               accessibilityDescription: "Play voice message")!,
                                target: self, action: #selector(playTapped(_:)))
            play.bezelStyle = .regularSquare
            play.isBordered = false
            play.identifier = NSUserInterfaceItemIdentifier(message.id)
            let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: 140, height: 26))
            if let url = store.recordingURLs[ticket] {
                wave.setStatic(samples: WaveformView.amplitudes(url: url), progress: 0)
                staticWaves[message.id] = wave
            } else {
                wave.setStatic(samples: .init(repeating: 0, count: 32), progress: 0)
            }
            wave.translatesAutoresizingMaskIntoConstraints = false
            let duration = NSTextField(labelWithString: durationLabel(durationMs))
            duration.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            duration.textColor = .secondaryLabelColor
            bubble.addSubview(play)
            bubble.addSubview(wave)
            bubble.addSubview(duration)
            NSLayoutConstraint.activate([
                play.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 8),
                play.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
                wave.leadingAnchor.constraint(equalTo: play.trailingAnchor, constant: 6),
                wave.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
                wave.widthAnchor.constraint(equalToConstant: 140),
                wave.heightAnchor.constraint(equalToConstant: 26),
                duration.leadingAnchor.constraint(equalTo: wave.trailingAnchor, constant: 6),
                duration.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
                duration.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            ])
        }

        row.addSubview(bubble)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        let leading = bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10)
        let trailing = bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10)
        if message.outgoing {
            leading.priority = .defaultLow
            trailing.isActive = true
        } else {
            trailing.priority = .defaultLow
            leading.isActive = true
        }
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
            leading, trailing,
        ])
        return row
    }

    // MARK: - Sending text

    @objc private func sendTapped() {
        guard let composerTextView else { return }
        let text = composerTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerTextView.string = ""
        let id = "local-\(UUID().uuidString)"
        store.appendOutgoing(ChatMessage(id: id, peerId: peer.id, kind: .text(text), outgoing: true, status: "Sending"))
        Task {
            do {
                try await client.sendText(to: peer.id, text)
                store.updateMessage(id: id) { $0.status = "Sent" }
            } catch {
                store.updateMessage(id: id) { $0.status = "Failed" }
                showBanner(error.localizedDescription)
            }
        }
    }

    // MARK: - Calls

    @objc private func liveCallTapped() { live.dial(peer.id) }
    @objc private func videoCallTapped() { video.dial(peer.id) }
    @objc private func liveAnswerTapped() { live.answer(); refreshHeaderSoon() }
    @objc private func liveDeclineTapped() { live.decline(); refreshHeaderSoon() }
    @objc private func liveHangUpTapped() { live.hangUp(); refreshHeaderSoon() }
    @objc private func videoAnswerTapped() { video.answer(); refreshHeaderSoon() }
    @objc private func videoDeclineTapped() { video.decline(); refreshHeaderSoon() }
    @objc private func videoHangUpTapped() { video.hangUp(); refreshHeaderSoon() }

    // MARK: - Live stage expand/collapse

    @objc private func liveExpandTapped() {
        isLiveFullscreen = true
        updateLiveUI()
    }

    @objc private func liveCollapseTapped() {
        isLiveFullscreen = false
        updateLiveUI()
    }

    // MARK: - One-way video share (GUI's video_share)

    @objc private func shareVideoTapped() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mpeg4Movie, .movie]
        panel.message = "Choose a fragmented MP4 to broadcast (GUI's Share video)."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task {
            do {
                let result = try await client.request(method: "media.live.publish", params: [
                    "file": AnyEncodable(file.path),
                    "video": AnyEncodable(true),
                ])
                guard let ticket = result?["ticket"]?.stringValue, !ticket.isEmpty else {
                    await MainActor.run { self.showBanner("Video publish failed") }
                    return
                }
                try await client.sendText(to: peer.id, LiveInvite.build(action: "start", ticket: ticket, call: false))
                await MainActor.run { self.showBanner("Video sharing started") }
            } catch {
                await MainActor.run { self.showBanner("Video publish failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Peer details

    @objc private func peerDetailsTapped() {
        let popover = NSPopover()
        let content = NSViewController()
        let endpoint = NSTextField(wrappingLabelWithString: peer.endpointId ?? peer.id)
        endpoint.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        endpoint.isSelectable = true
        let copy = NSButton(title: "Copy endpoint ID", target: self, action: #selector(copyEndpointTapped))
        copy.bezelStyle = .rounded
        let stack = NSStackView(views: [
            NSTextField(labelWithString: peer.displayName),
            endpoint,
            copy,
        ])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        content.view = stack
        popover.contentViewController = content
        popover.behavior = .transient
        popover.show(relativeTo: callLabel.bounds, of: callLabel, preferredEdge: .minY)
        peerPopover = popover
    }

    @objc private func copyEndpointTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(peer.endpointId ?? peer.id, forType: .string)
        peerPopover?.close()
    }

    // MARK: - Memo recording (shell-side AVAudioRecorder, real metering)

    @objc private func micTapped() {
        VoiceMemo.requestPermission { [weak self] granted in
            guard granted, let self else { return }
            DispatchQueue.main.async {
                let memo = VoiceMemo()
                do {
                    _ = try memo.start()
                } catch {
                    NSLog("idfon memo start failed: \(error.localizedDescription)")
                    return
                }
                self.memo = memo
                self.memoStartDate = Date()
                self.memoURL = nil
                self.composerMode = .memoRecording
                self.rebuildComposer()
                // VoiceMemo meters into the live waveform; this timer only
                // drives the elapsed label.
                self.memoTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.memo != nil else { return }
                        let elapsed = Date().timeIntervalSince(self.memoStartDate)
                        self.recordingElapsedLabel?.stringValue = String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
                    }
                }
            }
        }
    }

    @objc private func stopMemoTapped() {
        memoTimer?.invalidate()
        memoTimer = nil
        memoMeter?.stop()
        memoMeter = nil
        guard let memo else { return }
        guard let result = memo.stop() else { return }
        self.memo = nil
        memoURL = result.url
        memoDuration = result.duration
        composerMode = .memoReview(url: result.url)
        rebuildComposer()
    }

    @objc private func previewMemoTapped() {
        guard let url = memoURL else { return }
        if let player, player.isPlaying {
            player.stop()
            return
        }
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        newPlayer.delegate = self
        newPlayer.play()
        player = newPlayer
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.reviewWave?.setStatic(samples: self.reviewSamples, progress: player.currentTime / max(player.duration, 0.001))
            }
        }
    }

    @objc private func discardMemoTapped() {
        player?.stop()
        progressTimer?.invalidate()
        memoURL = nil
        memoDuration = 0
        composerMode = .normal
        rebuildComposer()
    }

    @objc private func sendMemoTapped() {
        guard let url = memoURL else { return }
        let durationMs = Int(memoDuration * 1000)
        discardMemoTapped()
        Task { await sendRecording(fileURL: url, durationMs: durationMs, codec: "pcm", sampleRate: "16000") }
    }

    private func sendRecording(fileURL: URL, durationMs: Int, codec: String, sampleRate: String) async {
        do {
            let data = try Data(contentsOf: fileURL)
            let ticket = try await client.putData(data, resourceId: "memo-\(UUID().uuidString)")
            let envelope = """
            IDFON-RECORDING/1
            id=\(UUID().uuidString)
            codec=\(codec)
            sample_rate=\(sampleRate)
            duration_ms=\(durationMs)
            sender_id=\(store.selfPeerId)
            ticket=\(ticket)
            """
            try await client.sendText(to: peer.id, envelope)
            await MainActor.run {
                store.appendOutgoing(ChatMessage(id: "local-\(UUID().uuidString)", peerId: peer.id, kind: .recording(ticket: ticket, durationMs: durationMs), outgoing: true, status: "Sent"))
                store.cacheRecording(ticket, url: fileURL)
                self.showBanner("Audio sent")
            }
        } catch {
            await MainActor.run { self.showBanner("Send failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - In-call recording (daemon-side opus, GUI's media.recording.*)

    @objc private func callRecordTapped() {
        if !callRecordingActive {
            guard live.state == .inCall(peer: peer.id) || video.state == .inCall else { return }
            Task.detached(priority: .userInitiated) { _ = media_recording_start() }
            callRecordingActive = true
            let meterWave = WaveformView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
            meterWave.startLive()
            callRecordingWaveView = meterWave
            // Same display-only mic tap as the inline call bar (two engine
            // taps would race the input node).
            let meter = ensureCallMeter()
            meter.add(view: meterWave)
            // Swap the composer into a live recording bar.
            composer.arrangedSubviews.forEach { composer.removeArrangedSubview($0); $0.removeFromSuperview() }
            let dot = NSTextField(labelWithString: "●")
            dot.textColor = .systemRed
            let elapsed = NSTextField(labelWithString: "0:00")
            elapsed.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            recordingElapsedLabel = elapsed
            let liveWave = callRecordingWaveView ?? meterWave
            let stop = NSButton(title: "Stop", target: self, action: #selector(callRecordTapped))
            stop.bezelStyle = .rounded
            stop.hasDestructiveAction = true
            composer.addArrangedSubview(dot)
            composer.addArrangedSubview(elapsed)
            composer.addArrangedSubview(liveWave)
            composer.addArrangedSubview(stop)
            liveWave.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                liveWave.heightAnchor.constraint(equalToConstant: 28),
                liveWave.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            ])
            refreshHeader()
        } else {
            callRecordingActive = false
            // Shared call meter keeps running — the call itself does.
            recordingElapsedLabel = nil
            Task {
                let stored = await Task.detached(priority: .userInitiated) { () -> String in
                    let ptr = media_live_recording_store()
                    defer { if let ptr { rust_free_string(ptr) } }
                    return ptr.map { String(cString: $0) } ?? ""
                }.value
                let fields = stored.split(separator: "\n").map(String.init)
                guard fields.count == 2, let durationMs = Int(fields[0]), !fields[1].isEmpty else {
                    await MainActor.run { self.showBanner("Recording store failed") }
                    return
                }
                let ticket = fields[1]
                await Task.detached(priority: .userInitiated) { _ = media_recording_persist(ticket) }.value
                await MainActor.run {
                    self.pendingCallRecording = (durationMs, ticket)
                    self.composerMode = .callReview(durationMs: durationMs, ticket: ticket)
                    self.rebuildComposer()
                }
            }
            refreshHeader()
        }
    }

    @objc private func discardCallRecordingTapped() {
        pendingCallRecording = nil
        composerMode = .normal
        rebuildComposer()
    }

    @objc private func sendCallRecordingTapped() {
        guard let pending = pendingCallRecording else { return }
        pendingCallRecording = nil
        composerMode = .normal
        rebuildComposer()
        let envelope = """
        IDFON-RECORDING/1
        id=\(UUID().uuidString)
        codec=opus
        channels=1
        sample_rate=48000
        duration_ms=\(pending.durationMs)
        sender_id=\(store.selfPeerId)
        ticket=\(pending.ticket)
        """
        Task {
            do {
                try await client.sendText(to: peer.id, envelope)
                await MainActor.run {
                    store.appendOutgoing(ChatMessage(id: "local-\(UUID().uuidString)", peerId: peer.id, kind: .recording(ticket: pending.ticket, durationMs: pending.durationMs), outgoing: true, status: "Sent"))
                    self.showBanner("Audio sent")
                }
            } catch {
                await MainActor.run { self.showBanner("Send failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Playback

    private func togglePlayback(messageId: String, file: URL?) {
        guard let file else { return }
        if let player, playingMessageId == messageId {
            player.stop()
            playingMessageId = nil
            progressTimer?.invalidate()
            table.reloadData()
            return
        }
        player?.stop()
        guard let newPlayer = try? AVAudioPlayer(contentsOf: file) else {
            showBanner("Cannot play this recording format")
            return
        }
        newPlayer.delegate = self
        newPlayer.play()
        player = newPlayer
        playingMessageId = messageId
        // Progress on the bubble's static waveform.
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.staticWaves[messageId]?.setStatic(
                    samples: self.staticWavesSamples[messageId] ?? .init(repeating: 0, count: 32),
                    progress: player.currentTime / max(player.duration, 0.001))
            }
        }
        table.reloadData()
    }

    private var staticWavesSamples: [String: [Float]] = [:]

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            playingMessageId = nil
            progressTimer?.invalidate()
            table.reloadData()
        }
    }

    @objc private func playTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, !id.isEmpty else { return }
        let message = history.first { $0.id == id }
        guard case .recording(let ticket, _) = message?.kind else { return }
        togglePlayback(messageId: id, file: store.recordingURLs[ticket])
    }
}

extension ChatViewController: NSTextViewDelegate {}

/// Composer field: Enter sends (GUI's submit-on-enter); Shift+Enter newline.
final class ComposerTextView: NSTextView {
    var onEnter: (() -> Void)?

    override func insertNewline(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
            super.insertNewline(sender)
        } else {
            onEnter?()
        }
    }
}