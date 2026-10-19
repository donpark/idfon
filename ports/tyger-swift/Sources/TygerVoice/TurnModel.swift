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
