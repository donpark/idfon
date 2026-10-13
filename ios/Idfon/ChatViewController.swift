import UIKit
import AVFAudio
import UniformTypeIdentifiers

/// D11 variant-A bubble: ours right (blue), theirs left (gray); the far edge
/// keeps a gap so the side reads at a glance. Sender header only where a side
/// carries multiple identities (rooms); provenance caption + time inside.
private final class MessageCell: UITableViewCell {
    let messageLabel = UILabel()
    let captionLabel = UILabel()
    /// Header row (avatar chip + nick) — hidden in 1:1 (D11: the side shows
    /// the sender there); shown where a side carries multiple identities.
    private let senderStack = UIStackView()
    private let senderLabel = UILabel()
    private let avatarView = UIView()
    private let avatarLabel = UILabel()
    private let bubbleView = UIView()
    private var sideConstraints: [NSLayoutConstraint] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        bubbleView.layer.cornerRadius = 18
        bubbleView.layer.cornerCurve = .continuous
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        senderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.numberOfLines = 0
        captionLabel.font = .preferredFont(forTextStyle: .caption2)
        avatarView.layer.cornerRadius = 9
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarLabel.font = .systemFont(ofSize: 9, weight: .bold)
        avatarLabel.textColor = .white
        avatarLabel.textAlignment = .center
        avatarLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarView.addSubview(avatarLabel)
        senderStack.axis = .horizontal
        senderStack.spacing = 6
        senderStack.alignment = .center
        [avatarView, senderLabel].forEach(senderStack.addArrangedSubview)
        let stack = UIStackView(arrangedSubviews: [senderStack, messageLabel, captionLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(stack)
        contentView.addSubview(bubbleView)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -14),
            avatarView.widthAnchor.constraint(equalToConstant: 18),
            avatarView.heightAnchor.constraint(equalToConstant: 18),
            avatarLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
        setAlignment(outgoing: false)
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    /// The sender header (avatar chip + nick, D11); `nil` collapses it.
    func setSender(_ name: String?) {
        senderLabel.text = name
        avatarLabel.text = name.map {
            $0.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
        }
        avatarView.backgroundColor = name.map { Self.avatarColor(for: $0) }
        senderStack.isHidden = name == nil
    }

    /// Stable per-name chip color (hashing is order-stable here, unlike
    /// `hashValue`).
    private static func avatarColor(for name: String) -> UIColor {
        let palette: [UIColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPink, .systemPurple, .systemTeal]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    func setAlignment(outgoing: Bool) {
        NSLayoutConstraint.deactivate(sideConstraints)
        if outgoing {
            bubbleView.backgroundColor = .systemBlue
            senderLabel.textColor = UIColor.white.withAlphaComponent(0.8)
            messageLabel.textColor = .white
            captionLabel.textColor = UIColor.white.withAlphaComponent(0.65)
            sideConstraints = [
                bubbleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                bubbleView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 60),
            ]
        } else {
            bubbleView.backgroundColor = .secondarySystemBackground
            senderLabel.textColor = .label
            messageLabel.textColor = .label
            captionLabel.textColor = .secondaryLabel
            sideConstraints = [
                bubbleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                bubbleView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -60),
            ]
        }
        NSLayoutConstraint.activate(sideConstraints)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Self-sizing labels wrap at this cap; it keeps the bubble hugging its
        // content instead of spanning the row.
        let cap = max(contentView.bounds.width * 0.78 - 40, 120)
        messageLabel.preferredMaxLayoutWidth = cap
        captionLabel.preferredMaxLayoutWidth = cap
    }
}

/// The timeline's card rows (D11): content cards (artifact / file / voice /
/// render) sit on their side like a bubble, thread cards are centered with a
/// gap on both sides, bucket cards span the row. Colored edges carry card
/// kind (thread blue, artifact green) and always pair with a kind icon (§7.6).
private final class TimelineCardCell: UITableViewCell {
    enum Placement { case side(outgoing: Bool), centered, fullWidth }
    enum Edge { case colored(UIColor), dashed }

    private let card = UIView()
    private let edgeView = UIView()
    private let titleIcon = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let disclosure = UIImageView()
    /// Dashed stroke for bucket cards; plain cards keep no border.
    private let dashedBorder = CAShapeLayer()
    private var placementConstraints: [NSLayoutConstraint] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        edgeView.layer.cornerRadius = 1.5
        edgeView.translatesAutoresizingMaskIntoConstraints = false
        titleIcon.contentMode = .scaleAspectFit
        titleIcon.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 0
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        disclosure.image = UIImage(systemName: "chevron.right")
        disclosure.tintColor = .tertiaryLabel
        disclosure.setContentHuggingPriority(.required, for: .horizontal)
        dashedBorder.fillColor = nil
        dashedBorder.strokeColor = UIColor.separator.cgColor
        dashedBorder.lineDashPattern = [4, 4]
        dashedBorder.lineWidth = 1
        dashedBorder.isHidden = true
        card.layer.addSublayer(dashedBorder)
        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [titleIcon, text, disclosure])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(edgeView)
        card.addSubview(row)
        contentView.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            edgeView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            edgeView.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            edgeView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            edgeView.widthAnchor.constraint(equalToConstant: 3),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            titleIcon.widthAnchor.constraint(equalToConstant: 20),
            disclosure.widthAnchor.constraint(equalToConstant: 14),
        ])
        setPlacement(.fullWidth)
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    func setPlacement(_ placement: Placement) {
        NSLayoutConstraint.deactivate(placementConstraints)
        switch placement {
        case .side(let outgoing):
            // Like bubbles: pin to the side, gap at the far edge so the sender
            // is clear at a glance (never span the row and read right-aligned).
            if outgoing {
                placementConstraints = [
                    card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                    card.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 60),
                ]
            } else {
                placementConstraints = [
                    card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                    card.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -60),
                ]
            }
        case .centered:
            // Threads are two-sided summaries: centered, gaps on both sides.
            placementConstraints = [
                card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                card.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 60),
                card.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -60),
            ]
        case .fullWidth:
            placementConstraints = [
                card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            ]
        }
        NSLayoutConstraint.activate(placementConstraints)
    }

    func configure(edge: Edge, glyph: String?, title: String, subtitle: String?,
                   placement: Placement, expanded: Bool, showsDisclosure: Bool = true) {
        switch edge {
        case .colored(let color):
            edgeView.backgroundColor = color
            dashedBorder.isHidden = true
        case .dashed:
            edgeView.backgroundColor = .clear
            dashedBorder.isHidden = false
        }
        titleIcon.image = glyph.flatMap { UIImage(systemName: $0) }
        titleIcon.isHidden = glyph == nil
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        disclosure.isHidden = !showsDisclosure
        disclosure.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right")
        // §7.6: the card is one VoiceOver element with a tap action.
        isAccessibilityElement = true
        accessibilityLabel = subtitle.map { "\(title). \($0)" } ?? title
        accessibilityTraits = .button
        setPlacement(placement)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashedBorder.path = UIBezierPath(roundedRect: card.bounds, cornerRadius: 14).cgPath
        let cap = max(contentView.bounds.width * 0.78 - 60, 120)
        titleLabel.preferredMaxLayoutWidth = cap
        subtitleLabel.preferredMaxLayoutWidth = cap
    }
}

