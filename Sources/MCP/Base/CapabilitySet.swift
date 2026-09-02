import Foundation

/// A lossless object containing known and extension capability fields.
public struct CapabilitySet: Hashable, Codable, Sendable {
    public var fields: [String: Value]

    public init(_ fields: [String: Value] = [:]) {
        self.fields = fields
    }

    public subscript(_ key: String) -> Value? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    public var experimental: [String: Value]? {
        get { fields["experimental"]?.objectValue }
        set { fields["experimental"] = newValue.map(Value.object) }
    }

    public var extensions: [String: Value]? {
        get { fields["extensions"]?.objectValue }
        set { fields["extensions"] = newValue.map(Value.object) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        fields = try container.decode([String: Value].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}
