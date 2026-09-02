import Foundation

/// Request parameters that carry responses and opaque state to a subsequent
/// independent request round.
public struct InputResponseRequestParams: Hashable, Codable, Sendable {
    public let metadata: RequestMetadata
    public let inputResponses: InputResponses?
    public let requestState: String?
    public let additionalFields: [String: Value]

    public init(
        metadata: RequestMetadata,
        requestState: String? = nil,
        inputResponses: InputResponses? = nil,
        additionalFields: [String: Value] = [:]
    ) {
        self.metadata = metadata
        self.requestState = requestState
        self.inputResponses = inputResponses
        self.additionalFields = _protocolCoreSanitizeAdditionalFields(
            additionalFields,
            excluding: ["_meta", "requestState", "inputResponses"]
        )
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "input response parameters")
        guard let rawMetadata = fields["_meta"] else {
            throw ProtocolCoreError.missingRequestMetadata("_meta")
        }
        let metadata = try _protocolCoreDecodeValue(rawMetadata, as: RequestMetadata.self)
        let requestState: String?
        if let rawState = fields["requestState"] {
            guard let state = rawState.stringValue else {
                throw ProtocolCoreError.invalidResultInput
            }
            requestState = state
        } else {
            requestState = nil
        }
        let inputResponses: InputResponses?
        if let rawResponses = fields["inputResponses"] {
            guard let responseFields = rawResponses.objectValue else {
                throw ProtocolCoreError.invalidResultInput
            }
            var decoded: InputResponses = [:]
            decoded.reserveCapacity(responseFields.count)
            for (key, value) in responseFields {
                decoded[key] = try _protocolCoreDecodeValue(value, as: InputResponse.self)
            }
            inputResponses = decoded
        } else {
            inputResponses = nil
        }
        let reserved = Set(["_meta", "requestState", "inputResponses"])
        self.init(
            metadata: metadata,
            requestState: requestState,
            inputResponses: inputResponses,
            additionalFields: fields.filter { !reserved.contains($0.key) }
        )
    }

    public func encode(to encoder: Encoder) throws {
        var fields = additionalFields
        fields["_meta"] = try Value(metadata)
        if let requestState {
            fields["requestState"] = .string(requestState)
        }
        if let inputResponses {
            fields["inputResponses"] = try Value(inputResponses)
        }
        try Value.object(fields).encode(to: encoder)
    }
}
