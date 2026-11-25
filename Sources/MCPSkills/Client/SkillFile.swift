import Foundation

/// A skill file returned by ``SkillsClient/read(_:of:)`` after verification.
public struct SkillFile: Hashable, Sendable {
    /// How the content was checked.
    public enum Integrity: Hashable, Sendable {
        /// Size and digest matched the manifest entry.
        case verified
        /// The skill is dynamic, so no manifest entry exists to check against.
        case unverifiable
    }

    /// The URI that was read.
    public let uri: String
    /// The MIME type reported by the server.
    public let mimeType: String?
    /// The raw bytes.
    public let data: Data
    /// The integrity check that was applied.
    public let integrity: Integrity
    /// The parsed document when this is the skill's own `SKILL.md`; its
    /// frontmatter equals the entry's.
    public let markdown: SkillMarkdown?

    /// The content as text when the bytes are lossless UTF-8.
    public var text: String? { LosslessUTF8.decode(data) }
}
