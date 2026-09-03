import Foundation

/// A state-free response to one of the allowed input request methods.
public struct InputResponse: Hashable, Codable, Sendable {
    public let value: Value

    /// Creates a response after validating it against the originating request
    /// method. The method is not stored because the wire value is an open union.
    public init(method: InputRequestMethod, value: Value) throws {
        try Self.validate(value, for: method)
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let fields = try _protocolCoreDecodeObject(from: decoder, as: "input response")
        let value = Value.object(fields)

        // Input responses are an open union: each official member allows
        // additional properties. Try each complete member validator instead
        // of inferring or storing a discriminator-like method.
        for method in [
            InputRequestMethod.samplingCreateMessage,
            .rootsList,
            .elicitationCreate,
        ] {
            do {
                try Self.validate(value, for: method)
                self.value = value
                return
            } catch {
                continue
            }
        }
        throw ProtocolCoreError.invalidInputResponse("response does not match an allowed method")
    }

    public func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    /// Validates this response against the method of the originating request.
    /// The method is supplied by the orchestration layer because the wire
    /// union itself does not carry an authoritative method discriminator.
    func validate(for method: InputRequestMethod) throws {
        try Self.validate(value, for: method)
    }

    private static func validate(_ value: Value, for method: InputRequestMethod) throws {
        guard case .object(let fields) = value else {
            throw ProtocolCoreError.invalidInputResponse("response must be an object")
        }
        switch method {
        case .samplingCreateMessage:
            try validateSampling(fields)
        case .rootsList:
            try validateRoots(fields)
        case .elicitationCreate:
            try validateElicitation(fields)
        }
    }

    private static func validateSampling(_ fields: [String: Value]) throws {
        guard fields["model"]?.stringValue != nil else {
            throw ProtocolCoreError.invalidInputResponse("sampling response requires model")
        }
        guard let role = fields["role"]?.stringValue,
            role == "user" || role == "assistant"
        else {
            throw ProtocolCoreError.invalidInputResponse("sampling response role is invalid")
        }
        guard let content = fields["content"] else {
            throw ProtocolCoreError.invalidInputResponse("sampling response requires content")
        }
        try validateSamplingContent(content)
        if let stopReason = fields["stopReason"], stopReason.stringValue == nil {
            throw ProtocolCoreError.invalidInputResponse("sampling response stopReason must be a string")
        }
        if let metadata = fields["_meta"], metadata.objectValue == nil {
            throw ProtocolCoreError.invalidInputResponse("sampling response _meta must be an object")
        }
    }

    private static func validateSamplingContent(_ value: Value) throws {
        switch value {
        case .array(let blocks):
            for block in blocks {
                try validateSamplingContentBlock(block)
            }
        case .object:
            try validateSamplingContentBlock(value)
        default:
            throw ProtocolCoreError.invalidInputResponse("sampling response content must be a block or array")
        }
    }

    private static func validateSamplingContentBlock(_ value: Value) throws {
        guard case .object(let fields) = value,
            let type = fields["type"]?.stringValue
        else {
            throw ProtocolCoreError.invalidInputResponse("sampling content blocks require an object type")
        }
        switch type {
        case "text":
            guard fields["text"]?.stringValue != nil else {
                throw ProtocolCoreError.invalidInputResponse("text content requires text")
            }
            try validateContentMetadata(fields, subject: "text content")
        case "image", "audio":
            guard fields["data"]?.stringValue != nil,
                fields["mimeType"]?.stringValue != nil
            else {
                throw ProtocolCoreError.invalidInputResponse("media content requires data and mimeType")
            }
            try validateContentMetadata(fields, subject: "media content")
        case "tool_use":
            guard fields["id"]?.stringValue != nil,
                fields["name"]?.stringValue != nil,
                fields["input"]?.objectValue != nil
            else {
                throw ProtocolCoreError.invalidInputResponse("tool_use content requires id, name, and input")
            }
            try validateContentMetadata(fields, subject: "tool_use content")
        case "tool_result":
            guard fields["toolUseId"]?.stringValue != nil,
                let nested = fields["content"]?.arrayValue
            else {
                throw ProtocolCoreError.invalidInputResponse("tool_result content requires toolUseId and content")
            }
            for block in nested {
                try validateToolResultContentBlock(block)
            }
            if let isError = fields["isError"], isError.boolValue == nil {
                throw ProtocolCoreError.invalidInputResponse("tool_result isError must be a boolean")
            }
            try validateContentMetadata(fields, subject: "tool_result content")
        default:
            throw ProtocolCoreError.invalidInputResponse("sampling content type is unsupported")
        }
    }

