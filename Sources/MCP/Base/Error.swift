import Foundation

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

/// Information about a required URL elicitation
public struct URLElicitationInfo: Codable, Hashable, Sendable {
    /// Elicitation mode (must be "url")
    public var mode: String
    /// Unique identifier for this elicitation
    public var elicitationId: String
    /// URL for the user to visit
    public var url: String
    /// Message describing the elicitation
    public var message: String

    public init(mode: String = "url", elicitationId: String, url: String, message: String) {
        self.mode = mode
        self.elicitationId = elicitationId
        self.url = url
        self.message = message
    }
}

/// A model context protocol error.
public enum MCPError: Swift.Error, Sendable {
    // Standard JSON-RPC 2.0 errors (-32700 to -32603)
    case parseError(String?)  // -32700
    case invalidRequest(String?)  // -32600
    case methodNotFound(String?)  // -32601
    case invalidParams(String?)  // -32602
    case internalError(String?)  // -32603

    // Server errors (-32000 to -32099)
    case serverError(code: Int, message: String)

    // MCP specific errors
    case urlElicitationRequired(message: String, elicitations: [URLElicitationInfo])  // -32042
    case headerMismatch(String?)  // -32020
    case missingRequiredClientCapability(required: [String: Value])  // -32021
    case unsupportedProtocolVersion(requested: String, supported: [String])  // -32022
    case negotiationFailed(String?)
    case localLimitExceeded(resource: String, limit: Int)

    // Transport specific errors
    case connectionClosed
    case transportError(Swift.Error)

    /// The JSON-RPC 2.0 error code
    public var code: Int {
        switch self {
        case .parseError: return -32700
        case .invalidRequest: return -32600
        case .methodNotFound: return -32601
        case .invalidParams: return -32602
        case .internalError: return -32603
        case .serverError(let code, _): return code
        case .urlElicitationRequired: return -32042
        case .headerMismatch: return -32020
        case .missingRequiredClientCapability: return -32021
        case .unsupportedProtocolVersion: return -32022
        case .negotiationFailed: return -32023
        case .localLimitExceeded: return -32024
        case .connectionClosed: return -32000
        case .transportError: return -32001
        }
    }

    /// Check if an error represents a "resource temporarily unavailable" condition
    public static func isResourceTemporarilyUnavailable(_ error: Swift.Error) -> Bool {
        #if canImport(System)
            if let errno = error as? System.Errno, errno == .resourceTemporarilyUnavailable {
                return true
            }
        #else
            if let errno = error as? SystemPackage.Errno, errno == .resourceTemporarilyUnavailable {
                return true
            }
        #endif
        return false
    }
}

// MARK: LocalizedError

extension MCPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .parseError(let detail):
            return "Parse error: Invalid JSON" + (detail.map { ": \($0)" } ?? "")
        case .invalidRequest(let detail):
            return "Invalid Request" + (detail.map { ": \($0)" } ?? "")
        case .methodNotFound(let detail):
            return "Method not found" + (detail.map { ": \($0)" } ?? "")
        case .invalidParams(let detail):
            return "Invalid params" + (detail.map { ": \($0)" } ?? "")
        case .internalError(let detail):
            return "Internal error" + (detail.map { ": \($0)" } ?? "")
        case .serverError(_, let message):
            return "Server error: \(message)"
        case .urlElicitationRequired(let message, _):
            return "URL elicitation required: \(message)"
        case .headerMismatch(let detail):
            return "Header mismatch" + (detail.map { ": \($0)" } ?? "")
        case .missingRequiredClientCapability(let required):
            return "Missing required client capability: \(required.keys.sorted().joined(separator: ", "))"
        case .unsupportedProtocolVersion(let requested, let supported):
            return "Unsupported protocol version: \(requested) (supported: \(supported.joined(separator: ", ")))"
        case .negotiationFailed(let detail):
            return "Protocol negotiation failed" + (detail.map { ": \($0)" } ?? "")
        case .localLimitExceeded(let resource, let limit):
            return "Local limit exceeded for \(resource): \(limit)"
        case .connectionClosed:
            return "Connection closed"
        case .transportError(let error):
            return "Transport error: \(error.localizedDescription)"
        }
    }

    public var failureReason: String? {
        switch self {
        case .parseError:
            return "The server received invalid JSON that could not be parsed"
        case .invalidRequest:
            return "The JSON sent is not a valid Request object"
        case .methodNotFound:
            return "The method does not exist or is not available"
        case .invalidParams:
            return "Invalid method parameter(s)"
        case .internalError:
            return "Internal JSON-RPC error"
        case .serverError:
            return "Server-defined error occurred"
        case .urlElicitationRequired:
            return "The server requires user authentication or input via external URL"
        case .headerMismatch:
            return "Ensure protocol headers match the corresponding request fields"
        case .missingRequiredClientCapability:
            return "Declare the required client capability before retrying the request"
        case .unsupportedProtocolVersion:
            return "Retry with one of the protocol versions advertised by the server"
        case .negotiationFailed:
            return "Check that both peers advertise a mutually supported protocol version"
        case .localLimitExceeded:
            return "Reduce the request or increase the owning operation's configured bound"
        case .connectionClosed:
            return "The connection to the server was closed"
        case .transportError(let error):
            return (error as? LocalizedError)?.failureReason ?? error.localizedDescription
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .parseError:
            return "Verify that the JSON being sent is valid and well-formed"
        case .invalidRequest:
            return "Ensure the request follows the JSON-RPC 2.0 specification format"
        case .methodNotFound:
            return "Check the method name and ensure it is supported by the server"
        case .invalidParams:
            return "Verify the parameters match the method's expected parameters"
        case .urlElicitationRequired(_, let elicitations):
            if let first = elicitations.first {
                return "Visit \(first.url) to complete the required authentication or input"
            }
            return "Complete the required URL-based elicitation"
        case .headerMismatch, .missingRequiredClientCapability, .unsupportedProtocolVersion,
            .negotiationFailed, .localLimitExceeded:
            return nil
        case .connectionClosed:
            return "Try reconnecting to the server"
        default:
            return nil
        }
    }
}

