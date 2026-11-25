import MCP

/// `skills/list`: enumerates the skills a server offers, one page at a time.
///
/// A listing may be empty or partial, and a skill entry is never split
/// across pages.
public enum ListSkills: Method {
    public static let name = "skills/list"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The opaque cursor from a previous page.
        public let cursor: String?

        public init(cursor: String? = nil) {
            self.cursor = cursor
        }
    }

    public struct Result: Hashable, Sendable {
        /// The skills on this page.
        public let skills: [Skill]
        /// The cursor of the next page, when one exists.
        public let nextCursor: String?
        /// The cache hint; present on 2026-07-28 and absent on legacy revisions.
        public let cacheHint: CacheHint?

        public init(skills: [Skill], nextCursor: String? = nil, cacheHint: CacheHint? = nil) {
            self.skills = skills
            self.nextCursor = nextCursor
            self.cacheHint = cacheHint
        }
    }
}

extension ListSkills.Result: Codable {
    private enum CodingKeys: String, CodingKey {
        case skills, nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            skills: try container.decode([Skill].self, forKey: .skills),
            nextCursor: try container.decodeIfPresent(String.self, forKey: .nextCursor),
            cacheHint: try CacheFields.decode(from: decoder)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(skills, forKey: .skills)
        try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
        try CacheFields.encode(cacheHint, to: encoder)
    }
}
