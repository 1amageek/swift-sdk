import Foundation

/// The wire contract selected for a connection or request.
public enum ProtocolEra: String, Codable, Hashable, Sendable {
    /// The session-oriented protocol family supported by previous SDK releases.
    case legacy
    /// The stateless per-request protocol family.
    case modern

    /// Creates an era from a protocol version.
    public init(version: String) throws {
        if version == Version.modern {
            self = .modern
        } else if Version.supported.contains(version) {
            self = .legacy
        } else {
            throw MCPError.unsupportedProtocolVersion(
                requested: version,
                supported: Version.supported.sorted() + [Version.modern]
            )
        }
    }

    /// Whether this era requires the 2026 per-request metadata contract.
    public var isModern: Bool { self == .modern }

    /// The canonical version for this era when one version is required.
    public var defaultVersion: String {
        switch self {
        case .legacy: return Version.latest
        case .modern: return Version.modern
        }
    }
}