// MARK: CustomDebugStringConvertible

extension MCPError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .transportError(let error):
            return
                "[\(code)] \(errorDescription ?? "") (Underlying error: \(String(reflecting: error)))"
        default:
            return "[\(code)] \(errorDescription ?? "")"
        }
    }

}

// MARK: Codable

extension MCPError: Codable {
    private enum CodingKeys: String, CodingKey {
        case code, message, data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)

        // Encode additional data if available
        switch self {
        case .parseError(let detail),
            .invalidRequest(let detail),
            .methodNotFound(let detail),
            .invalidParams(let detail),
            .internalError(let detail):
            try container.encode(errorDescription ?? "Unknown error", forKey: .message)
            if let detail = detail {
                try container.encode(["detail": detail], forKey: .data)
            }
        case .serverError(_, _):
            // No additional data for server errors
            try container.encode(errorDescription ?? "Unknown error", forKey: .message)
            break
        case .urlElicitationRequired(let message, let elicitations):
            // Encode the raw message so decode can round-trip without prefix doubling
            try container.encode(message, forKey: .message)
            // Encode elicitations array as structured data
            let elicitationsData = elicitations.map { info -> [String: Value] in
                return [
                    "mode": .string(info.mode),
                    "elicitationId": .string(info.elicitationId),
                    "url": .string(info.url),
                    "message": .string(info.message)
                ]
            }
            try container.encode(
                ["elicitations": Value.array(elicitationsData.map { .object($0) })],
                forKey: .data
            )
        case .headerMismatch(let detail):
            try container.encode(errorDescription ?? "Header mismatch", forKey: .message)
            if let detail {
                try container.encode(["detail": detail], forKey: .data)
            }
        case .missingRequiredClientCapability(let required):
            try container.encode(errorDescription ?? "Missing required client capability", forKey: .message)
            try container.encode(
                ["requiredCapabilities": Value.object(required)],
                forKey: .data
            )
        case .unsupportedProtocolVersion(let requested, let supported):
            try container.encode(errorDescription ?? "Unsupported protocol version", forKey: .message)
            try container.encode(
                Value.object([
                    "requested": .string(requested),
                    "supported": .array(supported.map(Value.string)),
                ]),
                forKey: .data
            )
        case .negotiationFailed(let detail):
            try container.encode(errorDescription ?? "Protocol negotiation failed", forKey: .message)
            if let detail {
                try container.encode(["detail": detail], forKey: .data)
            }
        case .localLimitExceeded(let resource, let limit):
            try container.encode(errorDescription ?? "Local limit exceeded", forKey: .message)
            try container.encode(
                Value.object(["resource": .string(resource), "limit": .int(limit)]),
                forKey: .data
            )
        case .connectionClosed:
            try container.encode(errorDescription ?? "Unknown error", forKey: .message)
        case .transportError(let error):
            try container.encode(errorDescription ?? "Unknown error", forKey: .message)
            try container.encode(
                ["error": error.localizedDescription],
                forKey: .data
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(Int.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        let data = try container.decodeIfPresent([String: Value].self, forKey: .data)

        let invalidStructuredData: (String) -> DecodingError = { detail in
            DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath + [CodingKeys.data],
                debugDescription: detail
            ))
        }

        // Helper to extract detail from data, falling back to message if needed
        let unwrapDetail: (String?) -> String? = { fallback in
            guard let detailValue = data?["detail"] else { return fallback }
            if case .string(let str) = detailValue { return str }
            return fallback
        }

        switch code {
        case -32700:
            self = .parseError(unwrapDetail(message))
        case -32600:
            self = .invalidRequest(unwrapDetail(message))
        case -32601:
            self = .methodNotFound(unwrapDetail(message))
        case -32602:
            self = .invalidParams(unwrapDetail(message))
        case -32603:
            self = .internalError(unwrapDetail(nil))
        case -32042:
            // Extract elicitations array from data
            var elicitations: [URLElicitationInfo] = []
            if case .array(let items) = data?["elicitations"] {
                for item in items {
                    if case .object(let dict) = item,
                       case .string(let mode) = dict["mode"],
                       case .string(let elicitationId) = dict["elicitationId"],
                       case .string(let url) = dict["url"],
                       case .string(let msg) = dict["message"] {
                        elicitations.append(URLElicitationInfo(
                            mode: mode,
                            elicitationId: elicitationId,
                            url: url,
                            message: msg))
                    }
                }
            }
            self = .urlElicitationRequired(message: message, elicitations: elicitations)
        case -32020:
            self = .headerMismatch(unwrapDetail(message))
        case -32021:
            guard let requiredValue = data?["requiredCapabilities"],
                case .object(let required) = requiredValue
            else {
                throw invalidStructuredData(
                    "Missing or invalid requiredCapabilities for error code -32021"
                )
            }
            self = .missingRequiredClientCapability(required: required)
        case -32022:
            guard let requested = data?["requested"]?.stringValue else {
                throw invalidStructuredData(
                    "Missing or invalid requested for error code -32022"
                )
            }
            guard case .array(let values)? = data?["supported"] else {
                throw invalidStructuredData(
                    "Missing or invalid supported for error code -32022"
                )
            }
            var supported: [String] = []
            supported.reserveCapacity(values.count)
            for value in values {
                guard let version = value.stringValue else {
                    throw invalidStructuredData(
                        "supported must contain only strings for error code -32022"
                    )
                }
                supported.append(version)
            }
            self = .unsupportedProtocolVersion(requested: requested, supported: supported)
        case -32023:
            self = .negotiationFailed(unwrapDetail(message))
        case -32024:
            guard let resource = data?["resource"]?.stringValue else {
                throw invalidStructuredData(
                    "Missing or invalid resource for error code -32024"
                )
            }
            guard let limit = data?["limit"]?.intValue else {
                throw invalidStructuredData(
                    "Missing or invalid limit for error code -32024"
                )
            }
            self = .localLimitExceeded(resource: resource, limit: limit)
        case -32000:
            self = .connectionClosed
        case -32001:
            // Extract underlying error string if present
            let underlyingErrorString =
                data?["error"].flatMap { val -> String? in
                    if case .string(let str) = val { return str }
                    return nil
                } ?? message
            self = .transportError(
                NSError(
                    domain: "org.jsonrpc.error",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: underlyingErrorString]
                )
            )
        default:
            self = .serverError(code: code, message: message)
        }
    }
}

