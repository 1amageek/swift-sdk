import MCP

/// The settings object a server declares for the Skills extension.
///
/// Any JSON object under `capabilities.extensions["io.modelcontextprotocol/skills"]`
/// is a declaration. Only a literal `directoryRead: true` enables
/// `resources/directory/read`; any other value leaves it disabled.
public struct SkillsCapability: Hashable, Sendable {
    /// Whether the server implements `resources/directory/read`.
    public var directoryRead: Bool

    public init(directoryRead: Bool = false) {
        self.directoryRead = directoryRead
    }

    /// Reads the declaration from a negotiated capability set.
    ///
    /// - Returns: `nil` when the extension is not declared with an object value.
    public init?(declaredIn capabilities: CapabilitySet) {
        guard let settings = capabilities.extensions?[SkillsExtension.identifier],
            case .object(let fields) = settings
        else {
            return nil
        }
        self.directoryRead = fields["directoryRead"] == .bool(true)
    }

    /// The settings object written to `capabilities.extensions`.
    public var settings: Value {
        directoryRead ? .object(["directoryRead": .bool(true)]) : .object([:])
    }
}
