import Foundation

/// The opt-in notification classes carried by a subscriptions/listen request.
public struct SubscriptionFilter: Hashable, Codable, Sendable {
    public let toolsListChanged: Bool?
    public let promptsListChanged: Bool?
    public let resourcesListChanged: Bool?
    public let resourceSubscriptions: [String]?
    public let additionalFields: [String: Value]

    public init(
        toolsListChanged: Bool? = nil,
        promptsListChanged: Bool? = nil,
        resourcesListChanged: Bool? = nil,
        resourceSubscriptions: [String]? = nil,
        additionalFields: [String: Value] = [:]
    ) {
        self.toolsListChanged = toolsListChanged
        self.promptsListChanged = promptsListChanged
        self.resourcesListChanged = resourcesListChanged
        self.resourceSubscriptions = resourceSubscriptions
        self.additionalFields = _protocolCoreSanitizeAdditionalFields(
            additionalFields,
            excluding: [
                "toolsListChanged", "promptsListChanged", "resourcesListChanged",
                "resourceSubscriptions",
            ]
        )
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "subscription filter")
        func decodeBool(_ key: String) throws -> Bool? {
            guard let value = fields[key] else { return nil }
            guard let bool = value.boolValue else {
                throw ProtocolCoreError.invalidSubscriptionFilter("\(key) must be a boolean")
            }
            return bool
        }
        let resources: [String]?
        if let value = fields["resourceSubscriptions"] {
            guard case .array(let values) = value else {
                throw ProtocolCoreError.invalidSubscriptionFilter("resourceSubscriptions must be an array")
            }
            var decoded: [String] = []
            decoded.reserveCapacity(values.count)
            for value in values {
                guard let uri = value.stringValue else {
                    throw ProtocolCoreError.invalidSubscriptionFilter(
                        "resourceSubscriptions must contain only strings"
                    )
                }
                decoded.append(uri)
            }
            resources = decoded
        } else {
            resources = nil
        }
        let reserved = Set([
            "toolsListChanged", "promptsListChanged", "resourcesListChanged",
            "resourceSubscriptions",
        ])
        self.init(
            toolsListChanged: try decodeBool("toolsListChanged"),
            promptsListChanged: try decodeBool("promptsListChanged"),
            resourcesListChanged: try decodeBool("resourcesListChanged"),
            resourceSubscriptions: resources,
            additionalFields: fields.filter { !reserved.contains($0.key) }
        )
    }

    public func encode(to encoder: Encoder) throws {
        var fields = additionalFields
        if let toolsListChanged { fields["toolsListChanged"] = .bool(toolsListChanged) }
        if let promptsListChanged { fields["promptsListChanged"] = .bool(promptsListChanged) }
        if let resourcesListChanged { fields["resourcesListChanged"] = .bool(resourcesListChanged) }
        if let resourceSubscriptions {
            fields["resourceSubscriptions"] = .array(resourceSubscriptions.map(Value.string))
        }
        try Value.object(fields).encode(to: encoder)
    }
}
