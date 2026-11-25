/// Per-skill size limits.
///
/// Servers should not serve a skill beyond these limits, and hosts must
/// support skills up to them.
public struct SkillLimits: Hashable, Sendable {
    /// The maximum number of files in one skill.
    public let maxFiles: Int
    /// The maximum total byte count of one skill.
    public let maxBytes: Int

    /// The limits defined by the Skills extension: 512 files and 16 MiB.
    public static let specification = SkillLimits(uncheckedMaxFiles: 512, maxBytes: 16_777_216)

    /// Creates limits.
    ///
    /// - Precondition: Both values are positive.
    public init(maxFiles: Int, maxBytes: Int) {
        precondition(maxFiles > 0 && maxBytes > 0, "Skill limits must be positive")
        self.init(uncheckedMaxFiles: maxFiles, maxBytes: maxBytes)
    }

    private init(uncheckedMaxFiles maxFiles: Int, maxBytes: Int) {
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
    }
}
