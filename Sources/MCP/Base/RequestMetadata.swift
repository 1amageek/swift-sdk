import Foundation

/// Required and optional metadata attached to a modern request.
public struct RequestMetadata: Hashable, Codable, Sendable {
    public static let protocolVersionKey = "io.modelcontextprotocol/protocolVersion"
    public static let clientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    public static let clientInfoKey = "io.modelcontextprotocol/clientInfo"
    public static let logLevelKey = "io.modelcontextprotocol/logLevel"
    public static let progressTokenKey = "progressToken"

    public let protocolVersion: String
    public let clientCapabilities: CapabilitySet
    public let clientInfo: ImplementationInfo?
    public let logLevel: String?
    public let progressToken: ProgressToken?
    public let additionalFields: [String: Value]

    public init(
        protocolVersion: String = Version.modern,
        clientCapabilities: CapabilitySet = .init(),
        clientInfo: ImplementationInfo? = nil,
        logLevel: String? = nil,
        progressToken: ProgressToken? = nil,
        additionalFields: [String: Value] = [:]
    ) throws {
        guard protocolVersion == Version.modern else {
            throw MCPError.unsupportedProtocolVersion(
                requested: protocolVersion,
                supported: [Version.modern]
            )
        }
        self.protocolVersion = protocolVersion
        self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo
        self.logLevel = logLevel
        self.progressToken = progressToken
        self.additionalFields = _protocolCoreSanitizeAdditionalFields(
            additionalFields,
            excluding: [
                Self.protocolVersionKey,
                Self.clientCapabilitiesKey,
                Self.clientInfoKey,
                Self.logLevelKey,
                Self.progressTokenKey,
            ]
        )
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "request metadata")
        guard let protocolVersion = fields[Self.protocolVersionKey]?.stringValue else {
            throw ProtocolCoreError.missingRequestMetadata(Self.protocolVersionKey)
        }
        guard let capabilityFields = fields[Self.clientCapabilitiesKey]?.objectValue else {
            throw ProtocolCoreError.missingRequestMetadata(Self.clientCapabilitiesKey)
        }

        let clientInfo: ImplementationInfo?
        if let value = fields[Self.clientInfoKey] {
            clientInfo = try _protocolCoreDecodeValue(value, as: ImplementationInfo.self)
        } else {
            clientInfo = nil
        }

        let logLevel: String?
        if let value = fields[Self.logLevelKey] {
            guard let string = value.stringValue else {
                throw ProtocolCoreError.invalidRequestMetadata(Self.logLevelKey)
            }
            logLevel = string
        } else {
            logLevel = nil
        }

        let progressToken: ProgressToken?
        if let value = fields[Self.progressTokenKey] {
            progressToken = try _protocolCoreDecodeValue(value, as: ProgressToken.self)
        } else {
            progressToken = nil
        }

        let reserved = Set([
            Self.protocolVersionKey,
            Self.clientCapabilitiesKey,
            Self.clientInfoKey,
            Self.logLevelKey,
            Self.progressTokenKey,
        ])
        try self.init(
            protocolVersion: protocolVersion,
            clientCapabilities: CapabilitySet(capabilityFields),
            clientInfo: clientInfo,
            logLevel: logLevel,
            progressToken: progressToken,
            additionalFields: fields.filter { !reserved.contains($0.key) }
        )
    }

    public func encode(to encoder: Encoder) throws {
        guard protocolVersion == Version.modern else {
            throw MCPError.unsupportedProtocolVersion(
                requested: protocolVersion,
                supported: [Version.modern]
            )
        }
        var fields = additionalFields
        fields[Self.protocolVersionKey] = .string(protocolVersion)
        fields[Self.clientCapabilitiesKey] = .object(clientCapabilities.fields)
        if let clientInfo {
            fields[Self.clientInfoKey] = try Value(clientInfo)
        }
        if let logLevel {
            fields[Self.logLevelKey] = .string(logLevel)
        }
        if let progressToken {
            fields[Self.progressTokenKey] = try Value(progressToken)
        }
        try Value.object(fields).encode(to: encoder)
    }
}
