/// A failure to install skills on a server.
public enum SkillsServerError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The Skills extension requires the server to declare `resources`.
    case resourcesCapabilityRequired
    /// The server already declares the Skills extension.
    case alreadyInstalled

    public var description: String {
        switch self {
        case .resourcesCapabilityRequired:
            "The Skills extension requires the resources capability"
        case .alreadyInstalled:
            "The Skills extension is already installed on this server"
        }
    }
}
