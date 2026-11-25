/// A `skills/list` entry that the client refused to surface.
///
/// Hosts must not load an invalid entry, and an entry whose URI appears more
/// than once is ambiguous, so every copy of it is refused.
public struct RejectedSkill: Hashable, Sendable {
    /// Why the entry was refused.
    public enum Reason: Hashable, Sendable {
        /// The entry does not decode as a skill.
        case malformed(String)
        /// The entry violates the extension's rules.
        case invalid(SkillValidationError)
        /// Another entry in the listing has the same URI.
        case duplicateURI
    }

    /// The entry URI, when one could be read.
    public let uri: String?
    /// Why the entry was refused.
    public let reason: Reason
}
