import Foundation

/// A result that asks the client for additional input before another
/// independent request round.
public struct InputRequiredResult: Hashable, Codable, Sendable {
    public let resultType: ResultType
    public let inputRequests: InputRequests?
    public let requestState: String?
    public let metadata: ResultMetadata?
    public let additionalFields: [String: Value]

    public init(
        inputRequests: InputRequests? = nil,
        requestState: String? = nil,
        metadata: ResultMetadata? = nil,
        additionalFields: [String: Value] = [:]
    ) {
        self.resultType = .inputRequired
        self.inputRequests = inputRequests
        self.requestState = requestState
        self.metadata = metadata
        self.additionalFields = _protocolCoreSanitizeAdditionalFields(
            additionalFields,
            excluding: ["resultType", "inputRequests", "requestState", "_meta"]
        )
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "input-required result")
        guard let rawType = fields["resultType"]?.stringValue else {
            throw ProtocolCoreError.missingResultType
        }
        guard ResultType(rawValue: rawType) == .inputRequired else {
            throw ProtocolCoreError.invalidResultInput
        }

        let inputRequests: InputRequests?
        if let rawRequests = fields["inputRequests"] {
            guard let requestFields = rawRequests.objectValue else {
                throw ProtocolCoreError.invalidResultInput
            }
            var decoded: InputRequests = [:]
            decoded.reserveCapacity(requestFields.count)
            for (key, value) in requestFields {
                decoded[key] = try _protocolCoreDecodeValue(value, as: InputRequest.self)
            }
            inputRequests = decoded
        } else {
            inputRequests = nil
        }

        let requestState: String?
        if let rawState = fields["requestState"] {
            guard let state = rawState.stringValue else {
                throw ProtocolCoreError.invalidResultInput
            }
            requestState = state
        } else {
            requestState = nil
        }
        guard inputRequests != nil || requestState != nil else {
            throw ProtocolCoreError.invalidResultInput
        }

        let metadata: ResultMetadata?
        if let rawMetadata = fields["_meta"] {
            metadata = try _protocolCoreDecodeValue(rawMetadata, as: ResultMetadata.self)
        } else {
            metadata = nil
        }
        let reserved = Set(["resultType", "inputRequests", "requestState", "_meta"])
        self.init(
            inputRequests: inputRequests,
            requestState: requestState,
            metadata: metadata,
            additionalFields: fields.filter { !reserved.contains($0.key) }
        )
    }

    public func encode(to encoder: Encoder) throws {
        guard inputRequests != nil || requestState != nil else {
            throw ProtocolCoreError.invalidResultInput
        }

        var fields = additionalFields
        fields["resultType"] = .string(ResultType.inputRequired.rawValue)
        if let inputRequests {
            fields["inputRequests"] = try Value(inputRequests)
        }
        if let requestState {
            fields["requestState"] = .string(requestState)
        }
        if let metadata {
            fields["_meta"] = try Value(metadata)
        }
        try Value.object(fields).encode(to: encoder)
    }
}
