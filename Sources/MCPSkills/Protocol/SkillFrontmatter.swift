import Foundation
import MCP

/// The YAML frontmatter of a `SKILL.md`, carried losslessly as JSON values.
///
/// Every field is kept, including fields this SDK does not interpret.
/// `name` and `description` are required strings.
public struct SkillFrontmatter: Hashable, Sendable {
    /// All frontmatter fields.
    public let fields: [String: Value]
    /// The skill name.
    public let name: String
    /// The skill description.
    public let description: String

    /// Creates frontmatter from its fields.
    ///
    /// - Throws: ``SkillFrontmatterError/missingField(_:)`` when `name` or
    ///   `description` is absent or not a string.
    public init(fields: [String: Value]) throws(SkillFrontmatterError) {
        guard let name = fields["name"]?.stringValue else {
            throw .missingField("name")
        }
        guard let description = fields["description"]?.stringValue else {
            throw .missingField("description")
        }
        self.fields = fields
        self.name = name
        self.description = description
    }

    /// The top-level keys whose values differ between two frontmatter
    /// objects, sorted. An empty result means the two are equal.
    ///
    /// Both sides are first normalized through the SDK's JSON representation
    /// of `Value`, so representation differences introduced by `Value`
    /// decoding cannot produce a difference. Object key order is ignored,
    /// array order is significant, and numbers compare by numeric value.
    ///
    /// - Throws: ``SkillFrontmatterError/unrepresentableNumber(_:)`` when a
    ///   side holds a value that has no JSON representation.
    public func differences(
        from other: SkillFrontmatter
    ) throws(SkillFrontmatterError) -> [String] {
        let lhs = try Self.normalized(fields)
        let rhs = try Self.normalized(other.fields)
        let keys = Set(lhs.keys).union(rhs.keys)
        return keys.filter { key in
            guard let left = lhs[key], let right = rhs[key] else { return true }
            return !Self.isEquivalent(left, right)
        }.sorted()
    }

    private static func normalized(
        _ fields: [String: Value]
    ) throws(SkillFrontmatterError) -> [String: Value] {
        // A JSON round trip applies the same Value decoding rules that every
        // received entry has already gone through.
        do {
            let data = try JSONEncoder().encode(fields)
            return try JSONDecoder().decode([String: Value].self, from: data)
        } catch {
            throw .unrepresentableNumber(String(describing: error))
        }
    }

    private static func isEquivalent(_ lhs: Value, _ rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.int(let left), .double(let right)), (.double(let right), .int(let left)):
            return Double(left) == right
        case (.array(let left), .array(let right)):
            return left.count == right.count
                && zip(left, right).allSatisfy { isEquivalent($0, $1) }
        case (.object(let left), .object(let right)):
            return Set(left.keys) == Set(right.keys)
                && left.allSatisfy { key, value in
                    right[key].map { isEquivalent(value, $0) } ?? false
                }
        default:
            return lhs == rhs
        }
    }
}

extension SkillFrontmatter: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let fields = try container.decode([String: Value].self)
        do {
            try self.init(fields: fields)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: error.description
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}
