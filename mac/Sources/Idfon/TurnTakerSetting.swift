import Foundation

/// The turn-taker option (`docs/voice-tyger-option.md`): how turns are decided.
/// `classic` = the Segmenter's signals (recognizer final / 1.2 s gap); `tyger` =
/// the turn model's decisions; `auto` = tyger when the model is available.
/// Global default + per-contact override. Fail-open everywhere: without a
/// loaded model a session keeps classic behavior whatever the setting says.
enum TurnTakerMode: String, CaseIterable {
    case auto
    case classic
    case tyger
}

enum TurnTakerSetting {
    private static let globalKey = "idfon.turn-taker"
    private static let overridesKey = "idfon.turn-taker-overrides"

    static func mode(for peerID: String?) -> TurnTakerMode {
        if let peerID, let raw = overrides()[peerID], let mode = TurnTakerMode(rawValue: raw) {
            return mode
        }
        return TurnTakerMode(rawValue: UserDefaults.standard.string(forKey: globalKey) ?? "") ?? .auto
    }

    static func setGlobal(_ mode: TurnTakerMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: globalKey)
    }

    static func setOverride(_ mode: TurnTakerMode?, for peerID: String) {
        var all = overrides()
        if let mode {
            all[peerID] = mode.rawValue
        } else {
            all.removeValue(forKey: peerID)
        }
        UserDefaults.standard.set(all, forKey: overridesKey)
    }

    /// Whether the model's decisions drive turns for this contact right now.
    static func usesModel(for peerID: String?, modelAvailable: Bool) -> Bool {
        guard modelAvailable else { return false }
        switch mode(for: peerID) {
        case .tyger, .auto: return true
        case .classic: return false
        }
    }

    private static func overrides() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
    }
}

/// Picker labels, shared by the person screen's view and edit modes.
extension TurnTakerMode {
    var title: String { rawValue.capitalized }

    var subtitle: String {
        switch self {
        case .auto: return "Tyger when its model is available"
        case .classic: return "The segmenter's timing (always available)"
        case .tyger: return "The turn model's decisions"
        }
    }

    /// What the mode means for the call, in one line.
    var caption: String {
        switch self {
        case .auto:
            return "The turn model decides turns when it is loaded; the classic segmenter is the fallback."
        case .classic:
            return "Turns commit on recognizer finals or the 1.2 s gap. No model needed."
        case .tyger:
            return "Turns commit at the model's endpoint. Without a loaded model the call falls back to classic."
        }
    }
}
