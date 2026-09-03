import Foundation

/// A cache freshness hint carried by cacheable results.
public struct CacheHint: Hashable, Codable, Sendable {
    public let scope: CacheScope
    public let ttlMs: Int

    public init(scope: CacheScope, ttlMs: Int) throws {
        guard ttlMs >= 0 else { throw ProtocolCoreError.invalidCacheHint }
        self.scope = scope
        self.ttlMs = ttlMs
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "cache hint")
        guard let scopeValue = fields["cacheScope"]?.stringValue,
            let scope = CacheScope(rawValue: scopeValue),
            let ttlMs = fields["ttlMs"]?.intValue,
            ttlMs >= 0
        else {
            throw ProtocolCoreError.invalidCacheHint
        }
        try self.init(scope: scope, ttlMs: ttlMs)
    }

    public func encode(to encoder: Encoder) throws {
        guard ttlMs >= 0 else { throw ProtocolCoreError.invalidCacheHint }
        try Value.object([
            "cacheScope": .string(scope.rawValue),
            "ttlMs": .int(ttlMs),
        ]).encode(to: encoder)
    }
}