// MARK: Equatable

extension MCPError: Equatable {
    public static func == (lhs: MCPError, rhs: MCPError) -> Bool {
        switch (lhs, rhs) {
        case (.parseError(let a), .parseError(let b)): return a == b
        case (.invalidRequest(let a), .invalidRequest(let b)): return a == b
        case (.methodNotFound(let a), .methodNotFound(let b)): return a == b
        case (.invalidParams(let a), .invalidParams(let b)): return a == b
        case (.internalError(let a), .internalError(let b)): return a == b
        case (.serverError(let c1, let m1), .serverError(let c2, let m2)):
            return c1 == c2 && m1 == m2
        case (.urlElicitationRequired(let m1, let e1), .urlElicitationRequired(let m2, let e2)):
            return m1 == m2 && e1 == e2
        case (.headerMismatch(let a), .headerMismatch(let b)):
            return a == b
        case (.missingRequiredClientCapability(let a), .missingRequiredClientCapability(let b)):
            return a == b
        case (
            .unsupportedProtocolVersion(let requestedA, let supportedA),
            .unsupportedProtocolVersion(let requestedB, let supportedB)
        ):
            return requestedA == requestedB && supportedA == supportedB
        case (.negotiationFailed(let a), .negotiationFailed(let b)):
            return a == b
        case (
            .localLimitExceeded(let resourceA, let limitA),
            .localLimitExceeded(let resourceB, let limitB)
        ):
            return resourceA == resourceB && limitA == limitB
        case (.connectionClosed, .connectionClosed): return true
        case (.transportError(let a), .transportError(let b)):
            return a.localizedDescription == b.localizedDescription
        default: return false
        }
    }
}

// MARK: Hashable

extension MCPError: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(code)
        switch self {
        case .parseError(let detail):
            hasher.combine(detail)
        case .invalidRequest(let detail):
            hasher.combine(detail)
        case .methodNotFound(let detail):
            hasher.combine(detail)
        case .invalidParams(let detail):
            hasher.combine(detail)
        case .internalError(let detail):
            hasher.combine(detail)
        case .serverError(_, let message):
            hasher.combine(message)
        case .urlElicitationRequired(let message, let elicitations):
            hasher.combine(message)
            hasher.combine(elicitations)
        case .headerMismatch(let detail):
            hasher.combine(detail)
        case .missingRequiredClientCapability(let required):
            hasher.combine(required)
        case .unsupportedProtocolVersion(let requested, let supported):
            hasher.combine(requested)
            hasher.combine(supported)
        case .negotiationFailed(let detail):
            hasher.combine(detail)
        case .localLimitExceeded(let resource, let limit):
            hasher.combine(resource)
            hasher.combine(limit)
        case .connectionClosed:
            break
        case .transportError(let error):
            hasher.combine(error.localizedDescription)
        }
    }
}
