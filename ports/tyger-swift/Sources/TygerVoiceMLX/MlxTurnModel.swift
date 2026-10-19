import Foundation
import MLX
import MLXNN
import TygerVoice

/// The mac tier's turn model: the accepted `ports/tyger-mlx/` chain (encoder +
/// 14M turn-taker) over the exported artifact (`ports/tyger-mlx/export_swift.py`
/// -> bench-results/mlx/TygerChainInt8.safetensors). All fp32; the artifact bakes
/// in the accepted int8-g16 quantisation, so there is no quantisation code here.
public final class MlxTurnModel: TurnModel {
    private let encoder: MlxEncoder
    private let tt: TurnTaker
    private var state: [MLXArray]? // the GRU's 3 x (1, 768) carried state

    public convenience init() throws {
        let pkg = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try self.init(weightsURL: pkg.appendingPathComponent("bench-results/mlx/TygerChainInt8.safetensors"))
    }

    public init(weightsURL: URL) throws {
        let all = try MLX.loadArrays(url: weightsURL)
        let enc = Dictionary(uniqueKeysWithValues: all.filter { $0.key.hasPrefix("enc.") }.map { (String($0.key.dropFirst(4)), $0.value) })
        let tt = Dictionary(uniqueKeysWithValues: all.filter { $0.key.hasPrefix("tt.") }.map { (String($0.key.dropFirst(3)), $0.value) })
        self.encoder = MlxEncoder(weights: enc)
        self.tt = TurnTaker(weights: tt)
        self.state = nil
    }

    public func reset() {
        state = nil
    }

    public func encode(_ window: [Float]) -> [[Float]] {
        guard !window.isEmpty else { return [] }
        let (frames, _) = MelFeatures.process(window)
        let t = frames.count
        var flat = [Float](repeating: 0, count: t * MelFeatures.nMels)
        for (i, row) in frames.enumerated() {
            flat.replaceSubrange((i * MelFeatures.nMels)..<((i + 1) * MelFeatures.nMels), with: row)
        }
        let h = encoder(MLXArray(flat).reshaped([1, t, MelFeatures.nMels]))
        MLX.eval(h)
        var rows: [[Float]] = []
        let arr = h.asArray(Float.self)
        for f in 0..<(arr.count / 1024) {
            rows.append(Array(arr[(f * 1024)..<((f + 1) * 1024)]))
        }
        return rows
    }

    public func step(hu: [Float], ha: [Float], actDb: Double, prevState: Int) -> [Float] {
        // the oracle's energy normalisation lives outside the model: (db+50)/25 clamped
        let act = min(3.0, max(-3.0, (actDb + 50.0) / 25.0))
        let (out, newState) = tt.step(
            hUser: MLXArray(hu).reshaped([1, 1, 1024]),
            hAgent: MLXArray(ha).reshaped([1, 1, 1024]),
            act: MLXArray([[Float(act)]]),
            prevState: prevState,
            state: state)
        state = newState
        MLX.eval(out)
        return out.asArray(Float.self)
    }
}

/// The 14M decision model (`ports/tyger-mlx/turn_taker.py`): fuse -> 3 GRU cells ->
/// the 8 heads. Torch GRU gate order [r, z, n].
final class TurnTaker {
    private let projUser: (MLXArray, MLXArray)
    private let projAgent: (MLXArray, MLXArray)
    private let projEnergy: (MLXArray, MLXArray)
    private let stateEmb: MLXArray // (5, 768)
    private let inNorm: (MLXArray, MLXArray)
    private let outNorm: (MLXArray, MLXArray)
    private let stateHead: (MLXArray, MLXArray)
    private let hazardHead: (MLXArray, MLXArray)
    private let yieldHead, bcHead, epHead: MlpHead
    let cells: [GRUCell]

    init(weights w: [String: MLXArray]) {
        projUser = (w["proj_user.weight"]!, w["proj_user.bias"]!)
        projAgent = (w["proj_agent.weight"]!, w["proj_agent.bias"]!)
        projEnergy = (w["proj_energy.weight"]!, w["proj_energy.bias"]!)
        stateEmb = w["state_emb.weight"]! // (5, 768), rows are the state ids
        inNorm = (w["in_norm.weight"]!, w["in_norm.bias"]!)
        outNorm = (w["out_norm.weight"]!, w["out_norm.bias"]!)
        stateHead = (w["state_head.weight"]!, w["state_head.bias"]!)
        hazardHead = (w["hazard_head.weight"]!, w["hazard_head.bias"]!)
        yieldHead = MlpHead(w["yield_head.0.weight"]!, w["yield_head.0.bias"]!, w["yield_head.2.weight"]!, w["yield_head.2.bias"]!)
        bcHead = MlpHead(w["bc_head.0.weight"]!, w["bc_head.0.bias"]!, w["bc_head.2.weight"]!, w["bc_head.2.bias"]!)
        epHead = MlpHead(w["ep_head.0.weight"]!, w["ep_head.0.bias"]!, w["ep_head.2.weight"]!, w["ep_head.2.bias"]!)
        cells = (0..<3).map { i in
            GRUCell(w["core.weight_ih_l\(i)"]!, w["core.weight_hh_l\(i)"]!,
                    w["core.bias_ih_l\(i)"]!, w["core.bias_hh_l\(i)"]!)
        }
    }

