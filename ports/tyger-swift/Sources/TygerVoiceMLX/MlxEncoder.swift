import Foundation
import MLX
import MLXNN

/// MLX port of the accepted `ports/tyger-mlx/encoder.py` EncoderL15 — the decision
/// path: mel features (B, T, 128) -> hidden_states[15] (B, T/8, 1024). Weights are
/// the exported artifact (`ports/tyger-mlx/export_swift.py`): the accepted int8-g16
/// config dequantised to fp32, so all compute is plain fp32 matmuls and the
/// arithmetic matches the accepted Python chain.
final class MlxEncoder {
    private let w: [String: MLXArray]
    private let invFreq: MLXArray
    private let subsampling: Subsampling
    private let blocks: [Block]

    init(weights: [String: MLXArray]) {
        self.w = weights
        var inv = [Float](repeating: 0, count: 512)
        for i in 0..<512 {
            inv[i] = 1.0 / powf(10000.0, Float(2 * i) / 1024) // REL_BASE ** (arange(0,HIDDEN,2)/HIDDEN)
        }
        self.invFreq = MLXArray(inv)
        self.subsampling = Subsampling(weights)
        self.blocks = (0..<15).map { Block(weights, $0) }
    }

    func callAsFunction(_ features: MLXArray) -> MLXArray {
        var x = subsampling(features)
        let t = x.shape[1]
        let posEmb = positions(t).expandedDimensions(axis: 0)
        let m = mask(t)
        for block in blocks {
            x = block(x, posEmb, m)
        }
        return x
    }

    /// Sin/cos positions, torch's layout: stack axis -1 then fold to 1024.
    private func positions(_ t: Int) -> MLXArray {
        var pos = [Float](repeating: 0, count: 2 * t - 1)
        for i in 0..<(2 * t - 1) {
            pos[i] = Float(t - 1 - i) // arange(t-1, -t, -1)
        }
        let freqs = MLXArray(pos).reshaped([2 * t - 1, 1]) * invFreq.expandedDimensions(axis: 0)
        return MLX.stacked([MLX.sin(freqs), MLX.cos(freqs)], axis: -1).reshaped([2 * t - 1, 1024])
    }

    /// Their `chunked_limited` mask at lookahead 0: attend to the WINDOW-1 previous
    /// frames in the same chunk (chunk = 1).
    private func mask(_ t: Int) -> MLXArray {
        var m = [Bool](repeating: false, count: t * t)
        for i in 0..<t {
            for j in 0..<t where i - j >= 0 && i - j <= 56 {
                m[i * t + j] = true
            }
        }
        return MLXArray(m).reshaped([t, t])
    }
}

/// `arr[..., lo..<hi]` along one axis (the artifact is small slices only).
func slice(_ a: MLXArray, axis: Int, _ range: Range<Int>) -> MLXArray {
    MLX.take(a, MLXArray(Array(range)), axis: axis)
}

private struct FeedForward {
    let w1, w2: MLXArray

    init(_ w: [String: MLXArray], _ p: String) {
        w1 = w["\(p).linear1.weight"]!
        w2 = w["\(p).linear2.weight"]!
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        matmul(MLXNN.silu(matmul(x, w1)), w2)
    }
}

private struct Attention {
    let q, k, v, o, relK, biasU, biasV: MLXArray

    init(_ w: [String: MLXArray], _ p: String) {
        q = w["\(p).q_proj.weight"]!
        k = w["\(p).k_proj.weight"]!
        v = w["\(p).v_proj.weight"]!
        o = w["\(p).o_proj.weight"]!
        relK = w["\(p).relative_k_proj.weight"]!
        biasU = w["\(p).bias_u"]!.reshaped([1, 8, 1, 128])
        biasV = w["\(p).bias_v"]!.reshaped([1, 8, 1, 128])
    }

    /// torch pad((1, 0)) is a LEFT pad; fold into rows and drop the first row.
    private func relShift(_ a: MLXArray) -> MLXArray {
        let b = a.shape[0], h = a.shape[1], q = a.shape[2], p = a.shape[3]
        let ap = MLX.padded(a, widths: [[0, 0], [0, 0], [0, 0], [1, 0]]) // torch pad((1, 0)): LEFT pad
        return slice(ap.reshaped([b, h, p + 1, q]), axis: 2, 1..<(p + 1)).reshaped([b, h, q, p])
    }

    func callAsFunction(_ x: MLXArray, _ posEmb: MLXArray, _ mask: MLXArray) -> MLXArray {
        let b = x.shape[0], t = x.shape[1]
        let q = matmul(x, self.q).reshaped([b, t, 8, 128]).transposed(0, 2, 1, 3)
        let k = matmul(x, self.k).reshaped([b, t, 8, 128]).transposed(0, 2, 1, 3)
        let v = matmul(x, self.v).reshaped([b, t, 8, 128]).transposed(0, 2, 1, 3)
        let relK = matmul(posEmb, self.relK).reshaped([1, posEmb.shape[1], 8, 128]).transposed(0, 2, 3, 1)
        let headDim: Float = 128.0
        let scaling = powf(headDim, -0.5)
        var bd = relShift(matmul(q + biasV, relK))
        bd = slice(bd, axis: 3, 0..<t) * scaling
        bd = MLX.where(mask.expandedDimensions(axes: [0, 1]), bd, MLXArray(-Float.infinity))
        let scores = matmul(q + biasU, k.transposed(0, 1, 3, 2)) * scaling + bd
        let out = matmul(MLX.softmax(scores, axis: -1), v)
        return matmul(out.transposed(0, 2, 1, 3).reshaped([b, t, 1024]), o)
    }
}

