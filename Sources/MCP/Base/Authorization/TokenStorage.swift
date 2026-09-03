import Foundation

// MARK: - Token Storage Protocol

/// Abstraction for persisting OAuth access tokens.
///
/// Implement this protocol to provide custom token storage (e.g., Keychain-backed).
/// The default ``InMemoryTokenStorage`` stores tokens in memory only.
/// Implementations must serialize their own state because `TokenStorage` is `Sendable`.
public protocol TokenStorage: AnyObject, Sendable {
    func save(_ token: OAuthAccessToken)
    func load() -> OAuthAccessToken?
    func clear()
}

// MARK: - In-Memory Implementation

/// Default ``TokenStorage`` that stores the access token in memory only.
///
/// The token is lost when the process exits. For persistent storage
/// (e.g., system Keychain), implement ``TokenStorage`` directly.
public final class InMemoryTokenStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var token: OAuthAccessToken?

    public init() {}

    public func save(_ token: OAuthAccessToken) {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
    }

    public func load() -> OAuthAccessToken? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        token = nil
    }
}
