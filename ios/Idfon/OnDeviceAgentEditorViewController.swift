import UIKit

/// Name + prompt editor for an on-device agent: the built-in `AFM 3`, or a
/// user agent. The prompt is the whole customization — the same local model
/// plays the role the name describes.
final class OnDeviceAgentEditorViewController: UIViewController {
    private let existing: OnDeviceAgent?
    private let onChanged: () -> Void

    private let nameField = UITextField()
    private let instructionsView = UITextView()

    init(agent: OnDeviceAgent?, onChanged: @escaping () -> Void) {
        self.existing = agent
        self.onChanged = onChanged
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = existing == nil ? "Add On-Device Agent" : "On-Device Agent"

        nameField.borderStyle = .roundedRect
        nameField.placeholder = "Name (the role)"
        nameField.text = existing?.name
        nameField.autocapitalizationType = .words

        instructionsView.font = .preferredFont(forTextStyle: .body)
        instructionsView.text = existing?.instructions ?? DirectorRuntime.onDeviceInstructions
        instructionsView.layer.borderColor = UIColor.separator.cgColor
        instructionsView.layer.borderWidth = 1
        instructionsView.layer.cornerRadius = 8
        instructionsView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)

        let promptLabel = UILabel()
        promptLabel.text = "Prompt"
        promptLabel.font = .preferredFont(forTextStyle: .headline)

        let agentName = existing?.name ?? nameField.text ?? "agent"
        let voiceLabel = UILabel()
        voiceLabel.font = .preferredFont(forTextStyle: .footnote)
        voiceLabel.textColor = .secondaryLabel
        voiceLabel.numberOfLines = 0
        voiceLabel.text = "Voice agent: \(agentName) (on-device)"
        if let id = existing?.id {
            Task {
                // The truth row (voice-agent-modes.md): who speaks and which
                // engines the calls use — from this agent's advertised catalog.
                let options = await VoiceCatalog.options(for: "\(id)", client: IdfonClient())
                let stt = options.first { $0.kind == .stt }
                let tts = options.first { $0.kind == .tts }
                let side: (VoiceOption?) -> String = { ($0?.side == .server) ? "server" : "on-device" }
                let asr = stt.map { "ASR: \($0.label) (\(side(stt)))" } ?? "ASR: —"
                let ttsLine = tts.map { "TTS: \($0.label) (\(side(tts)))" } ?? "TTS: —"
                voiceLabel.text = "Voice agent: \(agentName) (on-device) · \(asr) · \(ttsLine)"
            }
        }
        let stack = UIStackView(arrangedSubviews: [nameField, promptLabel, voiceLabel, instructionsView])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            instructionsView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(save))
    }

    @objc private func save() {
        let name = nameField.text ?? ""
        let instructions = instructionsView.text ?? ""
        if var existing {
            existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !existing.name.isEmpty else { return }
            OnDeviceAgents.shared.update(existing)
        } else {
            guard OnDeviceAgents.shared.add(name: name, instructions: instructions) != nil else {
                return
            }
        }
        onChanged()
        navigationController?.popViewController(animated: true)
    }
}
