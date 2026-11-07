import UIKit

extension Notification.Name {
    /// The audio call machine changed. `LiveCall.onState` is a single-consumer
    /// hook (the Bar), so screens that merely reflect a call observe this.
    static let idfonLiveCallState = Notification.Name("idfon.live.call.state")
}

/// One playable menu entry as its own screen (`docs/live-radio.md` "Menu
/// contact"): the station list pushes this while the call starts playing it,
/// and Back returns to the list. Playback belongs to the one call machine and
/// its Bar (hang-up is the off switch); this screen only reflects it.
final class StationDetailViewController: UIViewController {
    private let entry: MenuEntry
    private let peerID: String
    private let show: String
    private let status = UILabel()
    private let control = UIButton(type: .system)

    init(entry: MenuEntry, peerID: String, show: String) {
        self.entry = entry
        self.peerID = peerID
        self.show = show
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("StationDetailViewController is built in code") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = entry.title

        let icon = UIImageView(image: UIImage(systemName: "dot.radiowaves.left.and.right"))
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let name = UILabel()
        name.text = entry.title
        name.font = .preferredFont(forTextStyle: .title2)
        name.numberOfLines = 0
        name.textAlignment = .center

        let source = UILabel()
        source.text = entry.source
        source.font = .preferredFont(forTextStyle: .footnote)
        source.textColor = .secondaryLabel
        source.numberOfLines = 0
        source.lineBreakMode = .byTruncatingMiddle
        source.textAlignment = .center

        status.font = .preferredFont(forTextStyle: .subheadline)
        status.textAlignment = .center

        control.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        control.addTarget(self, action: #selector(controlTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, name, source, status, control])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: .idfonLiveCallState, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: .idfonLiveCallState, object: nil)
    }

    /// Playing exactly while the one call machine is on this station's peer.
    @objc private func refresh() {
        switch LiveCall.shared.state {
        case .calling(let peer) where peer == peerID:
            status.text = "Tuning…"
            status.textColor = .secondaryLabel
            control.setTitle("Stop", for: .normal)
        case .inCall(let peer) where peer == peerID:
            status.text = "Playing"
            status.textColor = .systemGreen
            control.setTitle("Stop", for: .normal)
        default:
            status.text = "Not playing"
            status.textColor = .secondaryLabel
            control.setTitle("Play", for: .normal)
        }
    }

    /// The station owns its off switch; the call Bar is a secondary surface.
    @objc private func controlTapped() {
        if case .inCall(let peer) = LiveCall.shared.state, peer == peerID {
            LiveCall.shared.hangUp()
        } else if case .calling(let peer) = LiveCall.shared.state, peer == peerID {
            LiveCall.shared.hangUp()
        } else if case .idle = LiveCall.shared.state {
            LiveCall.shared.dial(peerID, show: show)
        }
    }
}
