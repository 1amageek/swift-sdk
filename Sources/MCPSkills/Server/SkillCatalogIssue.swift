/// A problem found while building a ``SkillCatalog``.
public struct SkillCatalogIssue: Hashable, Sendable, CustomStringConvertible {
    /// What is wrong.
    public enum Kind: Hashable, Sendable {
        /// A `SKILL.md` sits at the catalog root, so it has no skill path.
        case manifestAtRoot
        /// A symbolic link or special file was found.
        case unsupportedFile
        /// `SKILL.md` is not valid UTF-8.
        case manifestNotUTF8
        /// The `SKILL.md` frontmatter could not be parsed.
        case invalidFrontmatter(SkillFrontmatterError)
        /// The skill entry violates the extension's rules.
        case invalidEntry(SkillValidationError)
        /// The skill exceeds the catalog's ``SkillLimits``.
        case limitExceeded(files: Int, bytes: Int)
    }

    /// The `/`-separated path of the affected skill directory or file,
    /// relative to the catalog root.
    public let path: String
    /// The problem.
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }

    public var description: String {
        let detail: String
        switch kind {
        case .manifestAtRoot:
            detail = "SKILL.md at the catalog root has no skill path"
        case .unsupportedFile:
            detail = "symbolic links and special files are not served"
        case .manifestNotUTF8:
            detail = "SKILL.md is not valid UTF-8"
        case .invalidFrontmatter(let error):
            detail = error.description
        case .invalidEntry(let error):
            detail = error.description
        case .limitExceeded(let files, let bytes):
            detail = "skill has \(files) files and \(bytes) bytes, beyond the catalog limits"
        }
        return "\(path.isEmpty ? "." : path): \(detail)"
    }
}
