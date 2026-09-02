import Foundation

/// Typed failures owned by the state-free protocol core.
public enum ProtocolCoreError: Swift.Error, Equatable, Hashable, Sendable {
    case malformedMessage(String)
    case invalidConnectionInfo(String)
    case missingRequestMetadata(String)
    case invalidRequestMetadata(String)
    case missingResultType
    case invalidResultType
    case invalidResultInput
    case invalidCacheHint
    case unsupportedInputMethod(String)
    case invalidInputRequest(String)
    case invalidInputResponse(String)
    case invalidSubscriptionFilter(String)
    case invalidToolSchema(String)
    case invalidHeaderValue(String)
}

extension ProtocolCoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedMessage(let detail): return "Malformed protocol message: \(detail)"
        case .invalidConnectionInfo(let detail): return "Invalid connection info: \(detail)"
        case .missingRequestMetadata(let field): return "Missing request metadata: \(field)"
        case .invalidRequestMetadata(let field): return "Invalid request metadata: \(field)"
        case .missingResultType: return "Modern result is missing resultType"
        case .invalidResultType: return "Invalid resultType"
        case .invalidResultInput: return "Invalid result/input combination"
        case .invalidCacheHint: return "Invalid cache hint"
        case .unsupportedInputMethod(let method): return "Unsupported input method: \(method)"
        case .invalidInputRequest(let detail): return "Invalid input request: \(detail)"
        case .invalidInputResponse(let detail): return "Invalid input response: \(detail)"
        case .invalidSubscriptionFilter(let detail): return "Invalid subscription filter: \(detail)"
        case .invalidToolSchema(let detail): return "Invalid tool schema: \(detail)"
        case .invalidHeaderValue(let detail): return "Invalid header value: \(detail)"
        }
    }
}
