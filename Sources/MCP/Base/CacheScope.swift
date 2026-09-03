/// The scope of a cache hint; this does not create or own a cache.
public enum CacheScope: String, Codable, Hashable, Sendable {
    case `private`
    case `public`
}
