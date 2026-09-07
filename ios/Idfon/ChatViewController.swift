import UIKit
import AVFAudio

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {
    private let peer: Peer
    private let client = DaemonClient()

    private let tableView = UITableView()
    private let composerBar = UIView()
    private let composerText = UITextView()
    private let micButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let callStatusLabel = UILabel()
    private let waveformView = LiveWaveformView(frame: .zero)
    private var waveformHeight: NSLayoutConstraint!
    private var audioMeter: AudioMeter!
    private var composerHeight: NSLayoutConstraint!

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

    private var autoAnswerArmed = false
    private var messages: [ChatMessage] = []
    private var players: [String: AVAudioPlayer] = [:] // ticket -> player

    init(peer: Peer) {
        self.peer = peer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = peer.displayName
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "phone"), style: .plain, target: self, action: #selector(dialTapped)),
            UIBarButtonItem(image: UIImage(systemName: "phone.badge.waveform"), style: .plain, target: self, action: #selector(toggleAutoAnswer)),
        ]

        buildViews()
        ChatStore.shared.onUpdate = { [weak self] in self?.syncMessages() }
        syncMessages()

        NotificationCenter.default.addObserver(forName: .init("idfon.dial"), object: nil, queue: .main) { [weak self] note in
            guard let ref = note.userInfo?["ref"] as? String else { return }
            self?.dial(peerRef: ref)
        }
        NotificationCenter.default.addObserver(forName: .init("idfon.answer"), object: nil, queue: .main) { [weak self] _ in
            self?.toggleAutoAnswer()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ChatStore.shared.onUpdate = nil
    }

    // MARK: - Views

    private func buildViews() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "message")
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive

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

        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.setImage(UIImage(systemName: "waveform"), for: .normal)
        micButton.tintColor = .secondaryLabel
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

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
        stopButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        stopButton.tintColor = .systemRed
        stopButton.addTarget(self, action: #selector(stopRecordingTapped), for: .touchUpInside)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.addTarget(self, action: #selector(discardMemoTapped), for: .touchUpInside)

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.addTarget(self, action: #selector(playMemoTapped), for: .touchUpInside)

        reviewWaveform.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(callStatusLabel)
        view.addSubview(waveformView)
        view.addSubview(composerBar)
        composerBar.addSubview(composerText)
        composerBar.addSubview(micButton)
        composerBar.addSubview(sendButton)
        composerBar.addSubview(elapsedLabel)
        composerBar.addSubview(stopButton)
        composerBar.addSubview(closeButton)
        composerBar.addSubview(playButton)
        composerBar.addSubview(reviewWaveform)

        composerHeight = composerText.heightAnchor.constraint(equalToConstant: 40)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: waveformView.topAnchor),

            waveformView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            waveformView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            waveformView.bottomAnchor.constraint(equalTo: composerBar.topAnchor, constant: -8),
            waveformHeight,

            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            composerBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),

            composerText.topAnchor.constraint(equalTo: composerBar.topAnchor),
            composerText.bottomAnchor.constraint(equalTo: composerBar.bottomAnchor),
            composerText.leadingAnchor.constraint(equalTo: composerBar.leadingAnchor, constant: 10),
            composerHeight,

            micButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            micButton.leadingAnchor.constraint(equalTo: composerText.trailingAnchor),
            micButton.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor, constant: -14),
            micButton.widthAnchor.constraint(equalToConstant: 28),

            sendButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            sendButton.leadingAnchor.constraint(equalTo: composerText.trailingAnchor),
            sendButton.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor, constant: -10),

            elapsedLabel.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            elapsedLabel.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor, constant: -64),

            stopButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor, constant: -16),

            closeButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: composerBar.leadingAnchor, constant: 16),

            playButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            playButton.leadingAnchor.constraint(equalTo: composerBar.leadingAnchor, constant: 56),

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
        [composerText, micButton, sendButton].forEach { $0.isHidden = recording || review }
        [elapsedLabel, stopButton].forEach { $0.isHidden = !recording }
        elapsedLabel.isHidden = !recording && !review
        [closeButton, playButton, reviewWaveform].forEach { $0.isHidden = !review }
        composerBar.backgroundColor = recording ? .systemRed.withAlphaComponent(0.08) : .secondarySystemBackground
        if recording { waveformView.style = .recording; waveformView.startLive() }
    }

    // MARK: - Text composer

    func textViewDidChange(_ textView: UITextView) {
        sendButton.isHidden = textView.text.isEmpty
        micButton.isHidden = !textView.text.isEmpty
        let maxHeight: CGFloat = 100
        let target = min(textView.sizeThatFits(.init(width: textView.frame.width, height: .greatestFiniteMagnitude)).height, maxHeight)
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
        ChatStore.shared.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: peer.id, kind: .text(text), outgoing: true))
        Task { try? await client.sendText(to: peer.id, text) }
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
                NSLog("idfon memo start failed: \(error.localizedDescription)")
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
        reviewWaveform.setStatic(samples: VoiceMemo.amplitudes(url: result.url), progress: 0)
        elapsedLabel.text = Self.format(result.duration)
        elapsedLabel.isHidden = false // duration label doubles as review duration
    }

    @objc private func discardMemoTapped() {
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
            reviewPlayer = try? AVAudioPlayer(contentsOf: url)
            reviewPlayer?.delegate = self
        }
        reviewPlayer?.play()
        playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
    }

    private func sendMemo() {
        guard let url = memoURL else { return }
        let durationMs = Int(memoDuration * 1000)
        showCallStatus("Sending voice message…")
        Task {
            do {
                let data = try Data(contentsOf: url)
                let ticket = try await client.putData(data, resourceId: "memo-\(UUID().uuidString)")
                let envelope = """
                IDFON-RECORDING/1
                id=\(UUID().uuidString)
                codec=pcm
                sample_rate=16000
                duration_ms=\(durationMs)
                sender_id=\(ChatStore.shared.selfPeerId)
                ticket=\(ticket)
                """
                try await client.sendText(to: peer.id, envelope)
                ChatStore.shared.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: peer.id, kind: .recording(ticket: ticket, durationMs: durationMs, localURL: url), outgoing: true))
                try? FileManager.default.removeItem(at: url)
                self.memoURL = nil
                self.reviewPlayer = nil
                self.mode = .normal
                self.showCallStatus(nil)
            } catch {
                self.showCallStatus("Send failed: \(error.localizedDescription)")
            }
        }
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

    @objc private func dialTapped() {
        dial(peerRef: peer.id)
    }

    private func dial(peerRef: String) {
        NSLog("idfon dial: \(peerRef)")
        showCallStatus("Calling…")
        Task {
            do {
                try await LiveCall.dial(peer: peerRef, seconds: 8, client: client)
                showCallStatus("Call ended")
            } catch {
                showCallStatus("Call failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.showCallStatus(nil) }
        }
    }

    /// Arms auto-answer: the daemon waits (up to 120s per attempt) for an
    /// incoming dial and records it. Disarming stops re-arming after the
    /// current attempt returns — the blocking request cannot be cancelled.
    @objc private func toggleAutoAnswer() {
        autoAnswerArmed.toggle()
        let armed = autoAnswerArmed
        navigationItem.rightBarButtonItems?.last?.isSelected = armed
        guard armed else { showCallStatus(nil); return }
        showCallStatus("Auto-answer armed…")
        Task {
            while self.autoAnswerArmed {
                do {
                    let out = try await LiveCall.armAutoAnswer(waitSeconds: 120, captureSeconds: 8, client: client)
                    guard self.autoAnswerArmed else { break }
                    self.showCallStatus("Call recorded")
                    NSLog("idfon call recorded to \(out)")
                } catch {
                    guard self.autoAnswerArmed else { break }
                    self.showCallStatus("Answer failed: \(error.localizedDescription)")
                }
            }
            if !self.autoAnswerArmed { self.showCallStatus(nil) }
        }
    }

    // MARK: - Table view

    private func syncMessages() {
        messages = ChatStore.shared.messages.filter { $0.peerId == peer.id }
        tableView.reloadData()
        if !messages.isEmpty {
            tableView.scrollToRow(at: IndexPath(row: messages.count - 1, section: 0), at: .bottom, animated: true)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath)
        let message = messages[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.secondaryText = message.outgoing ? "sent" : nil
        switch message.kind {
        case .text(let text):
            config.text = text
            cell.accessoryView = nil
        case .recording(let ticket, let durationMs, _):
            config.text = "Voice message (\(Self.format(Double(durationMs) / 1000)))"
            config.textProperties.color = .link
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: players[ticket]?.isPlaying == true ? "pause.fill" : "play.fill"), for: .normal)
            button.addTarget(self, action: #selector(playRecordingTapped(_:)), for: .touchUpInside)
            button.tag = indexPath.row
            cell.accessoryView = button
        }
        cell.contentConfiguration = config
        cell.isUserInteractionEnabled = true
        return cell
    }

    @objc private func playRecordingTapped(_ sender: UIButton) {
        guard case .recording(let ticket, _, let localURL) = messages[sender.tag].kind else { return }
        if let player = players[ticket] {
            if player.isPlaying { player.pause(); sender.setImage(UIImage(systemName: "play.fill"), for: .normal); return }
            player.play(); sender.setImage(UIImage(systemName: "pause.fill"), for: .normal)
            return
        }
        Task {
            do {
                let data: Data
                if let localURL, let cached = try? Data(contentsOf: localURL) {
                    data = cached
                } else {
                    data = try await client.fetchBlob(ticket)
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(ticket.prefix(12)).wav")
                try data.write(to: url)
                let player = try AVAudioPlayer(contentsOf: url)
                player.play()
                players[ticket] = player
                tableView.reloadRows(at: [IndexPath(row: sender.tag, section: 0)], with: .none)
            } catch {
                NSLog("idfon recording fetch failed: \(error.localizedDescription)")
            }
        }
    }
}

extension ChatViewController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        reviewWaveform.setProgress(0)
    }
}
