/// A failure to build a ``SkillCatalog``.
public enum SkillCatalogError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The catalog directory or one of its entries could not be read.
    case unreadable(path: String, reason: String)
    /// Under ``SkillCatalog/Policy/strict``, one or more skills are invalid.
    case invalidSkills([SkillCatalogIssue])
    /// The base URI is not of the form `<scheme>://…`.
    case invalidBaseURI(String)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason):
            "Cannot read \(path): \(reason)"
        case .invalidSkills(let issues):
            "Invalid skills: " + issues.map(\.description).joined(separator: "; ")
        case .invalidBaseURI(let uri):
            "Invalid skill base URI: \(uri)"
        }
    }
}
