import Foundation

/// Request parameters for a modern subscriptions/listen request.
public enum SubscriptionsListenRequest: Method {
    public static let name = "subscriptions/listen"
    public typealias Result = SubscriptionsListenResult

    public struct Parameters: Hashable, Codable, Sendable {
        public let notifications: SubscriptionFilter
        public let metadata: RequestMetadata
        public let additionalFields: [String: Value]

        public init(
            notifications: SubscriptionFilter,
            metadata: RequestMetadata,
            additionalFields: [String: Value] = [:]
        ) {
            self.notifications = notifications
            self.metadata = metadata
            self.additionalFields = _protocolCoreSanitizeAdditionalFields(
                additionalFields,
                excluding: ["notifications", "_meta"]
            )
        }

        public init(from decoder: Decoder) throws {
            let fields = try _protocolCoreDecodeObject(from: decoder, as: "subscription parameters")
            let notifications = try _protocolCoreDecodeValue(
                fields["notifications"] ?? .null,
                as: SubscriptionFilter.self
            )
            guard let rawMetadata = fields["_meta"] else {
                throw ProtocolCoreError.missingRequestMetadata("_meta")
            }
            let metadata = try _protocolCoreDecodeValue(rawMetadata, as: RequestMetadata.self)
            self.init(
                notifications: notifications,
                metadata: metadata,
                additionalFields: fields.filter { $0.key != "notifications" && $0.key != "_meta" }
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
