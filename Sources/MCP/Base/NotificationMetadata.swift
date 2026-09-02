import Foundation

/// Optional metadata attached to a modern notification.
public struct NotificationMetadata: Hashable, Codable, Sendable {
    public static let subscriptionIDKey = "io.modelcontextprotocol/subscriptionId"

    public let subscriptionID: ID?
    public let additionalFields: [String: Value]

    public init(
        subscriptionID: ID? = nil,
        additionalFields: [String: Value] = [:]
    ) {
        self.subscriptionID = subscriptionID
        self.additionalFields = _protocolCoreSanitizeAdditionalFields(
            additionalFields,
            excluding: [Self.subscriptionIDKey]
        )
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "notification metadata")
        let subscriptionID: ID?
        if let value = fields[Self.subscriptionIDKey] {
            subscriptionID = try _protocolCoreDecodeValue(value, as: ID.self)
        } else {
            subscriptionID = nil
        }
        self.init(
            subscriptionID: subscriptionID,
            additionalFields: fields.filter { $0.key != Self.subscriptionIDKey }
        )
    }

    public func encode(to encoder: Encoder) throws {
        var fields = additionalFields
        if let subscriptionID {
            fields[Self.subscriptionIDKey] = try Value(subscriptionID)
        }
        try Value.object(fields).encode(to: encoder)
    }
}
