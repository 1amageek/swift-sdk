import Foundation

/// A discovery result describing supported versions and server capabilities.
public struct DiscoverResult: Hashable, Codable, Sendable {
    public let supportedVersions: [String]
    public let capabilities: CapabilitySet
    public let instructions: String?
    public let cacheHint: CacheHint
    public let resultType: ResultType
    public let metadata: ResultMetadata?
    public let additionalFields: [String: Value]

    public init(
        supportedVersions: [String],
        capabilities: CapabilitySet = .init(),
        instructions: String? = nil,
        cacheHint: CacheHint,
        metadata: ResultMetadata? = nil,
        additionalFields: [String: Value] = [:]
    ) {
        self.supportedVersions = supportedVersions
        self.capabilities = capabilities
        self.instructions = instructions
        self.cacheHint = cacheHint
        self.resultType = .complete
        self.metadata = metadata
        self.additionalFields = _protocolCoreSanitizeAdditionalFields(
            additionalFields,
            excluding: [
                "supportedVersions", "capabilities", "instructions",
                "cacheScope", "ttlMs", "resultType", "_meta",
            ]
        )
    }

    public func encode(to encoder: Encoder) throws {
        guard cacheHint.ttlMs >= 0 else {
            throw ProtocolCoreError.invalidCacheHint
        }
        var fields = additionalFields
        fields["supportedVersions"] = .array(supportedVersions.map(Value.string))
        fields["capabilities"] = .object(capabilities.fields)
        if let instructions {
            fields["instructions"] = .string(instructions)
        }
        fields["cacheScope"] = .string(cacheHint.scope.rawValue)
        fields["ttlMs"] = .int(cacheHint.ttlMs)
        fields["resultType"] = .string(resultType.rawValue)
        if let metadata {
            fields["_meta"] = try Value(metadata)
        }
        try Value.object(fields).encode(to: encoder)
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "discovery result")
        guard let rawVersions = fields["supportedVersions"]?.arrayValue else {
            throw ProtocolCoreError.malformedMessage("supportedVersions must be an array")
        }
        var supportedVersions: [String] = []
        supportedVersions.reserveCapacity(rawVersions.count)
        for value in rawVersions {
            guard let version = value.stringValue else {
                throw ProtocolCoreError.malformedMessage("supportedVersions must contain strings")
            }
            supportedVersions.append(version)
        }
        guard let capabilityFields = fields["capabilities"]?.objectValue else {
            throw ProtocolCoreError.malformedMessage("capabilities must be an object")
        }
        let instructions: String?
        if let value = fields["instructions"] {
            guard let string = value.stringValue else {
                throw ProtocolCoreError.malformedMessage("instructions must be a string")
            }
            instructions = string
        } else {
            instructions = nil
        }
        if let rawResultType = fields["resultType"],
            rawResultType.stringValue != ResultType.complete.rawValue
        {
            throw ProtocolCoreError.invalidResultType
        }
        let cacheHint = try _protocolCoreDecodeValue(
            .object([
                "cacheScope": fields["cacheScope"] ?? .null,
                "ttlMs": fields["ttlMs"] ?? .null,
            ]),
            as: CacheHint.self
        )
        let metadata: ResultMetadata?
        if let value = fields["_meta"] {
            metadata = try _protocolCoreDecodeValue(value, as: ResultMetadata.self)
        } else {
            metadata = nil
        }
        let reserved = Set([
            "supportedVersions", "capabilities", "instructions",
            "cacheScope", "ttlMs", "resultType", "_meta",
        ])
        self.init(
            supportedVersions: supportedVersions,
            capabilities: CapabilitySet(capabilityFields),
            instructions: instructions,
            cacheHint: cacheHint,
            metadata: metadata,
            additionalFields: fields.filter { !reserved.contains($0.key) }
        )
    }
}
