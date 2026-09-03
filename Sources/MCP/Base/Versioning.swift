import Foundation

/// The Model Context Protocol uses string-based version identifiers
/// following the format YYYY-MM-DD, to indicate
/// the last date backwards incompatible changes were made.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/
public enum Version {
    /// All protocol versions supported by this implementation, ordered from newest to oldest.
    public static let supported: Set<String> = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    /// The latest protocol version supported by this implementation.
    public static let latest = supported.max()!

    /// The stateless protocol revision introduced by the 2026 wire contract.
    public static let modern = "2026-07-28"

    /// All revisions understood by this SDK, including the modern revision.
    /// `supported` remains the legacy-only set for source compatibility.
    public static let allSupported: Set<String> = supported.union([modern])

    /// Negotiates the protocol version based on the client's request and server's capabilities.
    /// - Parameter clientRequestedVersion: The protocol version requested by the client.
    /// - Returns: The negotiated protocol version. If the client's requested version is supported,
    ///            that version is returned. Otherwise, the server's latest supported version is returned.
    static func negotiate(clientRequestedVersion: String) -> String {
        if supported.contains(clientRequestedVersion) {
            return clientRequestedVersion
        }
        return latest
    }

    /// Negotiates a mutually supported revision without silently selecting a
    /// revision outside the server's advertised set.
    public static func negotiate(
        clientRequestedVersion: String,
        serverSupportedVersions: Set<String>
    ) throws -> String {
        let mutual = allSupported.intersection(serverSupportedVersions)
        guard !mutual.isEmpty else {
            throw MCPError.negotiationFailed("No mutually supported protocol version")
        }
        if mutual.contains(clientRequestedVersion) {
            return clientRequestedVersion
        }
        guard let selected = mutual.max() else {
            throw MCPError.negotiationFailed("No mutually supported protocol version")
        }
        return selected
    }
}
