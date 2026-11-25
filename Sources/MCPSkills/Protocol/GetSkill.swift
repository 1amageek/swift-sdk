import MCP

/// `skills/get`: returns the entry for one skill by its `SKILL.md` URI,
/// whether or not the skill appears in `skills/list`.
public enum GetSkill: Method {
    public static let name = "skills/get"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The URI of the skill's `SKILL.md`.
        public let uri: String

        public init(uri: String) {
            self.uri = uri
        }
    }

    public struct Result: Hashable, Sendable {
        /// The skill entry.
        public let skill: Skill
        /// The cache hint; present on 2026-07-28 and absent on legacy revisions.
        public let cacheHint: CacheHint?

        public init(skill: Skill, cacheHint: CacheHint? = nil) {
            self.skill = skill
            self.cacheHint = cacheHint
        }
    }
}

extension GetSkill.Result: Codable {
    private enum CodingKeys: String, CodingKey {
        case skill
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            skill: try container.decode(Skill.self, forKey: .skill),
            cacheHint: try CacheFields.decode(from: decoder)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(skill, forKey: .skill)
        try CacheFields.encode(cacheHint, to: encoder)
    }
}
