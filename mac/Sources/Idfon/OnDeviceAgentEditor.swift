import AppKit

/// Name + prompt editor for an on-device agent: the built-in `AFM 3`, or a
/// user agent. The prompt is the whole customization — the same local model
/// plays the role the name describes.
///
/// A sheet, not a screen: the mac shell has no push navigation for this
/// (`ios/Idfon/OnDeviceAgentEditorViewController.swift` is the iOS twin).
enum OnDeviceAgentEditor {
    static func present(agent: OnDeviceAgent?, in window: NSWindow?, onChanged: @escaping () -> Void) {
        guard let window else { return }

        let name = NSTextField(string: agent?.name ?? "")
        name.placeholderString = "Name (the role)"

        let promptScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 210))
        let prompt = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 210))
        prompt.font = NSFont.systemFont(ofSize: 12)
        prompt.isRichText = false
        prompt.isEditable = true
        prompt.string = agent?.instructions ?? Director.onDeviceInstructions
        promptScroll.documentView = prompt
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder

        let promptLabel = NSTextField(labelWithString: "Prompt")
        promptLabel.font = NSFont.boldSystemFont(ofSize: 12)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        name.frame = NSRect(x: 0, y: 216, width: 360, height: 24)
        promptLabel.frame = NSRect(x: 0, y: 196, width: 360, height: 16)
        accessory.addSubview(name)
        accessory.addSubview(promptLabel)
        accessory.addSubview(promptScroll)

        let alert = NSAlert()
        alert.messageText = agent == nil ? "Add On-Device Agent" : "On-Device Agent"
        alert.informativeText = "The name is the contact; the prompt is the role the local model plays."
        alert.addButton(withTitle: agent == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            if let existing = agent {
                var updated = existing
                updated.name = newName
                updated.instructions = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
                OnDeviceAgents.shared.update(updated)
            } else {
                OnDeviceAgents.shared.add(name: newName, instructions: prompt.string)
            }
            onChanged()
        }
    }
}
