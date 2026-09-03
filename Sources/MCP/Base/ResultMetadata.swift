import Foundation

/// Optional metadata attached to a modern result.
public struct ResultMetadata: Hashable, Codable, Sendable {
    public static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
    private static let reservedKeys: Set<String> = [
        serverInfoKey,
        NotificationMetadata.subscriptionIDKey,
    ]

    public let serverInfo: ImplementationInfo?
    public let additionalFields: [String: Value]

    public init(
        serverInfo: ImplementationInfo? = nil,
        additionalFields: [String: Value] = [:]
    ) {
        self.serverInfo = serverInfo
        self.additionalFields = _protocolCoreSanitizeAdditionalFields(
            additionalFields,
            excluding: Self.reservedKeys
        )
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "result metadata")
        let serverInfo: ImplementationInfo?
        if let value = fields[Self.serverInfoKey] {
            serverInfo = try _protocolCoreDecodeValue(value, as: ImplementationInfo.self)
        } else {
            serverInfo = nil
        }
        self.init(
            serverInfo: serverInfo,
            additionalFields: fields.filter { !Self.reservedKeys.contains($0.key) }
        )
    }

    public func encode(to encoder: Encoder) throws {
        var fields = additionalFields
        if let serverInfo {
            fields[Self.serverInfoKey] = try Value(serverInfo)
        }
        try Value.object(fields).encode(to: encoder)
    }
}