    /// (1,1,1024)x2 + act + the state row -> the fused (1, 768) after in_norm.
    func fuse(hUser: MLXArray, hAgent: MLXArray, act: MLXArray, prevState: Int) -> MLXArray {
        let row = MLX.take(stateEmb, MLXArray([prevState]), axis: 0).squeezed(axis: 0)
        var z = matmul(hUser, projUser.0) + projUser.1 + matmul(hAgent, projAgent.0) + projAgent.1 +
            matmul(act.expandedDimensions(axis: 2), projEnergy.0) + projEnergy.1 + row
        z = MLX.layerNorm(z, weight: inNorm.0, bias: inNorm.1, eps: 1e-5)
        return z.squeezed(axis: 1) // (1, 768)
    }

    /// One frame (1,1,1024) from the carried GRU state (3 x (1,768); nil: fresh)
    /// -> (the 8-vector, new state). This is the live path.
    func step(hUser: MLXArray, hAgent: MLXArray, act: MLXArray, prevState: Int, state: [MLXArray]?) -> (MLXArray, [MLXArray]) {
        var state = state ?? (0..<3).map { _ in MLX.zeros([1, 768]) }
        var z = fuse(hUser: hUser, hAgent: hAgent, act: act, prevState: prevState)
        for i in 0..<3 {
            z = cells[i](z, state[i])
            state[i] = z
        }
        return (outputs(z.expandedDimensions(axis: 1)), state)
    }

    /// (1, 1, 768) -> (1, 1, 8): state logits x4, then hazard, yield, bc, ep.
    func outputs(_ zIn: MLXArray) -> MLXArray {
        let z = MLX.layerNorm(zIn, weight: outNorm.0, bias: outNorm.1, eps: 1e-5)
        let state = matmul(z, stateHead.0) + stateHead.1
        let haz = MLX.sigmoid(matmul(z, hazardHead.0) + hazardHead.1)
        let yie = MLX.sigmoid(yieldHead(z))
        let bc = MLX.sigmoid(bcHead(z))
        let ep = MLX.sigmoid(epHead(z))
        return MLX.concatenated([state, haz, yie, bc, ep], axis: -1)
    }
}

struct GRUCell {
    let wx: [MLXArray] // per gate [r, z, n], (768, 768)
    let wh: [MLXArray]
    let bx: [MLXArray]
    let bh: [MLXArray]

    init(_ wIh: MLXArray, _ wHh: MLXArray, _ bIh: MLXArray, _ bHh: MLXArray) {
        // torch (3d, d) with gate blocks [r, z, n] -> rows per gate, transposed
        let d = 768
        func rows(_ a: MLXArray, _ r: Range<Int>) -> MLXArray {
            slice(a, axis: 0, r)
        }
        wx = (0..<3).map { rows(wIh, ($0 * d)..<(($0 + 1) * d)).transposed(axes: [1, 0]) }
        wh = (0..<3).map { rows(wHh, ($0 * d)..<(($0 + 1) * d)).transposed(axes: [1, 0]) }
        bx = (0..<3).map { rows(bIh, ($0 * d)..<(($0 + 1) * d)) }
        bh = (0..<3).map { rows(bHh, ($0 * d)..<(($0 + 1) * d)) }
    }

    func callAsFunction(_ x: MLXArray, _ h: MLXArray) -> MLXArray {
        let xr = matmul(x, wx[0]) + bx[0]
        let xz = matmul(x, wx[1]) + bx[1]
        let xn = matmul(x, wx[2]) + bx[2]
        let hr = matmul(h, wh[0]) + bh[0]
        let hz = matmul(h, wh[1]) + bh[1]
        let hn = matmul(h, wh[2]) + bh[2]
        let r = MLX.sigmoid(xr + hr)
        let z = MLX.sigmoid(xz + hz)
        let n = MLX.tanh(xn + r * hn)
        return (1 - z) * n + z * h
    }
}

struct MlpHead {
    let w1, b1, w2, b2: MLXArray

    init(_ w1: MLXArray, _ b1: MLXArray, _ w2: MLXArray, _ b2: MLXArray) {
        self.w1 = w1
        self.b1 = b1
        self.w2 = w2
        self.b2 = b2
    }

    func callAsFunction(_ z: MLXArray) -> MLXArray {
        matmul(MLXNN.silu(matmul(z, w1) + b1), w2) + b2
    }
}
