import Foundation

/// The terminal result that closes a subscriptions/listen stream.
public struct SubscriptionsListenResult: Hashable, Codable, Sendable {
    public let resultType: ResultType
    public let subscriptionID: ID
    public let metadata: ResultMetadata?
    public let additionalFields: [String: Value]

    public init(
        subscriptionID: ID,
        metadata: ResultMetadata? = nil,
        additionalFields: [String: Value] = [:]
    ) {
        self.subscriptionID = subscriptionID
        self.metadata = metadata
        self.additionalFields = _protocolCoreSanitizeAdditionalFields(
            additionalFields,
            excluding: ["resultType", "_meta"]
        )
        self.resultType = .complete
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "subscription result")
        if let rawResultType = fields["resultType"],
            rawResultType.stringValue != ResultType.complete.rawValue
        {
            throw ProtocolCoreError.invalidResultType
        }
        guard let rawMetadata = fields["_meta"],
            let rawMetadataFields = rawMetadata.objectValue,
            let rawID = rawMetadataFields[NotificationMetadata.subscriptionIDKey]
        else {
            throw ProtocolCoreError.invalidResultInput
        }
        let subscriptionID = try _protocolCoreDecodeValue(rawID, as: ID.self)
        let decodedMetadata = try _protocolCoreDecodeValue(rawMetadata, as: ResultMetadata.self)
        let metadataFields = decodedMetadata.additionalFields.filter {
            $0.key != NotificationMetadata.subscriptionIDKey
        }
        let resultMetadata: ResultMetadata?
        if decodedMetadata.serverInfo == nil, metadataFields.isEmpty {
            resultMetadata = nil
        } else {
            resultMetadata = ResultMetadata(
                serverInfo: decodedMetadata.serverInfo,
                additionalFields: metadataFields
            )
        }
        let reserved = Set(["resultType", "_meta"])
        self.init(
            subscriptionID: subscriptionID,
            metadata: resultMetadata,
            additionalFields: fields.filter { !reserved.contains($0.key) }
        )
    }

    public func encode(to encoder: Encoder) throws {
        guard resultType == .complete else {
            throw ProtocolCoreError.invalidResultType
        }
        var fields = additionalFields
        fields["resultType"] = .string(resultType.rawValue)
        var metadataFields = metadata?.additionalFields ?? [:]
        if let serverInfo = metadata?.serverInfo {
            metadataFields[ResultMetadata.serverInfoKey] = try Value(serverInfo)
        }
        metadataFields[NotificationMetadata.subscriptionIDKey] = try Value(subscriptionID)
        fields["_meta"] = .object(metadataFields)
        try Value.object(fields).encode(to: encoder)
    }
}
