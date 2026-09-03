import Foundation

/// The single concrete, era-aware JSON codec used by MCP orchestration.
struct MessageCodec: Sendable {
    let era: ProtocolEra

    init(era: ProtocolEra) {
        self.era = era
    }

    func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        try validateModernWire(data)
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if T.self == ResultEnvelope.self {
            let normalized = try resultEnvelopeData(data)
            try validateModernWire(normalized)
            return try JSONDecoder().decode(type, from: normalized)
        }
        try validateModernWire(data)
        return try JSONDecoder().decode(type, from: data)
    }

    func decodeResultEnvelope(from data: Data) throws -> ResultEnvelope {
        let raw = try decodeRawValue(from: data)
        let result: Value
        if case .object(let fields) = raw, let responseResult = fields["result"] {
            result = responseResult
        } else {
            result = raw
        }
        return try decodeResultEnvelope(from: result)
    }

    func decodeResultEnvelope(from result: Value) throws -> ResultEnvelope {
        let normalizedResult = materializeDefaultResultType(result)
        if era.isModern {
            try validateModernResult(normalizedResult)
        }
        return try _protocolCoreDecodeValue(normalizedResult, as: ResultEnvelope.self)
    }

    private func validateModernWire(_ data: Data) throws {
        guard era.isModern else { return }
        let raw = try decodeRawValue(from: data)
        switch raw {
        case .array(let values):
            for value in values { try validateModernMessage(value) }
        default:
            try validateModernMessage(raw)
        }
    }

    private func validateModernMessage(_ value: Value) throws {
        guard case .object(let fields) = value else {
            throw ProtocolCoreError.malformedMessage("message must be an object")
        }
        if let rawJSONRPC = fields["jsonrpc"] {
            guard rawJSONRPC.stringValue == "2.0" else {
                throw ProtocolCoreError.malformedMessage("jsonrpc must be 2.0")
            }
        } else if fields["resultType"] == nil {
            throw ProtocolCoreError.malformedMessage("jsonrpc must be 2.0")
        }
        if fields["method"] != nil {
            guard fields["method"]?.stringValue != nil else {
                throw ProtocolCoreError.malformedMessage("method must be a string")
            }
            if fields["id"] != nil {
                try validateModernRequest(fields)
            }
            return
        }
        if let result = fields["result"] {
            guard fields["id"] != nil else {
                throw ProtocolCoreError.malformedMessage("response is missing id")
            }
            try validateModernResult(result)
            return
        }
        if fields["resultType"] != nil {
            try validateModernResult(value)
            return
        }
        if fields["error"] != nil {
            return
        }
        throw ProtocolCoreError.malformedMessage("message has no method, result, or error")
    }

    private func validateModernRequest(_ fields: [String: Value]) throws {
        guard case .object(let params) = fields["params"] else {
            throw ProtocolCoreError.missingRequestMetadata("_meta")
        }
        guard case .object(let metadata) = params["_meta"] else {
            throw ProtocolCoreError.missingRequestMetadata("_meta")
        }
        let requestMetadata = try _protocolCoreDecodeValue(
            .object(metadata),
            as: RequestMetadata.self
        )
        guard requestMetadata.protocolVersion == Version.modern else {
            throw MCPError.unsupportedProtocolVersion(
                requested: requestMetadata.protocolVersion,
                supported: [Version.modern]
            )
        }
    }

    private func validateModernResult(_ value: Value) throws {
        guard case .object(let fields) = value else {
            throw ProtocolCoreError.malformedMessage("result must be an object")
        }
        let resultType: ResultType
        if let rawValue = fields["resultType"] {
            guard let rawType = rawValue.stringValue else {
                throw ProtocolCoreError.invalidResultType
            }
            resultType = ResultType(rawValue: rawType)
        } else {
            resultType = .complete
        }
        if let cacheScope = fields["cacheScope"], fields["ttlMs"] == nil {
            _ = cacheScope
            throw ProtocolCoreError.invalidCacheHint
        }
        if fields["ttlMs"] != nil, fields["cacheScope"] == nil {
            throw ProtocolCoreError.invalidCacheHint
        }
        if fields["cacheScope"] != nil || fields["ttlMs"] != nil {
            _ = try _protocolCoreDecodeValue(
                .object([
                    "cacheScope": fields["cacheScope"] ?? .null,
                    "ttlMs": fields["ttlMs"] ?? .null,
                ]),
                as: CacheHint.self
            )
        }
        guard resultType == .complete || resultType == .inputRequired else {
            return
        }
        if let rawState = fields["requestState"], rawState.stringValue == nil {
            throw ProtocolCoreError.invalidResultInput
        }
        if let rawRequests = fields["inputRequests"], rawRequests.objectValue == nil {
            throw ProtocolCoreError.invalidResultInput
        }
        if resultType == .inputRequired {
            _ = try _protocolCoreDecodeValue(value, as: InputRequiredResult.self)
            return
        }
        if resultType == .complete {
            try _protocolCoreValidateResultTypeCombination(resultType, fields: fields)
        }
    }

    private func decodeRawValue(from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw ProtocolCoreError.malformedMessage(String(describing: error))
        }
    }

    private func materializeDefaultResultType(_ value: Value) -> Value {
        guard case .object(var fields) = value, fields["resultType"] == nil else {
            return value
        }
        fields["resultType"] = .string(ResultType.complete.rawValue)
        return .object(fields)
    }

    private func resultEnvelopeData(_ data: Data) throws -> Data {
        let raw = try decodeRawValue(from: data)
        let normalized: Value
        if case .object(var fields) = raw, let result = fields["result"] {
            fields["result"] = materializeDefaultResultType(result)
            normalized = .object(fields)
        } else {
            normalized = materializeDefaultResultType(raw)
        }
        return try JSONEncoder().encode(normalized)
    }
}
