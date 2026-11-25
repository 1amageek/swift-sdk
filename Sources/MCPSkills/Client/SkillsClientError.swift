/// A Skills operation that the client refused or that failed verification.
public enum SkillsClientError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The client has no negotiated connection.
    case notConnected
    /// The server does not declare the Skills extension.
    case extensionNotSupported
    /// The server does not declare `directoryRead: true`.
    case directoryReadNotSupported
    /// A 2026-07-28 result lacks the required `ttlMs`/`cacheScope`.
    case missingCacheHint(method: String)
    /// A skill entry violates the extension's rules.
    case invalidEntry(SkillValidationError)
    /// `skills/get` returned a different skill than requested.
    case uriMismatch(requested: String, returned: String)
    /// A reference cannot be resolved inside the skill.
    case unresolvableReference(String)
    /// The file is not in the skill's manifest; nothing was requested.
    case unlistedResource(String)
    /// A dynamic skill reference leaves the skill directory; nothing was requested.
    case resourceOutsideSkill(String)
    /// The `resources/read` result has no contents for the requested URI.
    case missingContents(String)
    /// A blob is not valid base64.
    case invalidBlob(String)
    /// The byte count differs from the manifest entry.
    case sizeMismatch(uri: String, expected: Int, actual: Int)
    /// The SHA-256 digest differs from the manifest entry.
    case digestMismatch(uri: String, expected: SkillDigest, actual: SkillDigest)
    /// The fetched `SKILL.md` is not text or has unparsable frontmatter.
    case invalidFrontmatter(uri: String, SkillFrontmatterError)
    /// The fetched `SKILL.md` frontmatter differs from the entry in these fields.
    case frontmatterMismatch(uri: String, fields: [String])
    /// A dynamic read exceeded the per-skill byte limit.
    case limitExceeded(uri: String, bytes: Int)
    /// A listing returned a cursor it had already returned.
    case cursorCycle(String)
    /// A listing did not finish within the page limit.
    case pageLimitExceeded(Int)

    public var description: String {
        switch self {
        case .notConnected:
            "The client is not connected"
        case .extensionNotSupported:
            "The server does not declare the Skills extension"
        case .directoryReadNotSupported:
            "The server does not declare directoryRead"
        case .missingCacheHint(let method):
            "\(method) result lacks ttlMs/cacheScope"
        case .invalidEntry(let error):
            error.description
        case .uriMismatch(let requested, let returned):
            "Requested \(requested) but received \(returned)"
        case .unresolvableReference(let reference):
            "Cannot resolve \(reference) inside the skill"
        case .unlistedResource(let uri):
            "\(uri) is not listed in the skill manifest"
        case .resourceOutsideSkill(let uri):
            "\(uri) is outside the skill directory"
        case .missingContents(let uri):
            "No contents returned for \(uri)"
        case .invalidBlob(let uri):
            "Invalid base64 contents for \(uri)"
        case .sizeMismatch(let uri, let expected, let actual):
            "\(uri) has \(actual) bytes; the manifest lists \(expected)"
        case .digestMismatch(let uri, let expected, let actual):
            "\(uri) has digest \(actual); the manifest lists \(expected)"
        case .invalidFrontmatter(let uri, let error):
            "\(uri): \(error.description)"
        case .frontmatterMismatch(let uri, let fields):
            "\(uri) frontmatter differs in: \(fields.joined(separator: ", "))"
        case .limitExceeded(let uri, let bytes):
            "\(uri) has \(bytes) bytes, beyond the skill limit"
        case .cursorCycle(let cursor):
            "Listing repeated the cursor \(cursor)"
        case .pageLimitExceeded(let pages):
            "Listing did not finish within \(pages) pages"
        }
    }
}
