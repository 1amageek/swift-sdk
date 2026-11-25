/// Reserved names of the MCP Skills extension (SEP-2640).
public enum SkillsExtension {
    /// The extension identifier used as the key in `capabilities.extensions`.
    public static let identifier = "io.modelcontextprotocol/skills"

    /// The prefix for extension-defined `_meta` keys.
    public static let metadataPrefix = "io.modelcontextprotocol.skills/"

    /// The MIME type that marks a directory resource.
    public static let directoryMimeType = "inode/directory"

    /// The file name that marks a skill root.
    public static let manifestFileName = "SKILL.md"

    /// The MIME type servers use for a `SKILL.md` resource.
    public static let manifestMimeType = "text/markdown"

    /// The URI scheme servers use for skill resources.
    public static let uriScheme = "skill"
}
