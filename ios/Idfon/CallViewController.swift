import UIKit

/// Full-screen remote-video view for a 1:1 camera call. The video frame is
/// a polled JPEG (video-frame.jpg rewritten by the FFI ~15fps) rendered as
/// a UIImage — no pixels cross the FFI, mirroring the macOS GUI.
final class CallViewController: UIViewController {
    private let videoView = UIImageView()
    private let statusLabel = UILabel()
    private let hangUpButton = UIButton(type: .system)
    private let answerButton = UIButton(type: .system)
    private let declineButton = UIButton(type: .system)
    private var observers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        modalPresentationStyle = .fullScreen

        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.contentMode = .scaleAspectFit
        videoView.backgroundColor = .black

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .title3)

        func round(_ button: UIButton, _ systemName: String, _ color: UIColor) {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setImage(UIImage(systemName: systemName), for: .normal)
            button.tintColor = .white
            button.backgroundColor = color
            button.layer.cornerRadius = 32
        }
        round(hangUpButton, "phone.down.fill", .systemRed)
        round(answerButton, "phone.fill", .systemGreen)
        round(declineButton, "phone.down.fill", .systemRed)
        hangUpButton.addTarget(self, action: #selector(hangUpTapped), for: .touchUpInside)
        answerButton.addTarget(self, action: #selector(answerTapped), for: .touchUpInside)
        declineButton.addTarget(self, action: #selector(declineTapped), for: .touchUpInside)

        view.addSubview(videoView)
        view.addSubview(statusLabel)
        view.addSubview(hangUpButton)
        view.addSubview(answerButton)
        view.addSubview(declineButton)

        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            hangUpButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            answerButton.trailingAnchor.constraint(equalTo: view.centerXAnchor, constant: -44),
            declineButton.leadingAnchor.constraint(equalTo: view.centerXAnchor, constant: 44),
            hangUpButton.widthAnchor.constraint(equalToConstant: 64),
            hangUpButton.heightAnchor.constraint(equalToConstant: 64),
            answerButton.widthAnchor.constraint(equalToConstant: 64),
            answerButton.heightAnchor.constraint(equalToConstant: 64),
            declineButton.widthAnchor.constraint(equalToConstant: 64),
            declineButton.heightAnchor.constraint(equalToConstant: 64),
            hangUpButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            answerButton.bottomAnchor.constraint(equalTo: hangUpButton.bottomAnchor),
            declineButton.bottomAnchor.constraint(equalTo: hangUpButton.bottomAnchor),
        ])

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .idfonVideoChanged, object: nil, queue: .main) { [weak self] _ in self?.sync() })
        observers.append(center.addObserver(forName: .idfonVideoFrame, object: nil, queue: .main) { [weak self] note in
            self?.videoView.image = note.object as? UIImage
        })
        sync()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func sync() {
        let call = VideoCall.shared
        switch call.state {
        case .idle:
            dismiss(animated: true)
        case .calling:
            statusLabel.text = "Calling…"
            videoView.isHidden = true
        case .incoming:
            statusLabel.text = "Incoming video call"
            videoView.isHidden = true
        case .inCall:
            statusLabel.text = "In video call"
            videoView.isHidden = false
        }
        hangUpButton.isHidden = call.state == .incoming || call.state == .idle
        answerButton.isHidden = call.state != .incoming
        declineButton.isHidden = call.state != .incoming
        if call.state == .idle, let error = call.lastError, !error.isEmpty {
            statusLabel.text = error
        }
    }

    @objc private func hangUpTapped() { VideoCall.shared.hangUp() }
    @objc private func answerTapped() { VideoCall.shared.answer() }
    @objc private func declineTapped() { VideoCall.shared.decline() }
}
