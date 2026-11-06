import Foundation

/// One turn-taker implementation behind ``TurnRuntime``'s feed loop: the encoder
/// (audio window -> encoder frames) and the step (one frame -> the 8-vector),
/// with the carried state hidden inside. Core ML for the iOS tier
/// (``CoreMLTurnModel``), MLX for the mac tier (TygerVoiceMLX's MlxTurnModel).
public protocol TurnModel: AnyObject {
    /// The heads' context starts over (the rules' reset points).
    func reset()
    /// Encoder frames (window's mel frames / 8, 1024 wide) for one 16 kHz window.
    func encode(_ window: [Float]) -> [[Float]]
    /// One frame's 8-vector from the two hidden rows and the frame's energy in dB.
    func step(hu: [Float], ha: [Float], actDb: Double, prevState: Int) -> [Float]
}

/// A ``TurnModel`` whose encoder is a cache-aware streaming prefix (the 320 ms turn
/// tier, ``TurnPrefixModel``): one batched call per hop covers both ears, each with
/// its own cache set, instead of two `encode()` calls over an 8 s window.
///
/// `TurnRuntime` uses this conformance to switch feed loops. A model that does not
/// conform keeps the windowed cut path unchanged, byte for byte.
public protocol BatchedEarModel: TurnModel {
    /// Both ears' tap rows for one 320 ms hop (oldest first), from one prediction.
    func encodePair(mic: [Float], playback: [Float]) -> (mic: [[Float]], playback: [[Float]])
    /// The artifact's framing (rows per hop, cache depth, mel window).
    var shape: TurnPrefixModel.Shape { get }
    /// The 80 ms frame index of the last released block (never the row counter).
    var tapFrameOrigin: Int { get }
    /// A real stream restart: caches, mel history and the origin rebase together.
    /// A heads `reset()` must leave the audio stream alone.
    func restartStreams()
}
