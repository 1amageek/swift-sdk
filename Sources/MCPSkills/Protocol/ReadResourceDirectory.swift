import MCP

/// `resources/directory/read`: lists the direct children of a directory
/// resource. Available only when the server declares `directoryRead: true`.
public enum ReadResourceDirectory: Method {
    public static let name = "resources/directory/read"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The directory URI.
        public let uri: String
        /// The opaque cursor from a previous page.
        public let cursor: String?

        public init(uri: String, cursor: String? = nil) {
            self.uri = uri
            self.cursor = cursor
        }
    }

    public struct Result: Hashable, Sendable {
        /// The direct children. Subdirectories carry the
        /// ``SkillsExtension/directoryMimeType``.
        public let resources: [Resource]
        /// The cursor of the next page, when one exists.
        public let nextCursor: String?
        /// The cache hint; present on 2026-07-28 and absent on legacy revisions.
        public let cacheHint: CacheHint?

        public init(resources: [Resource], nextCursor: String? = nil, cacheHint: CacheHint? = nil) {
            self.resources = resources
            self.nextCursor = nextCursor
            self.cacheHint = cacheHint
        }
    }
}

extension ReadResourceDirectory.Result: Codable {
    private enum CodingKeys: String, CodingKey {
        case resources, nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            resources: try container.decode([Resource].self, forKey: .resources),
            nextCursor: try container.decodeIfPresent(String.self, forKey: .nextCursor),
            cacheHint: try CacheFields.decode(from: decoder)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resources, forKey: .resources)
        try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
        try CacheFields.encode(cacheHint, to: encoder)
    }
}