private struct ConvModule {
    let pw1, pw2, dw, dwBias, nw, nb: MLXArray?

    init(_ w: [String: MLXArray], _ p: String) {
        pw1 = w["\(p).pointwise_conv1.weight"]!
        pw2 = w["\(p).pointwise_conv2.weight"]!
        dw = w["\(p).depthwise_conv.weight"]!
        dwBias = w["\(p).depthwise_conv.bias"]
        nw = w["\(p).norm.weight"]!
        nb = w["\(p).norm.bias"]!
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = matmul(x, pw1!)
        h = slice(h, axis: 2, 0..<1024) * MLX.sigmoid(slice(h, axis: 2, 1024..<2048)) // GLU
        h = MLX.padded(h, widths: [[0, 0], [8, 0], [0, 0]]) // causal: left pad only
        h = MLX.conv1d(h, dw!, stride: 1, padding: 0, groups: 1024)
        if let b = dwBias {
            h = h + b
        }
        h = MLX.layerNorm(h, weight: nw!, bias: nb!, eps: 1e-5)
        h = MLXNN.silu(h)
        return matmul(h, pw2!)
    }
}

private struct Block {
    let ff1, ff2: FeedForward
    let attn: Attention
    let conv: ConvModule
    let norms: [String: (MLXArray, MLXArray)]

    init(_ w: [String: MLXArray], _ i: Int) {
        let p = "layers.\(i)"
        ff1 = FeedForward(w, "\(p).feed_forward1")
        ff2 = FeedForward(w, "\(p).feed_forward2")
        attn = Attention(w, "\(p).self_attn")
        conv = ConvModule(w, "\(p).conv")
        norms = Dictionary(uniqueKeysWithValues:
            ["norm_feed_forward1", "norm_self_att", "norm_conv", "norm_feed_forward2", "norm_out"]
                .map { ($0, (w["\(p).\($0).weight"]!, w["\(p).\($0).bias"]!)) })
    }

    private func norm(_ name: String, _ x: MLXArray) -> MLXArray {
        MLX.layerNorm(x, weight: norms[name]!.0, bias: norms[name]!.1, eps: 1e-5)
    }

    func callAsFunction(_ x: MLXArray, _ posEmb: MLXArray, _ mask: MLXArray) -> MLXArray {
        var x = x + 0.5 * ff1(norm("norm_feed_forward1", x))
        x = x + attn(norm("norm_self_att", x), posEmb, mask)
        x = x + conv(norm("norm_conv", x))
        x = x + 0.5 * ff2(norm("norm_feed_forward2", x))
        return norm("norm_out", x)
    }
}

private struct Subsampling {
    let convInW, convInB, linW, linB: MLXArray
    let dwW, dwB, pwW, pwB: [MLXArray]

    init(_ w: [String: MLXArray]) {
        convInW = w["subsampling.conv_in.weight"]!
        convInB = w["subsampling.conv_in.bias"]!
        linW = w["subsampling.linear.weight"]!
        linB = w["subsampling.linear.bias"]!
        dwW = (0..<2).map { w["subsampling.layers.\($0).depthwise_conv.weight"]! }
        dwB = (0..<2).map { w["subsampling.layers.\($0).depthwise_conv.bias"]! }
        pwW = (0..<2).map { w["subsampling.layers.\($0).pointwise_conv.weight"]! }
        pwB = (0..<2).map { w["subsampling.layers.\($0).pointwise_conv.bias"]! }
    }

    /// Offline causal padding: (K-1, S-1) on both axes; k=1 pointwise takes none.
    private func conv(_ h: MLXArray, _ wt: MLXArray, _ b: MLXArray, stride: Int, groups: Int, k: Int) -> MLXArray {
        let hp = MLX.padded(h, widths: [[0, 0], [k - 1, stride - 1], [k - 1, stride - 1], [0, 0]])
        return MLX.conv2d(hp, wt, stride: [stride, stride], padding: [0, 0], groups: groups) + b
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x.expandedDimensions(axis: 3) // (B, T, 128, 1)
        h = MLXNN.relu(conv(h, convInW, convInB, stride: 2, groups: 1, k: 3))
        for i in 0..<2 {
            h = conv(h, dwW[i], dwB[i], stride: 2, groups: 256, k: 3)
            h = MLXNN.relu(conv(h, pwW[i], pwB[i], stride: 1, groups: 1, k: 1))
        }
        let b = h.shape[0], t = h.shape[1], f = h.shape[2], c = h.shape[3]
        // torch: (B, C, F, T) -> transpose(1,2).reshape(B, T, C*F): last axis is (c, f)
        h = h.transposed(0, 1, 3, 2).reshaped([b, t, c * f])
        return matmul(h, linW) + linB
    }
}