/// §7.2a ambient dateline: slim, low-contrast day separator.
private final class DatelineCell: UITableViewCell {
    let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let left = UIView()
        let right = UIView()
        [left, right].forEach {
            $0.backgroundColor = .separator
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView.addSubview(left)
        contentView.addSubview(label)
        contentView.addSubview(right)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            left.heightAnchor.constraint(equalToConstant: 0.5),
            right.heightAnchor.constraint(equalToConstant: 0.5),
            left.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            right.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            left.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            left.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
            label.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -8),
            right.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }
}

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {
    /// Read by the Live Activity Bar coordinator (density + `.open` routing).
    let peer: Peer
    /// Rooms share the chat surface but expose no call controls, so the Bar
    /// shows no idle Call button for them.
    // shortcut: rooms get no call button — the voice side-channel is 1:1 only
    // and refuses calls in a room (docs/chatrooms.md); §7.1's room call button
    // waits on the protocol.
    var allowsCall: Bool { !conversation.isRoom }
    private let conversation: Conversation
    private let client = DaemonClient()

    private let tableView = UITableView()
    private let composerBar = UIView()
    private let composerText = UITextView()
    private let micButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let attachButton = UIButton(type: .system)
    private let callStatusLabel = UILabel()
    private let waveformView = LiveWaveformView(frame: .zero)
    private var waveformHeight: NSLayoutConstraint!
    private var audioMeter: AudioMeter!
    private var composerHeight: NSLayoutConstraint!

    // A pending artifact reference attached to the next sent turn.
    private var pendingReference: (artifact: Artifact, selector: ArtifactSelector, preview: Data?)?
    private let referenceChip = UIView()
    private let referenceChipLabel = UILabel()
    private var referenceChipHeight: NSLayoutConstraint!

    // recording state
    enum ComposerMode { case normal, recording, review }
    private var mode: ComposerMode = .normal { didSet { applyMode() } }
    private var memo: VoiceMemo?
    private var memoURL: URL?
    private var memoDuration: TimeInterval = 0
    private var memoStartDate = Date()
    private var memoTimer: Timer?
    private let reviewWaveform = LiveWaveformView(frame: .zero)
    private let elapsedLabel = UILabel()
    private let stopButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private var reviewPlayer: AVAudioPlayer?
    /// The in-flight memo upload, so the Session Tray's Cancel can abort it.
    private var memoTask: Task<Void, Never>?
    /// The in-flight file upload (§5), cancelled the same way.
    private var fileTask: Task<Void, Never>?

    private var messages: [ChatMessage] = []
    /// §7.3 derived display rows; `messages` stays the raw log.
    private var timelineItems: [Timeline.Item] = []
    /// Cards drilled open in place (§7.4); keyed by item id.
    private var expandedItems: Set<String> = []
    /// §7.3b: shown whenever the bottom is out of view — never auto-scroll a
    /// reader who has scrolled up.
    private let jumpButton = UIButton(type: .system)
    private var senderNames: [String: String] = [:]
    private var players: [String: AVAudioPlayer] = [:] // ticket -> player

    // inline live-video bar (tap to expand the fullscreen call screen)
    private let videoBar = UIView()
    private var videoBarHeight: NSLayoutConstraint!
    private var inlineVideoImage: UIImageView?
    private var videoObservers: [NSObjectProtocol] = []

    // D8 nav chrome (§7.1): the overflow (`ellipsis.circle`) is the stable
    // right-edge anchor; the call-state button sits left of it and is written
    // by LiveActivityController through `callChromeItem` — nav starts/stops
    // the call, the Bar operates it.
    private let overflowItem = UIBarButtonItem()
    /// The call-state nav item (idle call → calling → hang-up). Nil while an
    /// incoming ring (the Bar shows Answer/Decline) or another peer's call owns
    /// the chrome.
    var callChromeItem: UIBarButtonItem? { didSet { refreshNavChrome() } }

    init(peer: Peer) {
        self.peer = peer
        self.conversation = Conversation(peer: peer)
        super.init(nibName: nil, bundle: nil)
        // D12: the tab bar yields to the chat — even minimized it would float
        // over the composer, which owns the bottom edge.
        hidesBottomBarWhenPushed = true
    }

    init(room: Room) {
        self.peer = Peer(id: room.id, name: room.name, endpointId: nil, aliases: nil, callMode: nil)
        self.conversation = Conversation(room: room)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The nav bar is the thread's identity and call chrome (§7.1): title =
        // avatar + name, tappable → the person screen; trailing cluster =
        // [overflow] + the call-state item LiveActivityController writes (D8).
        title = conversation.title
        if !conversation.isRoom { navigationItem.largeTitleDisplayMode = .never }
        view.backgroundColor = .systemBackground
        buildNavChrome()

        // The call entry is the Bar's idle chrome (docs/ui-design-notes.md §3
        // State 1): the floating panel shows a Call button when idle and the
        // in-call controls while a call is active, so there is no nav-bar
        // button left to press twice. `.generic` keeps the back button
        // reading "Back" instead of the callee's name when a thread is
        // stacked on another.
        navigationItem.backButtonDisplayMode = .generic

        buildViews()
        ChatStore.shared.addObserver(self)
        ChatStore.shared.markRead(conversation)
        syncMessages()
        if conversation.isRoom {
            Task {
                if let peers = try? await client.peers() {
                    await MainActor.run {
                        self.senderNames = Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0.displayName) })
                        self.tableView.reloadData()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(forName: .init("idfon.dial"), object: nil, queue: .main) { [weak self] note in
            guard let ref = note.userInfo?["ref"] as? String else { return }
            self?.dial(peerRef: ref)
        }
        videoObservers.append(NotificationCenter.default.addObserver(forName: .idfonVideoChanged, object: nil, queue: .main) { [weak self] _ in
            self?.syncVideoBar()
        })
        videoObservers.append(NotificationCenter.default.addObserver(forName: .idfonVideoFrame, object: nil, queue: .main) { [weak self] note in
            if let image = note.object as? UIImage { self?.inlineVideoImage?.image = image }
        })
        // Call feedback from the call singletons ("No voice call available",
        // "No live calls …", "A call is already in progress").
        videoObservers.append(NotificationCenter.default.addObserver(forName: .idfonCallStatus, object: nil, queue: .main) { [weak self] note in
            guard let text = note.userInfo?["text"] as? String else { return }
            self?.showCallStatus(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard self?.callStatusLabel.text == text else { return }
                self?.showCallStatus(nil)
            }
        })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A rename in the person screen must be reflected when we come back.
        title = conversation.title
        titleButton.setTitle(conversation.title, for: .normal)
        ChatStore.shared.onPoint = { [weak self] point, _ in self?.handlePoint(point) }
        ChatStore.shared.onShow = { [weak self] show, _ in self?.handleShow(show) }
        ChatStore.shared.onScreenshot = { [weak self] request, _ in self?.handleScreenshot(request) }
        if let peerId = conversation.peer?.id {
            for point in ChatStore.shared.takePendingPoints(peerId: peerId) { handlePoint(point) }
            for show in ChatStore.shared.takePendingShows(peerId: peerId) { handleShow(show) }
            for request in ChatStore.shared.takePendingScreenshots(peerId: peerId) { handleScreenshot(request) }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ChatStore.shared.onPoint = nil
        ChatStore.shared.onShow = nil
        ChatStore.shared.onScreenshot = nil
    }

    /// The artifact with `artifactId` in this conversation, or a placeholder
    /// carrying the envelope's blob ticket when the chat never showed it.
    private func artifact(for artifactId: String, blobTicket: String?) -> Artifact {
        messages.compactMap { message -> Artifact? in
            if case .artifact(let artifact) = message.kind, artifact.artifactId == artifactId {
                return artifact
            }
            return nil
        }.last ?? Artifact(
            artifactId: artifactId, kind: .document, mime: "text/plain",
            title: artifactId, sizeBytes: 0, blobTicket: blobTicket,
            sourceMessageId: nil, conversation: nil, metadata: nil, createdAt: "")
    }

    /// Open the artifact an agent pointed at, with the highlight applied.
    private func handlePoint(_ point: PointEnvelope) {
        guard let peerId = conversation.peer?.id else { return }
        let artifact = artifact(for: point.artifactId, blobTicket: point.blobTicket)
        let detail = ArtifactDetailViewController(artifact: artifact, peerRef: peerId)
        detail.point = (point.selector, point.note)
        detail.onReference = { [weak self] selector, preview in
            guard let self else { return }
            self.pendingReference = (artifact, selector, preview)
            self.updateReferenceChip()
            self.composerText.becomeFirstResponder()
        }
        present(UINavigationController(rootViewController: detail), animated: true)
    }

    /// Open the artifact an agent asked to show, with no highlight.
    private func handleShow(_ show: ShowEnvelope) {
        guard let peerId = conversation.peer?.id else { return }
        let artifact = artifact(for: show.artifactId, blobTicket: show.blobTicket)
        let detail = ArtifactDetailViewController(artifact: artifact, peerRef: peerId)
        detail.onReference = { [weak self] selector, preview in
            guard let self else { return }
            self.pendingReference = (artifact, selector, preview)
            self.updateReferenceChip()
            self.composerText.becomeFirstResponder()
        }
        present(UINavigationController(rootViewController: detail), animated: true)
    }

    /// Capture this window and send it back to the agent that asked.
    private func handleScreenshot(_ request: ScreenshotEnvelope) {
        guard let window = view.window else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenshot-\(UUID().uuidString).png")
        guard (try? data.write(to: url)) != nil else { return }
        sendFile(at: url, name: "screenshot.png")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        videoObservers.forEach(NotificationCenter.default.removeObserver)
        videoObservers = []
        if memo != nil {
            memo?.discard()
            memo = nil
            memoURL = nil
            mode = .normal
        }
    }

    // MARK: - Views

    private let titleButton = UIButton(type: .system)

    /// §7.1 nav chrome: title = avatar + name, tappable → the person screen
    /// (the title is navigation, P9); trailing = [overflow] + the call-state
    /// item (written by LiveActivityController). Rooms keep a plain title and
    /// get no call-state item (`allowsCall` is false).
    private func buildNavChrome() {
        if !conversation.isRoom {
            titleButton.setTitle(conversation.title, for: .normal)
            titleButton.setImage(UIImage(systemName: "person.crop.circle.fill"), for: .normal)
            titleButton.setTitleColor(.label, for: .normal)
            titleButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
            titleButton.tintColor = .label
            titleButton.addTarget(self, action: #selector(titleTapped), for: .touchUpInside)
            navigationItem.titleView = titleButton
        }
        // ☰ reads as a nav drawer; the overflow is `ellipsis.circle` (P12).
        overflowItem.image = UIImage(systemName: "ellipsis.circle")
        overflowItem.menu = buildOverflowMenu()
        refreshNavChrome()
    }

    private func refreshNavChrome() {
        navigationItem.rightBarButtonItems = [overflowItem] + (callChromeItem.map { [$0] } ?? [])
    }

    /// D8 overflow. New Session and Share Screen are the design's verbs, but
    /// their backends (thread derivation §7.3, the screenshare stream) don't
    /// exist yet — shown disabled so the menu shape is visible without
    /// pretending to work.
    private func buildOverflowMenu() -> UIMenu {
        if conversation.isRoom {
            return UIMenu(children: [
                UIAction(title: "Copy Invite", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.copyInviteTapped()
                },
                UIAction(title: "Leave", image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                         attributes: .destructive) { [weak self] _ in
                    self?.leaveTapped()
                },
            ])
        }
        let newSession = UIAction(title: "New Session", image: UIImage(systemName: "plus.bubble"),
                                  attributes: .disabled) { _ in }
        let shareScreen = UIAction(title: "Share Screen", image: UIImage(systemName: "rectangle.inset.filled.and.person.filled"),
                                   attributes: .disabled) { _ in }
        let settings = UIAction(title: "Chat Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.openPersonScreen()
        }
        return UIMenu(children: [newSession, shareScreen, settings])
    }

    @objc private func titleTapped() { openPersonScreen() }

    /// The person screen (§6). ContactDetail is its stand-in until the
    /// dedicated hub exists; on-device agents keep their editor, and identity
    /// labels (A8) wait on the identity data model.
    func openPersonScreen() {
        if let id = OnDeviceAgent.id(fromPeerId: peer.id) {
            let editor = OnDeviceAgentEditorViewController(agent: OnDeviceAgents.shared.agent(id: id)) { }
            navigationController?.pushViewController(editor, animated: true)
            return
        }
        let detail = ContactDetailViewController(peer: peer)
        detail.onChanged = { [weak self] in
            guard let self else { return }
            self.title = self.conversation.title
            self.titleButton.setTitle(self.conversation.title, for: .normal)
        }
        navigationController?.pushViewController(detail, animated: true)
    }

    private func buildViews() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(MessageCell.self, forCellReuseIdentifier: "message")
        tableView.register(TimelineCardCell.self, forCellReuseIdentifier: "card")
        tableView.register(DatelineCell.self, forCellReuseIdentifier: "dateline")
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive

        // §7.3b jump-to-latest (P12: Messages).
        var jumpConfig = UIButton.Configuration.filled()
        jumpConfig.image = UIImage(systemName: "chevron.down")
        jumpConfig.cornerStyle = .capsule
        jumpButton.configuration = jumpConfig
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.isHidden = true
        jumpButton.accessibilityLabel = "Jump to latest"
        jumpButton.addTarget(self, action: #selector(jumpToLatestTapped), for: .touchUpInside)

        composerBar.translatesAutoresizingMaskIntoConstraints = false
        composerBar.backgroundColor = .secondarySystemBackground
        composerBar.layer.cornerRadius = 20

        composerText.translatesAutoresizingMaskIntoConstraints = false
        composerText.font = .preferredFont(forTextStyle: .body)
        composerText.delegate = self
        composerText.isScrollEnabled = false
        composerText.backgroundColor = .clear
        composerText.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        composerText.delegate = self

        // One symbol size for every composer control; the default symbol size
        // rendered these too small to hit comfortably.
        let composerSymbol = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)

        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.setImage(UIImage(systemName: "waveform", withConfiguration: composerSymbol), for: .normal)
        micButton.tintColor = .secondaryLabel
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill", withConfiguration: composerSymbol), for: .normal)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.setImage(UIImage(systemName: "plus.circle", withConfiguration: composerSymbol), for: .normal)
        attachButton.tintColor = .secondaryLabel
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)

        callStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        callStatusLabel.font = .preferredFont(forTextStyle: .callout)
        callStatusLabel.textColor = .secondaryLabel
        callStatusLabel.textAlignment = .center
        callStatusLabel.isHidden = true

        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformHeight = waveformView.heightAnchor.constraint(equalToConstant: 0)
        audioMeter = AudioMeter(view: waveformView)

        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.setImage(UIImage(systemName: "stop.fill", withConfiguration: composerSymbol), for: .normal)
        stopButton.tintColor = .systemRed
        stopButton.addTarget(self, action: #selector(stopRecordingTapped), for: .touchUpInside)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: composerSymbol), for: .normal)
        closeButton.addTarget(self, action: #selector(discardMemoTapped), for: .touchUpInside)

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.setImage(UIImage(systemName: "play.fill", withConfiguration: composerSymbol), for: .normal)
        playButton.addTarget(self, action: #selector(playMemoTapped), for: .touchUpInside)

        reviewWaveform.translatesAutoresizingMaskIntoConstraints = false

        referenceChip.translatesAutoresizingMaskIntoConstraints = false
        referenceChip.backgroundColor = .tertiarySystemBackground
        referenceChip.layer.cornerRadius = 15
        referenceChip.isHidden = true
        referenceChipLabel.translatesAutoresizingMaskIntoConstraints = false
        referenceChipLabel.font = .preferredFont(forTextStyle: .footnote)
        referenceChipLabel.lineBreakMode = .byTruncatingMiddle
        referenceChip.addSubview(referenceChipLabel)
        let clearReference = UIButton(type: .system)
        clearReference.translatesAutoresizingMaskIntoConstraints = false
        clearReference.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearReference.tintColor = .secondaryLabel
        clearReference.addTarget(self, action: #selector(clearReferenceTapped), for: .touchUpInside)
        referenceChip.addSubview(clearReference)
        NSLayoutConstraint.activate([
            referenceChipLabel.leadingAnchor.constraint(equalTo: referenceChip.leadingAnchor, constant: 12),
            referenceChipLabel.centerYAnchor.constraint(equalTo: referenceChip.centerYAnchor),
            referenceChipLabel.trailingAnchor.constraint(equalTo: clearReference.leadingAnchor, constant: -6),
            clearReference.centerYAnchor.constraint(equalTo: referenceChip.centerYAnchor),
            clearReference.trailingAnchor.constraint(equalTo: referenceChip.trailingAnchor, constant: -8),
            clearReference.widthAnchor.constraint(equalToConstant: 24),
        ])

        // Inline live-video bar: tap to expand the fullscreen call screen.
        videoBar.translatesAutoresizingMaskIntoConstraints = false
        videoBar.backgroundColor = .secondarySystemBackground
        videoBar.isUserInteractionEnabled = true
        let videoImage = UIImageView()
        videoImage.translatesAutoresizingMaskIntoConstraints = false
        videoImage.contentMode = .scaleAspectFit
        videoImage.clipsToBounds = true
        videoBar.addSubview(videoImage)
        inlineVideoImage = videoImage
        let expand = UIButton(type: .system)
        expand.translatesAutoresizingMaskIntoConstraints = false
        expand.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
        expand.tintColor = .white
        expand.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        expand.layer.cornerRadius = 16
        expand.addTarget(self, action: #selector(expandVideoTapped), for: .touchUpInside)
        videoBar.addSubview(expand)
        videoBar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(expandVideoTapped)))
        videoBar.isHidden = true
        videoBarHeight = videoBar.heightAnchor.constraint(equalToConstant: 0)

        view.addSubview(videoBar)
        view.addSubview(tableView)
        view.addSubview(jumpButton)
        view.addSubview(callStatusLabel)
        view.addSubview(waveformView)
        view.addSubview(referenceChip)
        view.addSubview(composerBar)
        composerBar.addSubview(composerText)
        composerBar.addSubview(attachButton)
        composerBar.addSubview(micButton)
        composerBar.addSubview(sendButton)
        composerBar.addSubview(elapsedLabel)
        composerBar.addSubview(stopButton)
        composerBar.addSubview(closeButton)
        composerBar.addSubview(playButton)
        composerBar.addSubview(reviewWaveform)

        composerHeight = composerText.heightAnchor.constraint(equalToConstant: 44)
        referenceChipHeight = referenceChip.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            jumpButton.trailingAnchor.constraint(equalTo: tableView.trailingAnchor, constant: -16),
            jumpButton.bottomAnchor.constraint(equalTo: tableView.bottomAnchor, constant: -16),
            jumpButton.widthAnchor.constraint(equalToConstant: 44),
            jumpButton.heightAnchor.constraint(equalToConstant: 44),

            videoBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            videoBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoBarHeight,
            videoImage.topAnchor.constraint(equalTo: videoBar.topAnchor, constant: 4),
            videoImage.bottomAnchor.constraint(equalTo: videoBar.bottomAnchor, constant: -4),
            videoImage.leadingAnchor.constraint(equalTo: videoBar.leadingAnchor, constant: 4),
            videoImage.trailingAnchor.constraint(equalTo: videoBar.trailingAnchor, constant: -4),
            expand.topAnchor.constraint(equalTo: videoBar.topAnchor, constant: 8),
            expand.trailingAnchor.constraint(equalTo: videoBar.trailingAnchor, constant: -8),
            expand.widthAnchor.constraint(equalToConstant: 32),
            expand.heightAnchor.constraint(equalToConstant: 32),

            tableView.topAnchor.constraint(equalTo: videoBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: waveformView.topAnchor),

            waveformView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            waveformView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            waveformView.bottomAnchor.constraint(equalTo: referenceChip.topAnchor, constant: -8),
            waveformHeight,

            referenceChip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            referenceChip.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            referenceChip.bottomAnchor.constraint(equalTo: composerBar.topAnchor, constant: -6),
            referenceChipHeight,

            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            composerBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),

            composerText.topAnchor.constraint(equalTo: composerBar.topAnchor),
            composerText.bottomAnchor.constraint(equalTo: composerBar.bottomAnchor),
            composerText.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 6),
            composerText.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            composerHeight,

            attachButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            attachButton.leadingAnchor.constraint(equalTo: composerBar.leadingAnchor, constant: 8),
            attachButton.widthAnchor.constraint(equalToConstant: 44),
            attachButton.heightAnchor.constraint(equalToConstant: 44),

            // Mic and send share one trailing slot: they are mutually exclusive
            // (mic while the field is empty, send once it has text), so both pin
            // to the same edge instead of stacking on top of each other.
            micButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            micButton.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor, constant: -8),
            micButton.widthAnchor.constraint(equalToConstant: 44),
            micButton.heightAnchor.constraint(equalToConstant: 44),

            sendButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            sendButton.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor, constant: -8),
            sendButton.widthAnchor.constraint(equalToConstant: 44),
            sendButton.heightAnchor.constraint(equalToConstant: 44),

            elapsedLabel.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            elapsedLabel.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor, constant: -64),

            stopButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor, constant: -16),
            stopButton.widthAnchor.constraint(equalToConstant: 36),
            stopButton.heightAnchor.constraint(equalToConstant: 36),

            closeButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: composerBar.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            playButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            playButton.leadingAnchor.constraint(equalTo: composerBar.leadingAnchor, constant: 60),
            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),

            reviewWaveform.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            reviewWaveform.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 12),
            reviewWaveform.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor, constant: -100),
            reviewWaveform.heightAnchor.constraint(equalToConstant: 32),
        ])
        applyMode()
    }

    // MARK: - Composer modes (normal / recording / review)

    private func applyMode() {
        let recording = mode == .recording
        let review = mode == .review
        let composing = !recording && !review
        composerText.isHidden = !composing
        attachButton.isHidden = !composing
        // Mic and send share one slot: show exactly one (mic on an empty field,
        // send once there is text). Without this both were visible on load and
        // drew on top of each other.
        let hasText = !composerText.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isHidden = !composing || !hasText
        micButton.isHidden = !composing || hasText
        [elapsedLabel, stopButton].forEach { $0.isHidden = !recording }
        elapsedLabel.isHidden = !recording && !review
        [closeButton, playButton, reviewWaveform].forEach { $0.isHidden = !review }
        composerBar.backgroundColor = recording ? .systemRed.withAlphaComponent(0.08) : .secondarySystemBackground
        if recording { waveformView.style = .recording; waveformView.startLive() }
    }

    // MARK: - Text composer

    func textViewDidChange(_ textView: UITextView) {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isHidden = !hasText
        micButton.isHidden = hasText
        let maxHeight: CGFloat = 100
        let target = max(44, min(textView.sizeThatFits(.init(width: textView.frame.width, height: .greatestFiniteMagnitude)).height, maxHeight))
        composerHeight.constant = target
        textView.isScrollEnabled = target >= maxHeight
        view.layoutIfNeeded()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" { sendTapped(); return false }
        return true
    }

    @objc private func sendTapped() {
        guard let text = composerText.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        composerText.text = ""
        textViewDidChange(composerText)
        let peerId = conversation.isRoom ? ChatStore.shared.selfPeerId : peer.id
        // A pending artifact selection turns this turn into a reference.
        let pending = pendingReference
        pendingReference = nil
        updateReferenceChip()
        if let pending {
            let message = MessageReference(text: text, refs: [
                ArtifactRef(artifactId: pending.artifact.artifactId, selector: pending.selector, blobTicket: pending.artifact.blobTicket, note: nil),
            ])
            guard let refEnvelope = ArtifactEnvelope.encodeReference(message) else { return }
            ChatStore.shared.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: peerId, kind: .reference(message), outgoing: true, timestamp: Date(), conversation: conversation.room?.id))
            Task {
                // A cropped region rides as an attachment so the agent gets the
                // pixels; the question lives in the reference envelope.
                var envelope = refEnvelope
                if let preview = pending.preview,
                   let ticket = try? await client.putData(preview, resourceId: "crop-\(UUID().uuidString)") {
                    envelope = "IDFON-DATA/1\nticket=\(ticket)\nsize=\(preview.count)\n" + refEnvelope
                }
                if let agent = OnDeviceAgents.shared.agent(forPeerId: peer.id) {
                    // The local model gets the reference itself: its selector
                    // carries the selected text, so point-and-ask works
                    // without a fetch. A crop ticket would be unreadable to it
                    // (no on-device resolver), so it is not staged here.
                    let ref = ArtifactRef(artifactId: pending.artifact.artifactId,
                                          selector: pending.selector,
                                          blobTicket: pending.artifact.blobTicket,
                                          note: nil)
                    let crop = pending.preview.map {
                        (name: "\(pending.artifact.title) region", png: $0)
                    }
                    await replyLocally(agent: agent, text: text, peerId: peerId,
                                       reference: ref, crop: crop)
                } else if let room = conversation.room {
                    try? await client.sendRoom(room.id, text: envelope)
                } else {
                    try? await client.sendText(to: peer.id, envelope, identity: peer.identity)
                }
            }
            return
        }
        ChatStore.shared.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: peerId, kind: .text(text), outgoing: true, timestamp: Date(), conversation: conversation.room?.id))
        Task {
            if let agent = OnDeviceAgents.shared.agent(forPeerId: peer.id) {
                await replyLocally(agent: agent, text: text, peerId: peerId)
            } else if let room = conversation.room {
                try? await client.sendRoom(room.id, text: text)
            } else {
                try? await client.sendText(to: peer.id, text, identity: peer.identity)
            }
        }
    }

    /// Answer a turn for an on-device agent and record it in the thread.
    private func replyLocally(agent: OnDeviceAgent, text: String, peerId: String,
                              reference: ArtifactRef? = nil, crop: (name: String, png: Data)? = nil) async {
        let spoken: String?
        if let reference {
            spoken = await OnDeviceAgentRunner.shared.reply(
                agent: agent, input: Self.turnInput(text: text, reference: reference, crop: crop))
        } else {
            spoken = await OnDeviceAgentRunner.shared.reply(agent: agent, text: text)
        }
        guard let spoken else { return }
        ChatStore.shared.appendOutgoing(
            ChatMessage(id: UUID().uuidString, peerId: peerId, kind: .text(spoken),
                        outgoing: false, timestamp: Date()))
    }

    /// The director's `TurnInput` JSON for a turn that points at an artifact
    /// (`docs/voice-multimodal.md`): the question in `text`, the reference in
    /// `references`, and — when the selection has pixels — the app's crop as an
    /// image part, so a model that takes images sees what was pointed at rather
    /// than only which region it was.
    private static func turnInput(text: String, reference: ArtifactRef,
                                  crop: (name: String, png: Data)? = nil) -> [String: Any] {
        var input: [String: Any] = ["text": text]
        if let data = try? JSONEncoder().encode(reference),
           let json = try? JSONSerialization.jsonObject(with: data) {
            input["references"] = [json]
        }
        if let crop, let attachment = OnDeviceAttachments.imageAttachment(name: crop.name, png: crop.png) {
            input["attachments"] = [attachment]
        }
        return input
    }

    private func sendConversationText(_ text: String) async throws {
        if let room = conversation.room {
            try await client.sendRoom(room.id, text: text)
        } else {
            try await client.sendText(to: peer.id, text, identity: peer.identity)
        }
    }

    // MARK: - Voice memo

    @objc private func micTapped() {
        VoiceMemo.requestPermission { [weak self] granted in
            guard granted, let self else { return }
            let memo = VoiceMemo()
            do {
                _ = try memo.start()
                self.memo = memo
                memo.onAmplitude = { [weak self] amplitude in
                    self?.waveformView.add(amplitude: amplitude)
                }
                self.mode = .recording
                self.memoStartDate = Date()
                self.memoTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    let elapsed = Date().timeIntervalSince(self?.memoStartDate ?? Date())
                    self?.elapsedLabel.text = Self.format(elapsed)
                }
            } catch {
                idfonError("idfon memo start failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func stopRecordingTapped() {
        guard let result = memo?.stop() else { return }
        memoTimer?.invalidate()
        memoURL = result.url
        memoDuration = result.duration
        memo = nil
        mode = .review
        reviewWaveform.style = .playback
        // Downsample decodes the whole file; keep it off the main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let samples = VoiceMemo.amplitudes(url: result.url)
            await MainActor.run { self.reviewWaveform.setStatic(samples: samples, progress: 0) }
        }
        elapsedLabel.text = Self.format(result.duration)
        elapsedLabel.isHidden = false // duration label doubles as review duration
    }

    @objc private func discardMemoTapped() {
        memo?.discard()
        memo = nil
        if let url = memoURL { try? FileManager.default.removeItem(at: url) }
        memoURL = nil
        reviewPlayer?.stop()
        reviewPlayer = nil
        mode = .normal
    }

    @objc private func playMemoTapped() {
        guard let url = memoURL else { return }
        if reviewPlayer?.isPlaying == true {
            reviewPlayer?.pause()
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
            return
        }
        if reviewPlayer == nil {
            Task { @MainActor in
                let p = try? AVAudioPlayer(contentsOf: url)
                guard reviewPlayer == nil else { return } // replayed while decoding
                reviewPlayer = p
                reviewPlayer?.delegate = self
            }
        }
        reviewPlayer?.play()
        playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
    }

    private func sendMemo() {
        guard let url = memoURL else { return }
        // An app-local agent has no audio path: it cannot hear a memo, and the
        // upload would be sent to a peer that does not exist.
        guard OnDeviceAgents.shared.agent(forPeerId: peer.id) == nil else {
            showCallStatus("\(peer.displayName) is an on-device agent: no voice messages yet")
            return
        }
        // Claim any pending reference now; it rides with the memo.
        let pending = pendingReference
        pendingReference = nil
        updateReferenceChip()
        let durationMs = Int(memoDuration * 1000)
        showCallStatus("Sending voice message…")
        // §4: the upload rides the Session Tray while it's in flight, and its
        // Cancel aborts the chunked put.
        let transferId = UUID().uuidString
        let started = Date()
        TransferCenter.shared.begin(id: transferId, peerId: peer.id, name: "Voice message") { [weak self] in
            self?.memoTask?.cancel()
        }
        memoTask = Task {
            do {
                let data = try Data(contentsOf: url)
                let ticket = try await client.putData(data, resourceId: "memo-\(UUID().uuidString)") { sent, total in
                    let fraction = total > 0 ? Double(sent) / Double(total) : 1
                    let rate = Double(sent) / max(Date().timeIntervalSince(started), 0.001)
                    Task { @MainActor in
                        TransferCenter.shared.update(id: transferId, fraction: fraction, bytesPerSecond: rate)
                    }
                }
                var envelope = """
                IDFON-RECORDING/1
                id=\(UUID().uuidString)
                codec=pcm
                sample_rate=16000
                duration_ms=\(durationMs)
                sender_id=\(ChatStore.shared.selfPeerId)
                ticket=\(ticket)
                """
                var reference: MessageReference?
                if let pending {
                    let message = MessageReference(text: "", refs: [
                        ArtifactRef(artifactId: pending.artifact.artifactId, selector: pending.selector, blobTicket: pending.artifact.blobTicket, note: nil),
                    ])
                    if let refEnvelope = ArtifactEnvelope.encodeReference(message) {
                        envelope += "\n\(refEnvelope)"
                        reference = message
                    }
                }
                try await sendConversationText(envelope)
                let outgoingPeerId = conversation.isRoom ? ChatStore.shared.selfPeerId : peer.id
                ChatStore.shared.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: outgoingPeerId, kind: .recording(ticket: ticket, durationMs: durationMs, localURL: url), outgoing: true, timestamp: Date(), conversation: conversation.room?.id))
                if let reference {
                    ChatStore.shared.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: outgoingPeerId, kind: .reference(reference), outgoing: true, timestamp: Date(), conversation: conversation.room?.id))
                }
                try? FileManager.default.removeItem(at: url)
                TransferCenter.shared.finish(id: transferId)
                self.memoURL = nil
                self.reviewPlayer = nil
                self.mode = .normal
                self.showCallStatus(nil)
            } catch is CancellationError {
                TransferCenter.shared.finish(id: transferId)
                idfonLog("idfon file: memo cancelled")
                self.showCallStatus("Voice message cancelled")
            } catch {
                TransferCenter.shared.finish(id: transferId)
                idfonError("idfon file: memo failed \(error.localizedDescription)")
                self.showCallStatus("Send failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - File send (§5)

    @objc private func attachTapped() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    /// Send a file to an app-local agent: read it as text and inline it into the
    /// turn. Not uploaded and not recorded as a file bubble — there is no peer
    /// to fetch a blob from, and the model cannot resolve one — so the thread
    /// says what was read instead of offering a download that cannot work.
    private func sendFileLocally(agent: OnDeviceAgent, at url: URL, name: String) async {
        let safeName = OnDeviceAttachments.promptName(name)
        guard let content = OnDeviceAttachments.text(at: url) else {
            showCallStatus("\(peer.displayName) can read text files only")
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        showCallStatus("Reading \(safeName)…")
        ChatStore.shared.appendOutgoing(ChatMessage(
            id: UUID().uuidString, peerId: peer.id, kind: .text("📄 \(safeName) (\(sizeText))"),
            outgoing: true, timestamp: Date(), conversation: conversation.room?.id))
        let spoken = await OnDeviceAgentRunner.shared.reply(
            agent: agent,
            input: OnDeviceAttachments.turnInput(
                text: "Attached file (\(size) bytes)", name: safeName, content: content))
        guard let spoken else {
            showCallStatus("\(peer.displayName) did not answer (Apple Intelligence off?)")
            return
        }
        ChatStore.shared.appendOutgoing(
            ChatMessage(id: UUID().uuidString, peerId: peer.id, kind: .text(spoken),
                        outgoing: false, timestamp: Date()))
        idfonLog("idfon file: read locally name=\(safeName) size=\(size)")
        showCallStatus(nil)
    }

    private static let streamableExtensions: Set<String> = ["mp4", "mkv", "mp3", "flac"]

    /// Starts a P2P file transfer (§5 "Send File"): chunked upload + ticket
    /// envelope, tracked in the Session Tray. The blob streams from disk, so
    /// large files never sit in memory.
    private func sendFile(at url: URL, name: String) {
        // An app-local agent has no sandbox and no resolver, so the file is read
        // here and inlined into the turn instead of uploaded.
        if let agent = OnDeviceAgents.shared.agent(forPeerId: peer.id) {
            Task { await sendFileLocally(agent: agent, at: url, name: name) }
            return
        }
        showCallStatus("Sending \(name)…")
        let transferId = UUID().uuidString
        let started = Date()
        TransferCenter.shared.begin(id: transferId, peerId: peer.id, name: name) { [weak self] in
            self?.fileTask?.cancel()
        }
        fileTask = Task {
            do {
                let ticket = try await client.putFile(at: url, resourceId: "file-\(UUID().uuidString)") { sent, total in
                    let fraction = total > 0 ? Double(sent) / Double(total) : 1
                    let rate = Double(sent) / max(Date().timeIntervalSince(started), 0.001)
                    Task { @MainActor in
                        TransferCenter.shared.update(id: transferId, fraction: fraction, bytesPerSecond: rate)
                    }
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                // A newline would split the envelope's key=value lines.
                let safeName = name.replacingOccurrences(of: "\n", with: " ")
                let envelope = """
                IDFON-FILE/1
                id=\(UUID().uuidString)
                name=\(safeName)
                size=\(size)
                sender_id=\(ChatStore.shared.selfPeerId)
                ticket=\(ticket)
                """
                try await sendConversationText(envelope)
                ChatStore.shared.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: conversation.isRoom ? ChatStore.shared.selfPeerId : peer.id, kind: .file(ticket: ticket, name: safeName, sizeBytes: size, localURL: nil), outgoing: true, timestamp: Date(), conversation: conversation.room?.id))
                idfonLog("idfon file: sent name=\(safeName) size=\(size) ticket=\(ticket)")
                TransferCenter.shared.finish(id: transferId)
                self.showCallStatus(nil)
            } catch is CancellationError {
                TransferCenter.shared.finish(id: transferId)
                idfonLog("idfon file: send cancelled name=\(name)")
                self.showCallStatus("Send cancelled")
            } catch {
                TransferCenter.shared.finish(id: transferId)
                idfonError("idfon file: send failed \(error.localizedDescription)")
                self.showCallStatus("Send failed: \(error.localizedDescription)")
            }
        }
    }

    /// Automation entry (Automation.swift): sends through the same path the
    /// attachment picker reaches, so the harness exercises the real wiring.
    func automateSendFile(at url: URL) { sendFile(at: url, name: url.lastPathComponent) }

    /// Row taps: cards drill open in place (§7.4) and content cards run their
    /// one primary action (open / play / fetch) — no accessory buttons and no
    /// row-index tags that go stale while messages stream in.
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        switch timelineItems[indexPath.row] {
        case .thread(let id, _), .bucket(let id, _, _, _):
            if expandedItems.contains(id) {
                expandedItems.remove(id)
            } else {
                expandedItems.insert(id)
            }
            syncMessages()
        case .message(let message):
            switch message.kind {
            case .artifact(let artifact):
                openArtifact(artifact, peerId: message.peerId)
            case .render(let render):
                navigationController?.pushViewController(
                    RenderBlockViewController(title: render.title, spec: render.spec), animated: true)
            case .recording(let ticket, _, let localURL):
                toggleRecording(messageID: message.id, ticket: ticket, localURL: localURL)
            case .file(let ticket, let name, _, let localURL):
                fetchFile(messageID: message.id, ticket: ticket, name: name, localURL: localURL)
            default:
                break
            }
        case .dateline:
            break
        }
    }

    private func reloadRow(for messageID: String) {
        guard let row = timelineItems.firstIndex(where: { $0.id == messageID }) else { return }
        tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
    }

    private func toggleRecording(messageID: String, ticket: String, localURL: URL?) {
        if let player = players[ticket] {
            if player.isPlaying { player.pause() } else { player.play() }
            reloadRow(for: messageID)
            return
        }
        Task {
            do {
                let data: Data
                if let localURL {
                    // Local cache read off the main actor too (this Task
                    // inherits MainActor from the view controller).
                    let cached = await Task.detached(priority: .userInitiated) {
                        try? Data(contentsOf: localURL)
                    }.value
                    if let cached {
                        data = cached
                    } else {
                        data = try await client.fetchBlob(ticket)
                    }
                } else {
                    data = try await client.fetchBlob(ticket)
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(ticket.prefix(12)).wav")
                try data.write(to: url)
                let player = try AVAudioPlayer(contentsOf: url)
                player.play()
                players[ticket] = player
                reloadRow(for: messageID)
            } catch {
                idfonError("idfon recording fetch failed: \(error.localizedDescription)")
            }
        }
    }

    private func openArtifact(_ artifact: Artifact, peerId: String) {
        let detail = ArtifactDetailViewController(artifact: artifact, peerRef: peerId)
        detail.onReference = { [weak self] selector, preview in
            guard let self else { return }
            self.pendingReference = (artifact, selector, preview)
            self.updateReferenceChip()
            self.composerText.becomeFirstResponder()
        }
        present(UINavigationController(rootViewController: detail), animated: true)
    }

    private func updateReferenceChip() {
        guard let pending = pendingReference else {
            referenceChip.isHidden = true
            referenceChipHeight.constant = 0
            return
        }
        referenceChipLabel.text = "\(pending.artifact.title) · \(Self.selectorSummary(pending.selector))"
        referenceChip.isHidden = false
        referenceChipHeight.constant = 34
    }

    @objc private func clearReferenceTapped() {
        pendingReference = nil
        updateReferenceChip()
    }

    private static func selectorSummary(_ selector: ArtifactSelector) -> String {
        switch selector {
        case .whole: return "whole"
        case .text(_, _, let quote): return quote.map { "“\($0.prefix(24))”" } ?? "text"
        case .region: return "region"
        case .timeRange: return "time range"
        case .jsonPointer(let pointer): return pointer
        case .element(let path): return path
        }
    }

    /// Fetch-on-demand for a received file, then offer it. Deliberately not part
    /// of ingest: a large file isn't pulled down until the recipient asks.
    private func fetchFile(messageID: String, ticket: String, name: String, localURL: URL?) {
        if let localURL {
            share(url: localURL, source: tableView)
            return
        }
        Task {
            do {
                let data = try await client.fetchBlob(ticket)
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Downloads", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // The sender's name is untrusted input: never let it escape
                // the Downloads directory.
                let url = dir.appendingPathComponent((name as NSString).lastPathComponent)
                try data.write(to: url)
                ChatStore.shared.attachFile(at: url, to: messageID)
                self.share(url: url, source: self.tableView)
            } catch {
                idfonError("idfon file: download failed \(error.localizedDescription)")
                self.showCallStatus("Download failed: \(error.localizedDescription)")
            }
        }
    }

    private func share(url: URL, source: UIView) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = source
        activity.popoverPresentationController?.sourceRect = source.bounds
        present(activity, animated: true)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Live call

    private func showCallStatus(_ text: String?) {
        DispatchQueue.main.async {
            self.callStatusLabel.text = text
            self.callStatusLabel.isHidden = text == nil
            let showWave = text != nil && self.mode == .normal
            self.waveformHeight.constant = showWave ? 48 : 0
            self.waveformView.isHidden = !showWave
            if showWave { self.audioMeter.start() } else { self.audioMeter.stop() }
        }
    }

    // MARK: - Inline live-video bar (hybrid: inline by default, tap expands)

    private func syncVideoBar() {
        let call = VideoCall.shared
        let active = call.state == .inCall || call.state == .calling
        videoBar.isHidden = !active
        videoBarHeight.constant = active ? 180 : 0
        if !active { inlineVideoImage?.image = nil }
        view.layoutIfNeeded()
    }

    @objc private func expandVideoTapped() {
        guard presentedViewController == nil else { return }
        present(CallViewController(), animated: true)
    }

    /// Start/stop the on-device (client-cascade) voice call. The shared call
    /// Bar shows the state and owns End/mute, so there is no nav-bar control.
    @objc private func voiceAgentTapped() {
        guard let peerId = conversation.peer?.id else { return }
        let session = VoiceAgentSession.shared
        if session.isActive {
            session.stop()
        } else {
            // Same call cues as a live call: ringback while the recognizer
            // loads, answered once it is listening, stop on hangup. Configure
            // the session first so the tone engine starts on the speaker route.
            session.start(peerRef: peerId)
            CallTonePlayer.shared.start(.ringback)
        }
    }

    /// Call entry (Bar's idle chrome). Routes by the ticket's voice mode:
    /// client-cascade starts the on-device voice call, which uses the same
    /// call Bar/End UI as a live call.
    func startCall() {
        // On-device agents run entirely in-app: no dial, no peer, no network.
        if let agent = OnDeviceAgents.shared.agent(forPeerId: peer.id) {
            VoiceAgentSession.shared.runOnDevice(agent: agent)
            return
        }
        // The per-contact STT/TTS selection (option ids from the agent's
        // `idfon.json` catalog) rides the invite; the holder resolves it. The
        // catalog is a fetched resource, cached after the contact screen.
        let peerID = peer.id
        let client = self.client
        let legacyRemote = peer.name == "live-voice"
            || ContactAudioProfiles.profile(for: peerID) == .pcm24k
        let signed = CapabilityTickets.voiceRoute(for: peerID)
        let holderTicket = CapabilityTickets.hasTicket(for: peerID)
        let selection = ContactVoiceSelection.selection(for: peerID)
        let onDevice = (stt: ContactOnDeviceEngines.asr(for: peerID),
                        tts: ContactOnDeviceEngines.tts(for: peerID))
        Task { @MainActor in
            let catalog = await VoiceCatalog.options(for: peerID, client: client)
            let decision = VoiceCallRouting.decide(
                selection: selection, onDevice: onDevice, catalog: catalog, signed: signed,
                holderTicket: holderTicket, legacyRemote: legacyRemote)
            self.perform(decision)
        }
    }

    private func perform(_ decision: VoiceCallDecision) {
        switch decision {
        case .onDevice:
            voiceAgentTapped()
        case .delegated(let route):
            dialDelegate(route)
        case .live(let route):
            dialLive(route)
        case .classic:
            VideoCall.shared.dial(peer.id, audio: true, video: true, cameraOn: false)
        }
    }

    /// Calls go to the delegate voice agent; text stays on this peer.
    private func dialDelegate(_ route: VoiceRoute) {
        guard let delegate = route.delegatePeerId else {
            voiceAgentTapped()
            return
        }
        if let contact = route.delegateContact {
            // Add the delegate from the signed contact (once), then dial.
            let client = self.client
            let ticket = route.delegateTicket
            Task { @MainActor in
                let identity = (try? await client.identityId()) ?? "default"
                let peers = (try? await client.peers()) ?? []
                if !peers.contains(where: { $0.id == delegate }) {
                    try? await client.addChannel(name: delegate, ticketJSON: contact, identity: identity)
                    if let ticket { _ = CapabilityTickets.store(ticket, for: delegate) }
                }
                LiveCall.shared.dial(delegate)
            }
        } else {
            LiveCall.shared.dial(delegate)
        }
    }

    /// The holder terminates audio. Its `voice.audio` codec decides between the
    /// live PCM media session (optionally hybrid) and the ordinary audio call.
    /// `route` is nil for a legacy ticket dialed on the name/profile heuristic.
    private func dialLive(_ route: VoiceRoute?) {
        let pcm = route?.audio == "pcm24k"
            || (route?.audio == nil && ContactAudioProfiles.profile(for: peer.id) == .pcm24k)
        guard pcm else {
            VideoCall.shared.dial(peer.id, audio: true, video: true, cameraOn: false)
            return
        }
        if let route, route.isHybrid {
            HybridVoice.shared.start(peerRef: peer.id, route: route)
        } else {
            LiveCall.shared.dial(peer.id)
        }
    }

    /// Automation entry (`idfon://dial` + the `idfon.dial` notification): the
    /// daemon-side WAV harness, not the real audio state machine.
    private func dial(peerRef: String) {
        idfonLog("idfon dial: \(peerRef)")
        showCallStatus("Calling…")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await LiveCallHarness.dial(peer: peerRef, seconds: 8, client: self.client)
                self.showCallStatus("Call ended")
            } catch {
                self.showCallStatus("Call failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.showCallStatus(nil) }
        }
    }

    @objc private func copyInviteTapped() {
        guard let room = conversation.room else { return }
        UIPasteboard.general.string = room.id
        let alert = UIAlertController(title: "Invite copied", message: "Share this room id with a member: \(room.id)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func leaveTapped() {
        guard let room = conversation.room else { return }
        let alert = UIAlertController(title: "Leave room?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in
            Task {
                try? await self?.client.leaveRoom(room.id)
                _ = await MainActor.run { self?.navigationController?.popViewController(animated: true) }
            }
        })
        present(alert, animated: true)
    }

    // MARK: - Table view (§7.3 timeline)

    private struct ScrollAnchor { let id: String; let offset: CGFloat }

    /// Re-derive the timeline and reload without losing the reader's place
    /// (§7.3b): anchor the top visible row across regrouping and prepends, and
    /// never auto-scroll a reader who has scrolled up — the jump button shows.
    private func syncMessages() {
        let atBottom = isNearBottom()
        let anchor = atBottom ? nil : scrollAnchor()
        messages = ChatStore.shared.messages(for: conversation)
        timelineItems = Timeline.items(for: messages, expanding: expandedItems)
        tableView.reloadData()
        if atBottom {
            scrollToLatest(animated: false)
        } else {
            if let anchor { restore(anchor) }
            jumpButton.isHidden = false
        }
    }

    private func isNearBottom() -> Bool {
        guard tableView.contentSize.height > 0 else { return true }
        let bottom = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom
        return tableView.contentSize.height - bottom < 80
    }

    private func scrollAnchor() -> ScrollAnchor? {
        guard let row = tableView.indexPathsForVisibleRows?.first?.row,
              timelineItems.indices.contains(row) else { return nil }
        let top = tableView.rectForRow(at: IndexPath(row: row, section: 0)).minY
        return ScrollAnchor(id: timelineItems[row].id, offset: top - tableView.contentOffset.y)
    }

    private func restore(_ anchor: ScrollAnchor) {
        guard let row = timelineItems.firstIndex(where: { $0.id == anchor.id }) else { return }
        let top = tableView.rectForRow(at: IndexPath(row: row, section: 0)).minY - anchor.offset
        tableView.contentOffset.y = max(-tableView.adjustedContentInset.top, top)
    }

    private func scrollToLatest(animated: Bool) {
        guard !timelineItems.isEmpty else { return }
        tableView.scrollToRow(at: IndexPath(row: timelineItems.count - 1, section: 0), at: .bottom, animated: animated)
        jumpButton.isHidden = true
    }

    /// §7.3b: re-derive first (grouping may have shifted while the reader was
    /// up in history — D17), then land on the bottom.
    @objc private func jumpToLatestTapped() {
        syncMessages()
        scrollToLatest(animated: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        jumpButton.isHidden = isNearBottom()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        timelineItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch timelineItems[indexPath.row] {
        case .message(let message):
            return messageCell(for: message, at: indexPath)
        case .dateline(_, let text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "dateline", for: indexPath) as! DatelineCell
            cell.label.text = text
            return cell
        case .thread(let id, let thread):
            let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath) as! TimelineCardCell
            let duration = (thread.last?.timestamp ?? Date()).timeIntervalSince(thread.first?.timestamp ?? Date())
            cell.configure(edge: .colored(.systemBlue), glyph: "bubble.left.and.bubble.right",
                           title: "Thread · \(thread.count) messages · \(Self.durationText(duration))",
                           subtitle: threadPreview(thread),
                           placement: .centered, expanded: expandedItems.contains(id))
            return cell
        case .bucket(let id, let label, let summary, _):
            let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath) as! TimelineCardCell
            cell.configure(edge: .dashed, glyph: nil, title: label, subtitle: summary,
                           placement: .fullWidth, expanded: expandedItems.contains(id))
            return cell
        }
    }

    /// D11: bubbles carry the simple messages (typed / spoken / reference);
    /// anything that is really an artifact (file, voice memo, artifact, render
    /// block) renders as a side-aligned card with its kind glyph (§7.2a).
    private func messageCell(for message: ChatMessage, at indexPath: IndexPath) -> UITableViewCell {
        switch message.kind {
        case .text(let text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath) as! MessageCell
            cell.setSender(senderHeader(for: message))
            cell.messageLabel.text = text
            cell.captionLabel.text = caption(message.outgoing ? "typed · sent" : "typed", for: message)
            cell.setAlignment(outgoing: side(for: message))
            return cell
        case .callTranscript(let transcript):
            let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath) as! MessageCell
            cell.setSender(senderHeader(for: message))
            cell.messageLabel.text = transcript.text
            cell.captionLabel.text = caption(
                "\(transcript.role == "agent" ? "Agent" : "You") · \(transcript.final ? "spoken" : "speaking…")",
                for: message)
            cell.setAlignment(outgoing: side(for: message))
            return cell
        case .reference(let reference):
            let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath) as! MessageCell
            cell.setSender(senderHeader(for: message))
            cell.messageLabel.text = reference.text.isEmpty ? "Asked about an artifact" : reference.text
            cell.captionLabel.text = caption(
                "\(reference.refs.count) reference\(reference.refs.count == 1 ? "" : "s")", for: message)
            cell.setAlignment(outgoing: side(for: message))
            return cell
        case .recording(let ticket, let durationMs, _):
            let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath) as! TimelineCardCell
            cell.configure(edge: .colored(.systemGreen),
                           glyph: players[ticket]?.isPlaying == true ? "pause.fill" : "play.fill",
                           title: "Voice message",
                           subtitle: Self.format(Double(durationMs) / 1000),
                           placement: .side(outgoing: side(for: message)), expanded: false, showsDisclosure: false)
            return cell
        case .file(_, let name, let sizeBytes, _):
            let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath) as! TimelineCardCell
            cell.configure(edge: .colored(.systemGreen), glyph: "doc", title: name,
                           subtitle: ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file),
                           placement: .side(outgoing: side(for: message)), expanded: false, showsDisclosure: false)
            return cell
        case .artifact(let artifact):
            let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath) as! TimelineCardCell
            cell.configure(edge: .colored(.systemGreen), glyph: artifact.kind.glyph, title: artifact.title,
                           subtitle: "Artifact · \(artifact.kind.rawValue)",
                           placement: .side(outgoing: side(for: message)), expanded: false, showsDisclosure: false)
            return cell
        case .render(let render):
            let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath) as! TimelineCardCell
            cell.configure(edge: .colored(.systemGreen), glyph: "rectangle.grid.1x2",
                           title: render.title ?? "View", subtitle: render.spec.summary(),
                           placement: .side(outgoing: side(for: message)), expanded: false, showsDisclosure: false)
            return cell
        }
    }

    /// D11: alignment shows the side, not the sender — ours right, theirs left.
    private func side(for message: ChatMessage) -> Bool {
        if case .callTranscript(let transcript) = message.kind { return transcript.role != "agent" }
        return message.outgoing
    }

    /// Sender header only where a side holds multiple identities (§7.2a).
    private func senderHeader(for message: ChatMessage) -> String? {
        guard conversation.isRoom, !message.outgoing else { return nil }
        return senderNames[message.peerId] ?? String(message.peerId.prefix(8))
    }

    /// D11 detail level: provenance caption + timestamp inside the bubble.
    private func caption(_ text: String, for message: ChatMessage) -> String {
        "\(message.timestamp.formatted(date: .omitted, time: .shortened)) · \(text)"
    }

    /// Thread card preview: the burst's last line, sender-prefixed in rooms.
    private func threadPreview(_ thread: [ChatMessage]) -> String? {
        guard let last = thread.last else { return nil }
        if conversation.isRoom {
            let name = senderNames[last.peerId] ?? String(last.peerId.prefix(2)).uppercased()
            return "\(name): \(last.displayText)"
        }
        return last.displayText
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        seconds < 3600 ? "\(max(1, Int(seconds / 60)))m" : format(seconds)
    }

}

/// §5 intent routing: non-streamable files bypass the modal; streamable media
/// prompts Stream-vs-Send (the Stream branch isn't built yet, so its action is
/// present but disabled).
extension ChatViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let name = (url.lastPathComponent as NSString).lastPathComponent
        guard Self.streamableExtensions.contains(url.pathExtension.lowercased()) else {
            sendFile(at: url, name: name)
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let alert = UIAlertController(
            title: "Handle Large Media",
            message: "\(name) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))",
            preferredStyle: .actionSheet)
        let stream = UIAlertAction(title: "Stream Content", style: .default) { _ in }
        stream.isEnabled = false // §5 stream branch: not built yet
        alert.addAction(stream)
        alert.addAction(UIAlertAction(title: "Send File", style: .default) { [weak self] _ in
            self?.sendFile(at: url, name: name)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = attachButton
        alert.popoverPresentationController?.sourceRect = attachButton.bounds
        present(alert, animated: true)
    }
}

extension ChatViewController: ChatStoreObserver {
    func chatStoreDidUpdate() { syncMessages() }
}

extension ChatViewController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        reviewWaveform.setProgress(0)
    }
}
