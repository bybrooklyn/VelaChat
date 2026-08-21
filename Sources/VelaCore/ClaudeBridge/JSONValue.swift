import Foundation

/// A decoded JSON value of unknown shape.
///
/// Needed because Claude Code's tool inputs and control-request payloads
/// are arbitrary per tool — `Bash` takes a command string, `Edit` takes
/// paths and replacements, an MCP tool takes whatever its server declared.
/// Modelling each one would mean tracking every tool Claude Code ships,
/// which is exactly the coupling `ClaudeControlProtocol` is written to
/// avoid.
public enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
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
            self = .null
        }
    }

    /// Back to Foundation types, for re-encoding through
    /// `JSONSerialization` when a value has to be echoed back unchanged
    /// (an approved tool call's input, for example).
    public var anyValue: Any? {
        switch self {
        case .null: return nil
        case .bool(let value): return value
        case .number(let value): return value == value.rounded() && abs(value) < 9e15 ? Int(value) : value
        case .string(let value): return value
        case .array(let items): return items.map { $0.anyValue ?? NSNull() }
        case .object(let fields): return fields.mapValues { $0.anyValue ?? NSNull() }
        }
    }

    public var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }
    public var intValue: Int? { if case .number(let value) = self { return Int(value) } else { return nil } }

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    /// Compact single-line rendering for an activity row's detail text.
    public var compactDescription: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .string(let value): return value
        case .array(let items): return "[" + items.map(\.compactDescription).joined(separator: ", ") + "]"
        case .object(let fields):
            return "{" + fields.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.compactDescription)" }
                .joined(separator: ", ") + "}"
        }
    }
}
