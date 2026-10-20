import CoreAI

/// Fill an NDArray's backing buffer from a flat sequence (row-major).
@available(macOS 27.0, iOS 27.0, *)
func fillNDArray<S: Sequence>(_ array: inout NDArray, as type: Float.Type, with values: S)
where S.Element == Float {
    let view = array.mutableView(as: Float.self)
    view.withUnsafeMutablePointer { ptr, _, _ in
        var i = 0
        for v in values {
            ptr[i] = v
            i += 1
        }
    }
}

/// Fill `count` elements via a closure of the flat index.
@available(macOS 27.0, iOS 27.0, *)
func fillNDArray(_ array: inout NDArray, as type: Float.Type, count: Int, _ make: (Int) -> Float) {
    let view = array.mutableView(as: Float.self)
    view.withUnsafeMutablePointer { ptr, _, _ in
        for i in 0..<count {
            ptr[i] = make(i)
        }
    }
}

/// Fill an Int32 NDArray from a flat sequence (row-major).
@available(macOS 27.0, iOS 27.0, *)
func fillNDArray<S: Sequence>(_ array: inout NDArray, as type: Int32.Type, with values: S)
where S.Element == Int32 {
    let view = array.mutableView(as: Int32.self)
    view.withUnsafeMutablePointer { ptr, _, _ in
        var i = 0
        for v in values {
            ptr[i] = v
            i += 1
        }
    }
}

/// Read `count` floats out of an NDArray (row-major).
@available(macOS 27.0, iOS 27.0, *)
func readNDArray(_ array: NDArray, as type: Float.Type, count: Int) -> [Float] {
    var out = [Float]()
    out.reserveCapacity(count)
    array.view(as: Float.self).withUnsafePointer { ptr, _, _ in
        for i in 0..<count {
            out.append(ptr[i])
        }
    }
    return out
}
