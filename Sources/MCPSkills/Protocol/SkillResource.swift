/// One file listed in a skill's manifest.
public struct SkillResource: Hashable, Codable, Sendable {
    /// The file URI, readable with `resources/read`.
    public let uri: String
    /// The digest of the file's raw bytes.
    public let digest: SkillDigest
    /// The raw byte count covered by ``digest``.
    public let size: Int

    public init(uri: String, digest: SkillDigest, size: Int) {
        self.uri = uri
        self.digest = digest
        self.size = size
    }
}