    private static func validateToolResultContentBlock(_ value: Value) throws {
        guard case .object(let fields) = value,
            let type = fields["type"]?.stringValue
        else {
            throw ProtocolCoreError.invalidInputResponse("tool result content blocks require an object type")
        }
        switch type {
        case "text":
            guard fields["text"]?.stringValue != nil else {
                throw ProtocolCoreError.invalidInputResponse("text tool result content requires text")
            }
            try validateContentMetadata(fields, subject: "text tool result content")
        case "image", "audio":
            guard fields["data"]?.stringValue != nil,
                fields["mimeType"]?.stringValue != nil
            else {
                throw ProtocolCoreError.invalidInputResponse("media tool result content requires data and mimeType")
            }
            try validateContentMetadata(fields, subject: "media tool result content")
        case "resource":
            try validateEmbeddedResource(fields["resource"])
            try validateContentMetadata(fields, subject: "embedded resource content")
        case "resource_link":
            guard fields["uri"]?.stringValue != nil,
                fields["name"]?.stringValue != nil
            else {
                throw ProtocolCoreError.invalidInputResponse("resource_link content requires uri and name")
            }
            try validateOptionalString(fields["title"], named: "resource_link title")
            try validateOptionalString(fields["description"], named: "resource_link description")
            try validateOptionalString(fields["mimeType"], named: "resource_link mimeType")
            try validateOptionalObject(fields["annotations"], named: "resource_link annotations")
            try validateOptionalObject(fields["_meta"], named: "resource_link _meta")
        default:
            throw ProtocolCoreError.invalidInputResponse("tool result content type is unsupported")
        }
    }

    private static func validateContentMetadata(
        _ fields: [String: Value],
        subject: String
    ) throws {
        try validateOptionalObject(fields["annotations"], named: "\(subject) annotations")
        try validateOptionalObject(fields["_meta"], named: "\(subject) _meta")
    }

    private static func validateEmbeddedResource(_ value: Value?) throws {
        guard let value, let fields = value.objectValue,
            fields["uri"]?.stringValue != nil
        else {
            throw ProtocolCoreError.invalidInputResponse(
                "embedded resource requires a resource object with a uri"
            )
        }
        if let mimeType = fields["mimeType"], mimeType.stringValue == nil {
            throw ProtocolCoreError.invalidInputResponse("embedded resource mimeType must be a string")
        }
        if let metadata = fields["_meta"], metadata.objectValue == nil {
            throw ProtocolCoreError.invalidInputResponse("embedded resource _meta must be an object")
        }
        try validateOptionalObject(fields["annotations"], named: "embedded resource annotations")

        let hasText = fields["text"]?.stringValue != nil
        let hasBlob = fields["blob"]?.stringValue != nil
        if fields["text"] != nil, !hasText {
            throw ProtocolCoreError.invalidInputResponse("embedded resource text must be a string")
        }
        if fields["blob"] != nil, !hasBlob {
            throw ProtocolCoreError.invalidInputResponse("embedded resource blob must be a string")
        }
        guard hasText != hasBlob else {
            throw ProtocolCoreError.invalidInputResponse(
                "embedded resource must contain exactly one of text or blob"
            )
        }
    }

    private static func validateOptionalString(_ value: Value?, named name: String) throws {
        guard value == nil || value?.stringValue != nil else {
            throw ProtocolCoreError.invalidInputResponse("\(name) must be a string")
        }
    }

    private static func validateOptionalObject(_ value: Value?, named name: String) throws {
        guard value == nil || value?.objectValue != nil else {
            throw ProtocolCoreError.invalidInputResponse("\(name) must be an object")
        }
    }

    private static func validateRoots(_ fields: [String: Value]) throws {
        guard let roots = fields["roots"]?.arrayValue else {
            throw ProtocolCoreError.invalidInputResponse("roots must be an array")
        }
        try validateOptionalObject(fields["_meta"], named: "roots _meta")
        for root in roots {
            guard case .object(let rootFields) = root,
                rootFields["uri"]?.stringValue != nil
            else {
                throw ProtocolCoreError.invalidInputResponse("each root requires a uri string")
            }
            if let name = rootFields["name"], name.stringValue == nil {
                throw ProtocolCoreError.invalidInputResponse("root name must be a string")
            }
            if let metadata = rootFields["_meta"], metadata.objectValue == nil {
                throw ProtocolCoreError.invalidInputResponse("root _meta must be an object")
            }
        }
    }

    private static func validateElicitation(_ fields: [String: Value]) throws {
        guard let action = fields["action"]?.stringValue,
            action == "accept" || action == "decline" || action == "cancel"
        else {
            throw ProtocolCoreError.invalidInputResponse("action is invalid")
        }
        if let metadata = fields["_meta"], metadata.objectValue == nil {
            throw ProtocolCoreError.invalidInputResponse("elicitation _meta must be an object")
        }
        guard let content = fields["content"] else { return }
        guard action == "accept", case .object(let values) = content else {
            throw ProtocolCoreError.invalidInputResponse("decline and cancel responses must not include content")
        }
        for value in values.values {
            switch value {
            case .string, .int, .bool:
                continue
            case .array(let items) where items.allSatisfy({ $0.stringValue != nil }):
                continue
            default:
                throw ProtocolCoreError.invalidInputResponse(
                    "accepted elicitation content values must be string, integer, boolean, or string array"
                )
            }
        }
    }
}

/// Client responses keyed by the server-assigned input request identifiers.
public typealias InputResponses = [String: InputResponse]
