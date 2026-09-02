import Foundation

/// A state-free server-initiated input request.
public struct InputRequest: Hashable, Codable, Sendable {
    public let method: InputRequestMethod
    public let params: Value?
    public let additionalFields: [String: Value]

    public init(
        method: InputRequestMethod,
        params: Value? = nil,
        additionalFields: [String: Value] = [:]
    ) {
        self.method = method
        self.params = params
        self.additionalFields = _protocolCoreSanitizeAdditionalFields(
            additionalFields,
            excluding: ["method", "params"]
        )
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "input request")
        guard let rawMethod = fields["method"]?.stringValue else {
            throw ProtocolCoreError.invalidInputRequest("method must be a string")
        }
        guard let method = InputRequestMethod(rawValue: rawMethod) else {
            throw ProtocolCoreError.unsupportedInputMethod(rawMethod)
        }

        let params: Value?
        if let rawParams = fields["params"] {
            guard rawParams.objectValue != nil else {
                throw ProtocolCoreError.invalidInputRequest("params must be an object")
            }
            params = rawParams
        } else {
            params = nil
        }
        if method != .rootsList, params == nil {
            throw ProtocolCoreError.invalidInputRequest("params is required for \(rawMethod)")
        }

        self.init(
            method: method,
            params: params,
            additionalFields: fields.filter { $0.key != "method" && $0.key != "params" }
        )
    }

    public func encode(to encoder: Encoder) throws {
        if method != .rootsList, params == nil {
            throw ProtocolCoreError.invalidInputRequest("params is required for \(method.rawValue)")
        }
        if let params, params.objectValue == nil {
            throw ProtocolCoreError.invalidInputRequest("params must be an object")
        }

        var fields = additionalFields
        fields["method"] = .string(method.rawValue)
        if let params {
            fields["params"] = params
        }
        try Value.object(fields).encode(to: encoder)
    }
}

/// Server-assigned identifiers and their input requests.
public typealias InputRequests = [String: InputRequest]
