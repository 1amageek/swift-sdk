import Foundation

/// The protocol facts learned during connection or discovery.
public struct ConnectionInfo: Hashable, Codable, Sendable {
    public let era: ProtocolEra
    public let protocolVersion: String
    public let serverCapabilities: CapabilitySet
    public let serverInfo: ImplementationInfo?
    public let instructions: String?

    public init(
        era: ProtocolEra,
        protocolVersion: String,
        serverCapabilities: CapabilitySet = .init(),
        serverInfo: ImplementationInfo? = nil,
        instructions: String? = nil
    ) throws {
        let validVersion = switch era {
        case .legacy:
            Version.supported.contains(protocolVersion)
        case .modern:
            protocolVersion == Version.modern
        }
        guard validVersion else {
            throw ProtocolCoreError.invalidConnectionInfo(
                "era \(era.rawValue) does not match version \(protocolVersion)"
            )
        }
        self.era = era
        self.protocolVersion = protocolVersion
        self.serverCapabilities = serverCapabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }

    public init(
        protocolVersion: String,
        serverCapabilities: CapabilitySet = .init(),
        serverInfo: ImplementationInfo? = nil,
        instructions: String? = nil
    ) throws {
        let era = try ProtocolEra(version: protocolVersion)
        try self.init(
            era: era,
            protocolVersion: protocolVersion,
            serverCapabilities: serverCapabilities,
            serverInfo: serverInfo,
            instructions: instructions
        )
    }

    private enum CodingKeys: String, CodingKey {
        case era, protocolVersion, serverCapabilities, serverInfo, instructions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            era: container.decode(ProtocolEra.self, forKey: .era),
            protocolVersion: container.decode(String.self, forKey: .protocolVersion),
            serverCapabilities: container.decodeIfPresent(CapabilitySet.self, forKey: .serverCapabilities) ?? .init(),
            serverInfo: container.decodeIfPresent(ImplementationInfo.self, forKey: .serverInfo),
            instructions: container.decodeIfPresent(String.self, forKey: .instructions)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(era, forKey: .era)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(serverCapabilities, forKey: .serverCapabilities)
        try container.encodeIfPresent(serverInfo, forKey: .serverInfo)
        try container.encodeIfPresent(instructions, forKey: .instructions)
    }
}
