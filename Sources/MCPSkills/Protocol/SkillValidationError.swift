/// A violation of the Skills extension's entry rules.
public enum SkillValidationError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The digest is not `sha256:` followed by 64 lowercase hex digits.
    case invalidDigest(String)
    /// A resource size is negative.
    case invalidSize(uri: String, size: Int)
    /// The entry URI is not a hierarchical `…/<skill-path>/SKILL.md` URI.
    case invalidSkillURI(String)
    /// The frontmatter name violates the Agent Skills naming rules.
    case invalidName(String)
    /// The final skill-path segment differs from the frontmatter name.
    case nameMismatch(name: String, uri: String)
    /// The frontmatter description is empty or longer than 1024 characters.
    case invalidDescription
    /// A listed manifest does not contain the entry's own `SKILL.md`.
    case missingManifestFile(uri: String)
    /// A manifest lists the same file more than once.
    case duplicateResource(uri: String)
    /// A manifest entry is not strictly inside the skill directory.
    case resourceOutsideSkill(uri: String)

    public var description: String {
        switch self {
        case .invalidDigest(let digest):
            "Invalid skill digest: \(digest)"
        case .invalidSize(let uri, let size):
            "Invalid size \(size) for \(uri)"
        case .invalidSkillURI(let uri):
            "Invalid skill URI: \(uri)"
        case .invalidName(let name):
            "Invalid skill name: \(name)"
        case .nameMismatch(let name, let uri):
            "Skill name \(name) does not match \(uri)"
        case .invalidDescription:
            "Skill description must contain 1 to 1024 characters"
        case .missingManifestFile(let uri):
            "Skill manifest does not list \(uri)"
        case .duplicateResource(let uri):
            "Skill manifest lists \(uri) more than once"
        case .resourceOutsideSkill(let uri):
            "Skill resource is outside the skill directory: \(uri)"
        }
    }
}
