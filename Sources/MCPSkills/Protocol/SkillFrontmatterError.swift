/// A `SKILL.md` frontmatter that cannot be represented as a skill entry.
///
/// Parsing fails closed: YAML constructs outside the supported subset are
/// errors rather than guesses.
public enum SkillFrontmatterError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The document does not start with a `---` line.
    case missingOpeningDelimiter
    /// No closing `---` line follows the opening delimiter.
    case missingClosingDelimiter
    /// The YAML text could not be parsed.
    case invalidYAML(String)
    /// The frontmatter is not a mapping.
    case notAMapping
    /// A mapping key is not a string.
    case nonStringKey
    /// A mapping contains the same key twice.
    case duplicateKey(String)
    /// The YAML uses an anchor or alias.
    case anchorsNotSupported
    /// The YAML uses an explicit tag other than `!` or `!!str`.
    case unsupportedTag(String)
    /// A number cannot be represented as a finite JSON number.
    case unrepresentableNumber(String)
    /// The YAML nests deeper than the supported depth.
    case nestingTooDeep
    /// A required field is missing or not a string.
    case missingField(String)

    public var description: String {
        switch self {
        case .missingOpeningDelimiter:
            "SKILL.md must begin with a --- frontmatter delimiter"
        case .missingClosingDelimiter:
            "SKILL.md frontmatter has no closing --- delimiter"
        case .invalidYAML(let detail):
            "Invalid YAML frontmatter: \(detail)"
        case .notAMapping:
            "Frontmatter must be a YAML mapping"
        case .nonStringKey:
            "Frontmatter keys must be strings"
        case .duplicateKey(let key):
            "Frontmatter repeats the key \(key)"
        case .anchorsNotSupported:
            "Frontmatter anchors and aliases are not supported"
        case .unsupportedTag(let tag):
            "Frontmatter tag \(tag) is not supported"
        case .unrepresentableNumber(let text):
            "Frontmatter number \(text) cannot be represented"
        case .nestingTooDeep:
            "Frontmatter nests too deeply"
        case .missingField(let field):
            "Frontmatter field \(field) must be a string"
        }
    }
}
