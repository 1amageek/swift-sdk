import Foundation

/// A state-free request parameter object for modern methods that only need `_meta`.
public struct ModernRequestParameters: Hashable, Codable, Sendable {
    public let metadata: RequestMetadata
    public let additionalFields: [String: Value]

    public init(
        metadata: RequestMetadata,
        additionalFields: [String: Value] = [:]
    ) {
        self.metadata = metadata
        self.additionalFields = _protocolCoreSanitizeAdditionalFields(
            additionalFields,
            excluding: ["_meta"]
        )
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "modern request parameters")
        guard let metadataValue = fields["_meta"] else {
            throw ProtocolCoreError.missingRequestMetadata("_meta")
        }
        let metadata = try _protocolCoreDecodeValue(metadataValue, as: RequestMetadata.self)
        self.init(
            metadata: metadata,
            additionalFields: fields.filter { $0.key != "_meta" }
        )
    }

    public func encode(to encoder: Encoder) throws {
        var fields = additionalFields
        fields["_meta"] = try Value(metadata)
        try Value.object(fields).encode(to: encoder)
    }
}
