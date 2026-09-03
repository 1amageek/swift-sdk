import Foundation

/// A raw result object used when the method-specific result type is not known.
public struct ResultEnvelope: Hashable, Codable, Sendable {
    public let resultType: ResultType
    public let metadata: ResultMetadata?
    public let cacheHint: CacheHint?
    public let fields: [String: Value]

    public init(
        resultType: ResultType = .complete,
        metadata: ResultMetadata? = nil,
        cacheHint: CacheHint? = nil,
        fields: [String: Value] = [:]
    ) {
        self.resultType = resultType
        self.metadata = metadata
        self.cacheHint = cacheHint
        self.fields = _protocolCoreSanitizeAdditionalFields(
            fields,
            excluding: ["resultType", "_meta", "cacheScope", "ttlMs"]
        )
    }

    public init(from decoder: Decoder) throws {
        let rawFields = try _protocolCoreDecodeObject(from: decoder, as: "result")
        let resultType: ResultType
        if let rawValue = rawFields["resultType"] {
            guard let rawType = rawValue.stringValue else {
                throw ProtocolCoreError.invalidResultType
            }
            resultType = ResultType(rawValue: rawType)
        } else {
            resultType = .complete
        }
        try _protocolCoreValidateResultTypeCombination(resultType, fields: rawFields)

        let metadata: ResultMetadata?
        if let value = rawFields["_meta"] {
            metadata = try _protocolCoreDecodeValue(value, as: ResultMetadata.self)
        } else {
            metadata = nil
        }

        let cacheHint: CacheHint?
        if rawFields["cacheScope"] != nil || rawFields["ttlMs"] != nil {
            cacheHint = try _protocolCoreDecodeValue(
                .object([
                    "cacheScope": rawFields["cacheScope"] ?? .null,
                    "ttlMs": rawFields["ttlMs"] ?? .null,
                ]),
                as: CacheHint.self
            )
        } else {
            cacheHint = nil
        }

        let reserved = Set(["resultType", "_meta", "cacheScope", "ttlMs"])
        self.init(
            resultType: resultType,
            metadata: metadata,
            cacheHint: cacheHint,
            fields: rawFields.filter { !reserved.contains($0.key) }
        )
    }

    public func encode(to encoder: Encoder) throws {
        try _protocolCoreValidateResultTypeCombination(resultType, fields: fields)
        if let cacheHint, cacheHint.ttlMs < 0 {
            throw ProtocolCoreError.invalidCacheHint
        }
        var rawFields = fields
        rawFields["resultType"] = .string(resultType.rawValue)
        if let metadata {
            rawFields["_meta"] = try Value(metadata)
        }
        if let cacheHint {
            rawFields["cacheScope"] = .string(cacheHint.scope.rawValue)
            rawFields["ttlMs"] = .int(cacheHint.ttlMs)
        }
        try Value.object(rawFields).encode(to: encoder)
    }
}
