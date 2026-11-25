import MCP

/// Reads and writes the `ttlMs` / `cacheScope` members that Skills results
/// carry inline on 2026-07-28 and omit on legacy revisions.
enum CacheFields {
    enum Key: String, CodingKey {
        case ttlMs, cacheScope
    }

    /// Decodes the inline cache hint, or `nil` when neither member is present.
    static func decode(from decoder: Decoder) throws -> CacheHint? {
        let container = try decoder.container(keyedBy: Key.self)
        guard container.contains(.ttlMs) || container.contains(.cacheScope) else {
            return nil
        }
        return try CacheHint(from: decoder)
    }

    /// Encodes the cache hint inline when present.
    static func encode(_ cacheHint: CacheHint?, to encoder: Encoder) throws {
        guard let cacheHint else { return }
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(cacheHint.ttlMs, forKey: .ttlMs)
        try container.encode(cacheHint.scope, forKey: .cacheScope)
    }
}
