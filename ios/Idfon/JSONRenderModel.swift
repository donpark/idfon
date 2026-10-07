import Foundation

/// App-owned JSON-render model (`docs/idfon-web-hybrid-plan.md`, P5).
///
/// The remote agent sends **data only**: a declarative tree that names existing
/// components from this fixed catalog and carries no code. Unknown component
/// types are dropped with their subtrees, and size/depth/element limits are
/// enforced before anything renders. Interactive nodes carry an `action` name
/// that [`RenderToolRegistry`] resolves against a trusted, app-registered tool
/// catalog — the remote agent never supplies executable logic.
///
/// Foundation-only so `ios/Checks/JSONRenderCheck` can run it on the host.

/// Arbitrary JSON, typed enough for props without a schema per component.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

enum JSONRenderError: Error, Equatable {
    case tooLarge
    case tooManyElements
    case badRoot
}

/// Hard bounds on an untrusted spec, before it reaches the renderer.
struct SpecLimits: Equatable {
    var maxBytes = 256 * 1024
    var maxElements = 512
    var maxDepth = 32

    static let standard = SpecLimits()
}

struct JSONRenderElement: Codable, Equatable {
    let type: String
    let props: [String: JSONValue]?
    let children: [String]?
}

struct JSONRenderSpec: Codable, Equatable {
    let root: String
    let elements: [String: JSONRenderElement]

    /// The only components this app knows how to draw.
    static let catalog: Set<String> = [
        "Text", "Button", "Card", "Metric", "Row", "Divider", "Spacer",
    ]

    /// Decodes and validates a spec. Throws when it exceeds a limit or has no
    /// usable root; component-type filtering happens in `normalized()`.
    static func decode(_ data: Data, limits: SpecLimits = .standard) throws -> JSONRenderSpec {
        guard data.count <= limits.maxBytes else { throw JSONRenderError.tooLarge }
        let spec = try JSONDecoder().decode(JSONRenderSpec.self, from: data)
        guard spec.elements.count <= limits.maxElements else { throw JSONRenderError.tooManyElements }
        guard let root = spec.elements[spec.root], Self.catalog.contains(root.type) else {
            throw JSONRenderError.badRoot
        }
        return spec
    }

    /// Keeps only known component types (and their known descendants), drops
    /// missing child ids and cycles, and enforces the element/depth limits.
    func normalized(limits: SpecLimits = .standard) throws -> JSONRenderSpec {
        guard let rootElement = elements[root], Self.catalog.contains(rootElement.type) else {
            throw JSONRenderError.badRoot
        }
        var kept: [String: JSONRenderElement] = [:]
        var visiting: Set<String> = []

        func visit(_ id: String, _ depth: Int) {
            guard depth <= limits.maxDepth, kept.count < limits.maxElements else { return }
            guard !visiting.contains(id), kept[id] == nil, let element = elements[id],
                  Self.catalog.contains(element.type) else { return }
            visiting.insert(id)
            let children = (element.children ?? []).filter { child in
                guard let node = elements[child] else { return false }
                return Self.catalog.contains(node.type)
            }
            kept[id] = JSONRenderElement(
                type: element.type, props: element.props,
                children: children.isEmpty ? nil : children)
            for child in children { visit(child, depth + 1) }
            visiting.remove(id)
        }
        visit(root, 0)
        return JSONRenderSpec(root: root, elements: kept)
    }
}

/// A tool the app exposes to a rendered spec. `sensitive` tools require an
/// explicit human confirmation before they run.
struct RenderTool: @unchecked Sendable {
    let name: String
    let description: String
    let sensitive: Bool
    let run: ([String: JSONValue]) async -> String
}

enum RenderError: Error, Equatable {
    case unknown(String)
    case denied(String)
}

/// One dispatched action and its outcome, for the durable audit log.
struct RenderAudit: Codable, Equatable {
    let at: Date
    let action: String
    let args: [String: JSONValue]
    /// `"unknown"`, `"denied"`, or `"ok: <result>"`.
    let outcome: String
}

/// The trusted action catalog. A spec's `action` string is matched here; an
/// unregistered name never executes.
final class RenderToolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String: RenderTool] = [:]

    /// Human-in-the-loop gate for `sensitive` tools. `nil` denies every
    /// sensitive action.
    var confirm: ((RenderTool) async -> Bool)?

    /// Every dispatch is reported here — the action, its args, and the outcome.
    /// The app persists it; a denial is the security-relevant event.
    var audit: ((RenderAudit) -> Void)?

    func register(_ tool: RenderTool) {
        lock.lock()
        tools[tool.name] = tool
        lock.unlock()
    }

    func names() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return tools.keys.sorted()
    }

    func tool(named name: String) -> RenderTool? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }

    func dispatch(
        _ action: String,
        args: [String: JSONValue] = [:]
    ) async -> Result<String, RenderError> {
        guard let tool = tool(named: action) else {
            audit?(RenderAudit(at: Date(), action: action, args: args, outcome: "unknown"))
            return .failure(.unknown(action))
        }
        if tool.sensitive {
            guard let confirm, await confirm(tool) else {
                audit?(RenderAudit(at: Date(), action: action, args: args, outcome: "denied"))
                return .failure(.denied(action))
            }
        }
        let result = await tool.run(args)
        audit?(RenderAudit(at: Date(), action: action, args: args, outcome: "ok: \(result)"))
        return .success(result)
    }
}
