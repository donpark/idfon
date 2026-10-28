import UIKit

/// Full-screen remote-video view for a 1:1 camera call. The video frame is
/// decoded video frames supplied by Idfon's current media bridge, rendered as
/// a UIImage — no pixels cross the FFI, mirroring the macOS GUI.
final class CallViewController: UIViewController {
    private let videoView = UIImageView()
    private let statusLabel = UILabel()
    private let hangUpButton = UIButton(type: .system)
    private let answerButton = UIButton(type: .system)
    private let declineButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)
    private let checkButton = UIButton(type: .system)
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
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        collapseButton.tintColor = .white
        collapseButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        collapseButton.layer.cornerRadius = 20
        collapseButton.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)
        checkButton.translatesAutoresizingMaskIntoConstraints = false
        checkButton.setImage(UIImage(systemName: "waveform.path.ecg"), for: .normal)
        checkButton.tintColor = .white
        checkButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        checkButton.layer.cornerRadius = 20
        checkButton.addTarget(self, action: #selector(healthCheckTapped), for: .touchUpInside)
        hangUpButton.addTarget(self, action: #selector(hangUpTapped), for: .touchUpInside)
        answerButton.addTarget(self, action: #selector(answerTapped), for: .touchUpInside)
        declineButton.addTarget(self, action: #selector(declineTapped), for: .touchUpInside)

        view.addSubview(videoView)
        view.addSubview(statusLabel)
        view.addSubview(hangUpButton)
        view.addSubview(answerButton)
        view.addSubview(declineButton)
        view.addSubview(collapseButton)
        view.addSubview(checkButton)

        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            checkButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            checkButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            checkButton.widthAnchor.constraint(equalToConstant: 40),
            checkButton.heightAnchor.constraint(equalToConstant: 40),

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

            collapseButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            collapseButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            collapseButton.widthAnchor.constraint(equalToConstant: 40),
            collapseButton.heightAnchor.constraint(equalToConstant: 40),
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
        // Collapse back to the inline chat view while calling/in call.
        collapseButton.isHidden = !(call.state == .calling || call.state == .inCall)
        if call.state == .idle, let error = call.lastError, !error.isEmpty {
            statusLabel.text = error
        }
    }

    @objc private func hangUpTapped() { VideoCall.shared.hangUp() }

    /// Connection health check (docs/media-adaptation.md §B2.2): a sheet with
    /// check progress, then the actions the measurements imply.
    @objc private func healthCheckTapped() {
        let progress = UIAlertController(
            title: "Connection check",
            message: "Sampling both ends of the call…",
            preferredStyle: .alert
        )
        progress.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(progress, animated: true)
        HealthCheck.shared.run(peerTicket: VideoCall.shared.joinedTicket) { [weak self] event in
            guard case .done(let report) = event else { return }
            progress.dismiss(animated: true) {
                self?.presentHealthReport(report)
            }
        }
    }

    private func presentHealthReport(_ report: HealthCheck.Report) {
        var message = "Local: loss \(String(format: "%.1f", report.local.lossPctMean))%, rtt \(report.local.rttMsMin)–\(report.local.rttMsMax) ms"
        if let remote = report.remote {
            message += "\nRemote: loss \(String(format: "%.1f", remote.lossPctMean))%, rtt \(remote.rttMsMin)–\(remote.rttMsMax) ms"
        }
        for tip in report.tips {
            message += "\n• \(tip.reason)"
        }
        let alert = UIAlertController(
            title: "Connection: \(report.verdict.capitalized)",
            message: message,
            preferredStyle: .actionSheet
        )
        for tip in report.tips {
            switch tip.action {
            case "turn_off_video":
                alert.addAction(UIAlertAction(title: "Turn off video", style: .default) { _ in
                    VideoCall.shared.setVideoEnabled(false)
                })
            case "turn_off_stereo":
                alert.addAction(UIAlertAction(title: "Switch to mono", style: .default) { _ in
                    VideoCall.shared.setStereo(false)
                })
            default:
                break
            }
        }
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
    }
    @objc private func answerTapped() { VideoCall.shared.answer() }
    @objc private func declineTapped() { VideoCall.shared.decline() }
    /// Collapse to the inline chat video bar; the call keeps running.
    @objc private func collapseTapped() { dismiss(animated: true) }
}
