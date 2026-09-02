import Foundation

/// Acknowledges which subscription filters the server accepted.
public struct SubscriptionsAcknowledgedNotification: Notification {
    public static let name = "notifications/subscriptions/acknowledged"

    public init() {}

    public struct Parameters: Hashable, Codable, Sendable {
        public let subscriptionID: ID
        public let notifications: SubscriptionFilter
        public let metadata: NotificationMetadata
        public let additionalFields: [String: Value]

        public init(
            subscriptionID: ID,
            notifications: SubscriptionFilter,
            metadata: NotificationMetadata? = nil,
            additionalFields: [String: Value] = [:]
        ) {
            self.subscriptionID = subscriptionID
            self.notifications = notifications
            self.metadata = NotificationMetadata(
                subscriptionID: subscriptionID,
                additionalFields: metadata?.additionalFields ?? [:]
            )
            self.additionalFields = _protocolCoreSanitizeAdditionalFields(
                additionalFields,
                excluding: ["notifications", "_meta"]
            )
        }

        public init(from decoder: Decoder) throws {
            let fields = try _protocolCoreDecodeObject(from: decoder, as: "subscription acknowledgement")
            guard let rawMetadata = fields["_meta"] else {
                throw ProtocolCoreError.invalidResultInput
            }
            let metadata = try _protocolCoreDecodeValue(rawMetadata, as: NotificationMetadata.self)
            guard let subscriptionID = metadata.subscriptionID else {
                throw ProtocolCoreError.invalidResultInput
            }
            let notifications = try _protocolCoreDecodeValue(
                fields["notifications"] ?? .null,
                as: SubscriptionFilter.self
            )
            let reserved = Set(["_meta", "notifications"])
            self.init(
                subscriptionID: subscriptionID,
                notifications: notifications,
                metadata: metadata,
                additionalFields: fields.filter { !reserved.contains($0.key) }
            )
        }

        public func encode(to encoder: Encoder) throws {
            var fields = additionalFields
            fields["notifications"] = try Value(notifications)
            fields["_meta"] = try Value(metadata)
            try Value.object(fields).encode(to: encoder)
        }
    }
}
