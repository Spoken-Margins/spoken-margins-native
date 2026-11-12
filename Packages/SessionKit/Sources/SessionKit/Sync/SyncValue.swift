import Foundation

/// A field value in a sync record: JSON's shapes and nothing else, so a record round-trips through any transport and a
/// device can carry a field it does not understand (a newer build's) without losing it.
public enum SyncValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    /// Numbers are doubles, as in JSON. Whole numbers up to 2^53 (times in milliseconds, character offsets) are exact.
    case number(Double)
    case string(String)
    case array([SyncValue])
    case object([String: SyncValue])

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case let .number(value) = self, value.rounded() == value, abs(value) < 9_007_199_254_740_992 else { return nil }
        return Int(value)
    }

    public var arrayValue: [SyncValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: SyncValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// The value as JSON with sorted keys: the same text on every device and every run, to order values that tie.
    var canonical: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? ""
    }

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
        } else if let value = try? container.decode([SyncValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SyncValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// An `Encodable` model as a sync value, by way of its JSON. Dates become numbers, as the model's own coder makes them.
    public init<T: Encodable>(encoding model: T) throws {
        let data = try JSONEncoder().encode(model)
        self = try JSONDecoder().decode(SyncValue.self, from: data)
    }

    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}
