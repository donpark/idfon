import Foundation

/// Type-erased Encodable/Decodable so params and results can hold arbitrary
/// JSON produced or consumed dynamically.
///
/// Foundation-only (no C ABI, no UIKit) so `ios/Checks/*` can compile it on
/// the host alongside the code under test.
struct AnyEncodable: Encodable, Decodable {
    let value: Any

    subscript(key: String) -> AnyEncodable? {
        (value as? [String: AnyEncodable])?[key]
    }

    subscript(index: Int) -> AnyEncodable? {
        (value as? [AnyEncodable])?[index]
    }

    var asArray: [AnyEncodable]? { value as? [AnyEncodable] }

    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyEncodable].self) {
            value = array
        } else if let object = try? container.decode([String: AnyEncodable].self) {
            value = object
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Int64: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [AnyEncodable]: try container.encode(v)
        case let v as [String: AnyEncodable]: try container.encode(v)
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "unsupported JSON type"))
        }
    }
}
