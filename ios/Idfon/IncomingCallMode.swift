import Foundation

/// How calls with one contact use iOS system calling or the in-app Bar.
/// The in-app Bar is the default; CallKit is the explicit system-call choice.
///
/// Decoded leniently: an unrecognized wire value resolves to `.bar` rather
/// than throwing, so a future daemon mode iOS does not know never breaks
/// decoding of the whole `peers` array.
enum IncomingCallMode: String, Decodable, CaseIterable {
    case bar = "bar"
    case callKit = "call_kit"

    var wireValue: String { rawValue }
    var title: String { self == .bar ? "In-app only" : "System call" }
    var usesCallKit: Bool { self == .callKit }

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(IncomingCallMode.init(rawValue:)) ?? .bar
    }
}

