import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if canImport(CryptoKit)
    import CryptoKit
#endif

private func authorizationServersMatch(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.absoluteString == rhs.absoluteString
}

private final class OAuthAuthorizationServerSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var authorizationServer: URL?
    private var resource: URL?

    init() {}

    func update(authorizationServer: URL?, resource: URL?) {
        lock.lock()
        defer { lock.unlock() }
        self.authorizationServer = authorizationServer
        self.resource = resource
    }

    func read() -> (authorizationServer: URL?, resource: URL?) {
        lock.lock()
        defer { lock.unlock() }
        return (authorizationServer, resource)
    }

}

private actor OAuthAuthorizerCore {
    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    struct State: Sendable {
        var authentication: OAuthConfiguration.TokenEndpointAuthentication
        var selectedAuthorizationServer: URL?
        var selectedResource: URL?
        var protectedResourceMetadata: OAuthProtectedResourceMetadata?
        var authorizationServerMetadata: OAuthAuthorizationServerMetadata?
        var cachedProtectedResourceMetadataURL: URL?
        var clientRegistrationAttempted: Bool
        var clientSecretExpiresAt: Date?
    }

    private var state: State
    private let tokenStorage: any TokenStorage
    private let authorizationServerSnapshot: OAuthAuthorizationServerSnapshot
    private var operationInProgress = false
    private var operationWaiters: [OperationWaiter] = []

    init(
        authentication: OAuthConfiguration.TokenEndpointAuthentication,
        tokenStorage: any TokenStorage,
        authorizationServerSnapshot: OAuthAuthorizationServerSnapshot
    ) {
        self.state = State(
            authentication: authentication,
            selectedAuthorizationServer: nil,
            selectedResource: nil,
            protectedResourceMetadata: nil,
            authorizationServerMetadata: nil,
            cachedProtectedResourceMetadataURL: nil,
            clientRegistrationAttempted: false,
            clientSecretExpiresAt: nil
        )
        self.tokenStorage = tokenStorage
        self.authorizationServerSnapshot = authorizationServerSnapshot
    }

    func snapshot() -> State {
        state
    }

    func update<Result>(_ body: (inout State) -> Result) -> Result {
        let result = body(&state)
        clearStoredTokenWithMismatchedContext()
        authorizationServerSnapshot.update(
            authorizationServer: state.selectedAuthorizationServer,
            resource: state.selectedResource
        )
        return result
    }

    func loadToken() -> OAuthAccessToken? {
        guard let token = tokenStorage.load() else { return nil }
        if hasMismatchedBinding(token) {
            tokenStorage.clear()
            return nil
        }
        return token
    }

    func saveToken(_ token: OAuthAccessToken) {
        if hasMismatchedBinding(token) {
            tokenStorage.clear()
            return
        }
        tokenStorage.save(token)
    }

    func clearToken() {
        tokenStorage.clear()
    }

    func beginOperation() async throws {
        try Task.checkCancellation()
        guard operationInProgress else {
            operationInProgress = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                operationWaiters.append(
                    OperationWaiter(id: waiterID, continuation: continuation))
            }
        }, onCancel: {
            Task { await self.cancelOperationWaiter(waiterID) }
        })

        do {
            try Task.checkCancellation()
        } catch {
            endOperation()
            throw error
        }
    }

    func endOperation() {
        if operationWaiters.isEmpty {
            operationInProgress = false
        } else {
            let waiter = operationWaiters.removeFirst()
            waiter.continuation.resume()
        }
    }

    private func cancelOperationWaiter(_ id: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = operationWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func clearStoredTokenWithMismatchedContext() {
        guard let token = tokenStorage.load(), hasMismatchedBinding(token) else { return }
        tokenStorage.clear()
    }

    private func hasMismatchedBinding(_ token: OAuthAccessToken) -> Bool {
        guard let selectedAuthorizationServer = state.selectedAuthorizationServer,
            let selectedResource = state.selectedResource
        else {
            return false
        }
        guard let tokenAuthorizationServer = token.authorizationServer,
            let tokenResource = token.resource
        else {
            return true
        }
        return !authorizationServersMatch(tokenAuthorizationServer, selectedAuthorizationServer)
            || tokenResource.absoluteString != selectedResource.absoluteString
    }

}

// MARK: - HTTPClientAuthorizer Protocol

/// Abstraction used by ``HTTPClientTransport`` to handle OAuth authorization challenges.
///
/// Implement this protocol to provide custom token acquisition strategies,
/// or use the built-in ``OAuthAuthorizer`` for a full OAuth 2.1 implementation.
///
/// ``HTTPClientTransport`` calls these methods automatically when it receives
/// `401 Unauthorized` or `403 Forbidden` responses from the server.
public protocol HTTPClientAuthorizer: AnyObject, Sendable {
    /// The maximum number of authorization retries permitted for a single request.
    ///
    /// ``HTTPClientTransport`` will not call ``handleChallenge(statusCode:headers:endpoint:operationKey:session:)``
    /// more than this many times for a single outgoing request.
    var maxAuthorizationAttempts: Int { get }

    /// The maximum number of scope-upgrade retries permitted for one outgoing request.
    var maxScopeUpgradeAttempts: Int { get }

    /// Validates that the MCP endpoint URL satisfies the security requirements for OAuth.
    ///
    /// Called once before the first request is sent. Throw ``OAuthAuthorizationError/insecureOAuthEndpoint(context:url:)``
    /// if the URL does not meet the requirements (e.g., non-HTTPS non-loopback).
    /// - Parameter endpoint: The MCP endpoint URL to validate.
    func validateEndpointSecurity(for endpoint: URL) throws

    /// Returns the `Authorization` header value to attach to the next request, if a valid token is available.
    ///
    /// - Parameter endpoint: The MCP endpoint being requested.
    /// - Returns: A `"Bearer <token>"` string, or `nil` if no valid token is cached.
    func authorizationHeader(for endpoint: URL) -> String?

    /// Handles an authorization challenge received from the server and attempts to acquire a new token.
    ///
    /// Called by ``HTTPClientTransport`` when a `401` or `403` response is received.
    /// The implementation should attempt to obtain a valid access token and store it
    /// so that a subsequent call to ``authorizationHeader(for:)`` returns the new value.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code (401 or 403).
    ///   - headers: All response headers from the challenge response.
    ///   - endpoint: The MCP endpoint that returned the challenge.
    ///   - operationKey: An optional informational identifier for the MCP operation. Retry
    ///     accounting remains owned by the outgoing HTTP logical request.
    ///   - session: The `URLSession` to use for discovery and token requests.
    /// - Returns: `true` if a new token was acquired and the original request should be retried;
    ///   `false` if the challenge cannot be handled.
    func handleChallenge(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey: String?,
        session: URLSession
    ) async throws -> Bool

    /// Proactively refreshes the access token if it is close to expiry.
    ///
    /// Called by ``HTTPClientTransport`` before sending each request and before opening
    /// an SSE stream, allowing the token to be silently renewed without a 401 round-trip.
    /// Implementations should swallow refresh errors — if refresh fails, the normal
    /// ``handleChallenge(statusCode:headers:endpoint:operationKey:session:)`` path recovers.
    ///
    /// - Parameters:
    ///   - endpoint: The MCP endpoint about to be contacted.
    ///   - session: The `URLSession` to use for token refresh requests.
    func prepareAuthorization(for endpoint: URL, session: URLSession) async throws
}

extension HTTPClientAuthorizer {
    public var maxScopeUpgradeAttempts: Int { maxAuthorizationAttempts }

    public func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {}
}

// MARK: - OAuthAuthorizer

/// Full OAuth 2.1 implementation of ``HTTPClientAuthorizer``.
///
/// `OAuthAuthorizer` orchestrates the complete MCP authorization flow on behalf of an HTTP client:
///
/// 1. **Protected Resource Metadata discovery** (RFC 9728) — fetches
///    `/.well-known/oauth-protected-resource` to locate the authorization server.
/// 2. **Authorization Server Metadata discovery** (RFC 8414 / OIDC Discovery 1.0) — fetches
///    `/.well-known/oauth-authorization-server` or `/.well-known/openid-configuration`.
/// 3. **Dynamic Client Registration** (RFC 7591) — registers the client if no credentials are
///    pre-configured and the AS advertises a registration endpoint.
/// 4. **Token acquisition** — performs the configured grant flow (`authorization_code` with PKCE,
///    or `client_credentials`), binding tokens to the resource indicator (RFC 8707).
/// 5. **Token refresh** — attempts a `refresh_token` grant before a full re-authorization.
/// 6. **Scope step-up** — handles `403 insufficient_scope` challenges by re-requesting with
///    the union of existing and required scopes.
///
/// Pass an instance to `HTTPClientTransport(authorizer:)` to enable automatic authorization:
///
/// ```swift
/// let config = OAuthConfiguration(
///     grantType: .clientCredentials,
///     authentication: .clientSecretBasic(clientID: "my-app", clientSecret: "s3cr3t")
/// )
/// let authorizer = OAuthAuthorizer(configuration: config)
/// let transport = HTTPClientTransport(endpoint: serverURL, authorizer: authorizer)
/// ```
///
/// - Important: This type is `@unchecked Sendable` because its injected protocol
///   implementations are caller-owned. The authorizer's own mutable flow state is
///   serialized by a private actor, and its synchronous issuer view is published through
///   a lock-protected snapshot. Share one authorizer only between concurrent requests in
///   the same configured resource and authorization-server context.
public final class OAuthAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {

    // MARK: - Immutable Configuration and Synchronized State

    private let configuration: OAuthConfiguration
    private let tokenStorage: any TokenStorage
    private let authorizationServerSnapshot: OAuthAuthorizationServerSnapshot
    private let core: OAuthAuthorizerCore

    // MARK: - Composable Dependencies

    private let scopeSelector: any OAuthScopeSelecting
    private let challengeParser: any OAuthWWWAuthenticateParsing
    private let urlValidator: any OAuthURLValidating
    private let discoveryClient: any OAuthDiscoveryFetching
    private let tokenEndpointClient: any OAuthTokenRequesting
    private let clientRegistrar: any OAuthClientRegistering
    private let authCodeFlow: any OAuthAuthorizationCodeFlowing

    /// Creates an `OAuthAuthorizer` with the given configuration and optional injectable dependencies.
    ///
    /// - Parameters:
    ///   - configuration: OAuth 2.1 configuration controlling the grant type, authentication method,
    ///     endpoint discovery overrides, and retry policy.
    ///   - tokenStorage: Stores acquired access tokens. Defaults to ``InMemoryTokenStorage``,
    ///     which loses tokens when the process exits. Supply a Keychain-backed implementation
    ///     to persist tokens across sessions.
    ///   - scopeSelector: Strategy for selecting OAuth scopes from challenge and metadata hints.
    ///     Defaults to ``DefaultOAuthScopeSelector``.
    ///   - challengeParser: Parses `WWW-Authenticate: Bearer` challenge headers.
    ///     Defaults to ``DefaultOAuthWWWAuthenticateParser``.
    ///   - metadataDiscovery: Constructs well-known discovery URLs and validates resource URI matching.
    ///     Defaults to ``DefaultOAuthMetadataDiscovery``.
    public convenience init(
        configuration: OAuthConfiguration,
        tokenStorage: TokenStorage = InMemoryTokenStorage(),
        scopeSelector: any OAuthScopeSelecting = DefaultOAuthScopeSelector(),
        challengeParser: any OAuthWWWAuthenticateParsing = DefaultOAuthWWWAuthenticateParser(),
        metadataDiscovery: any OAuthMetadataDiscovering = DefaultOAuthMetadataDiscovery()
    ) {
        let urlValidator = OAuthURLValidator(
            allowLoopbackHTTPForAuthorizationServer:
                configuration.allowLoopbackHTTPAuthorizationServerEndpoints
        )
        self.init(
            configuration: configuration,
            tokenStorage: tokenStorage,
            scopeSelector: scopeSelector,
            challengeParser: challengeParser,
            urlValidator: urlValidator,
            discoveryClient: OAuthDiscoveryClient(
                metadataDiscovery: metadataDiscovery,
                urlValidator: urlValidator
            ),
            tokenEndpointClient: OAuthTokenEndpointClient(urlValidator: urlValidator),
            clientRegistrar: OAuthClientRegistrar(urlValidator: urlValidator),
            authCodeFlow: OAuthAuthorizationCodeFlow()
        )
    }

    init(
        configuration: OAuthConfiguration,
        tokenStorage: TokenStorage = InMemoryTokenStorage(),
        scopeSelector: any OAuthScopeSelecting = DefaultOAuthScopeSelector(),
        challengeParser: any OAuthWWWAuthenticateParsing = DefaultOAuthWWWAuthenticateParser(),
        urlValidator: any OAuthURLValidating,
        discoveryClient: any OAuthDiscoveryFetching,
        tokenEndpointClient: any OAuthTokenRequesting,
        clientRegistrar: any OAuthClientRegistering,
        authCodeFlow: any OAuthAuthorizationCodeFlowing
    ) {
        self.configuration = configuration
        self.tokenStorage = tokenStorage
        let authorizationServerSnapshot = OAuthAuthorizationServerSnapshot()
        self.authorizationServerSnapshot = authorizationServerSnapshot
        self.core = OAuthAuthorizerCore(
            authentication: configuration.authentication,
            tokenStorage: tokenStorage,
            authorizationServerSnapshot: authorizationServerSnapshot
        )
        self.scopeSelector = scopeSelector
        self.challengeParser = challengeParser
        self.urlValidator = urlValidator
        self.discoveryClient = discoveryClient
        self.tokenEndpointClient = tokenEndpointClient
        self.clientRegistrar = clientRegistrar
        self.authCodeFlow = authCodeFlow
    }

    // MARK: - HTTPClientAuthorizer

    public var maxAuthorizationAttempts: Int {
        configuration.retryPolicy.maxAuthorizationAttempts
    }

    public var maxScopeUpgradeAttempts: Int {
        configuration.retryPolicy.maxScopeUpgradeAttempts
    }

    public func validateEndpointSecurity(for endpoint: URL) throws {
        try urlValidator.validateHTTPSOrLoopback(endpoint, context: "MCP endpoint")
    }

    public func authorizationHeader(for endpoint: URL) -> String? {
        guard let accessToken = tokenStorage.load() else { return nil }
        let context = authorizationServerSnapshot.read()
        guard let tokenAuthorizationServer = accessToken.authorizationServer,
            let selectedAuthorizationServer = context.authorizationServer,
            authorizationServersMatch(tokenAuthorizationServer, selectedAuthorizationServer),
            let tokenResource = accessToken.resource,
            let selectedResource = context.resource,
            tokenResource.absoluteString == selectedResource.absoluteString,
            let endpointResource = try? discoveryClient.metadataDiscovery
                .canonicalResourceURI(from: endpoint),
            discoveryClient.metadataDiscovery.protectedResourceMatches(
                resource: selectedResource,
                endpoint: endpointResource
            )
        else { return nil }
        if accessToken.isExpired() {
            return nil
        }
        return "\(OAuthTokenType.bearer) \(accessToken.value)"
    }

    public func handleChallenge(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey _: String? = nil,
        session: URLSession
    ) async throws -> Bool {
        try validateEndpointSecurity(for: endpoint)

        try await core.beginOperation()
        do {
            try Task.checkCancellation()
            let handled = try await handleChallengeSerially(
                statusCode: statusCode,
                headers: headers,
                endpoint: endpoint,
                session: session
            )
            await core.endOperation()
            return handled
        } catch {
            await core.endOperation()
            throw error
        }
    }

    private func handleChallengeSerially(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        session: URLSession
    ) async throws -> Bool {
        let challenge = challengeParser.parseBearer(from: headers)

        switch statusCode {
        case 401:
            var refreshedMetadata: OAuthProtectedResourceMetadata?
            if let refreshToken = await core.loadToken()?.refreshToken {
                await core.clearToken()
                let metadata = try await discoverProtectedResourceMetadata(
                    endpoint: endpoint,
                    challenge: challenge,
                    forceRefresh: true,
                    session: session
                )
                refreshedMetadata = metadata
                let asMetadata = try await resolveAuthorizationServerMetadata(
                    metadata: metadata,
                    session: session
                )
                let resource = try await canonicalResource(for: endpoint)
                let requestedScopes = scopeSelector.selectScopes(
                    challengeScope: challenge?.scope,
                    scopesSupported: metadata.scopesSupported
                )
                if try await refreshAccessToken(
                    refreshToken: refreshToken,
                    resource: resource,
                    requestedScopes: requestedScopes,
                    asMetadata: asMetadata,
                    session: session
                ) {
                    return true
                }
            } else {
                await core.clearToken()
            }

            let metadata: OAuthProtectedResourceMetadata
            if let refreshedMetadata {
                metadata = refreshedMetadata
            } else {
                metadata = try await discoverProtectedResourceMetadata(
                    endpoint: endpoint,
                    challenge: challenge,
                    forceRefresh: true,
                    session: session
                )
            }
            let requestedScopes = scopeSelector.selectScopes(
                challengeScope: challenge?.scope,
                scopesSupported: metadata.scopesSupported
            )

            let providerContext = try await makeAccessTokenProviderContext(
                statusCode: statusCode,
                endpoint: endpoint,
                challenge: challenge,
                metadata: metadata,
                requestedScopes: requestedScopes,
                session: session
            )
            if let externalToken = try await fetchAccessTokenFromProvider(
                context: providerContext,
                session: session
            ) {
                await storeExternalAccessToken(
                    externalToken,
                    requestedScopes: providerContext.requestedScopes,
                    authorizationServer: providerContext.authorizationServer,
                    resource: providerContext.resource
                )
                return true
            }

            try await acquireToken(
                endpoint: endpoint,
                metadata: metadata,
                requestedScopes: requestedScopes,
                session: session
            )
            return true

        case 403:
            guard challenge?.error?.lowercased() == "insufficient_scope" else { return false }

            let metadata = try await discoverProtectedResourceMetadata(
                endpoint: endpoint,
                challenge: challenge,
                session: session
            )
            let requiredScopes =
                scopeSelector.selectScopes(
                    challengeScope: challenge?.scope,
                    scopesSupported: metadata.scopesSupported
                ) ?? []

            let existingScopes = await core.loadToken()?.scopes ?? []
            let upgradedScopes = existingScopes.union(requiredScopes)
            let providerRequestedScopes = upgradedScopes.isEmpty ? nil : upgradedScopes
            let providerContext = try await makeAccessTokenProviderContext(
                statusCode: statusCode,
                endpoint: endpoint,
                challenge: challenge,
                metadata: metadata,
                requestedScopes: providerRequestedScopes,
                session: session
            )
            if let externalToken = try await fetchAccessTokenFromProvider(
                context: providerContext,
                session: session
            ) {
                await storeExternalAccessToken(
                    externalToken,
                    requestedScopes: providerContext.requestedScopes,
                    authorizationServer: providerContext.authorizationServer,
                    resource: providerContext.resource
                )
                return true
            }

            try await acquireToken(
                endpoint: endpoint,
                metadata: metadata,
                requestedScopes: upgradedScopes,
                session: session
            )
            return true

        default:
            return false
        }
    }

    public func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {
        try await core.beginOperation()
        do {
            try Task.checkCancellation()
            try await prepareAuthorizationSerially(for: endpoint, session: session)
            await core.endOperation()
        } catch {
            await core.endOperation()
            throw error
        }
    }

    private func prepareAuthorizationSerially(for endpoint: URL, session: URLSession) async throws {
        guard let storedToken = await core.loadToken() else { return }
        guard storedToken.authorizationServer != nil, storedToken.resource != nil else {
            await core.clearToken()
            return
        }

        let currentState = await core.snapshot()
        if currentState.selectedAuthorizationServer == nil || currentState.selectedResource == nil {
            let metadata = try await discoverProtectedResourceMetadata(
                endpoint: endpoint,
                challenge: nil,
                session: session
            )
            _ = try await resolveAuthorizationServerMetadata(metadata: metadata, session: session)
            _ = try await canonicalResource(for: endpoint)
        }

        guard let token = await core.loadToken() else { return }
        guard configuration.proactiveRefreshWindowSeconds > 0 else { return }
        guard token.isExpired(skewSeconds: configuration.proactiveRefreshWindowSeconds) else {
            return
        }
        guard let refreshToken = token.refreshToken else { return }
        guard let asMeta = await core.snapshot().authorizationServerMetadata,
            asMeta.tokenEndpoint != nil
        else { return }

        let resource: URL
        do {
            resource = try await canonicalResource(for: endpoint)
        } catch {
            return
        }

        let requestedScopes = token.scopes.isEmpty ? nil : token.scopes
        do {
            _ = try await refreshAccessToken(
                refreshToken: refreshToken,
                resource: resource,
                requestedScopes: requestedScopes,
                asMetadata: asMeta,
                session: session
            )
        } catch {
            // Proactive refresh is best effort; the challenge path remains authoritative.
        }
    }

    // MARK: - Discovery

    private func discoverProtectedResourceMetadata(
        endpoint: URL,
        challenge: OAuthBearerChallenge?,
        forceRefresh: Bool = false,
        session: URLSession
    ) async throws -> OAuthProtectedResourceMetadata {
        let currentState = await core.snapshot()
        if !forceRefresh,
            let protectedResourceMetadata = currentState.protectedResourceMetadata
        {
            let incomingURL = challenge?.resourceMetadataURL
            if incomingURL == nil || incomingURL == currentState.cachedProtectedResourceMetadataURL {
                return protectedResourceMetadata
            }
        }

        var candidates: [URL] = []

        if let challengeURL = challenge?.resourceMetadataURL {
            try urlValidator.validateHTTPSOrLoopback(
                challengeURL, context: "Protected resource metadata URL")
            if let host = URLComponents(url: challengeURL, resolvingAgainstBaseURL: false)?.host?
                .lowercased(), urlValidator.isPrivateIPHost(host)
            {
                throw OAuthAuthorizationError.privateIPAddressBlocked(
                    context: "Protected resource metadata URL",
                    url: challengeURL.absoluteString
                )
            }
            candidates.append(challengeURL)
        }
        if let configuredURL = configuration.endpointOverrides.protectedResourceMetadataURL,
            !candidates.contains(configuredURL)
        {
            try urlValidator.validateHTTPSOrLoopback(
                configuredURL,
                context: "Configured protected resource metadata URL"
            )
            candidates.append(configuredURL)
        }

        for fallback in discoveryClient.metadataDiscovery.protectedResourceMetadataURLs(
            for: endpoint)
        where !candidates.contains(fallback) {
            candidates.append(fallback)
        }

        let fallbackIssuer = try? discoveryClient.metadataDiscovery
            .authorizationServerFallbackIssuer(from: endpoint)
        let metadata = try await discoveryClient.fetchProtectedResourceMetadata(
            candidates: candidates, fallbackIssuer: fallbackIssuer, session: session)
        try validateProtectedResource(metadata: metadata, endpoint: endpoint)

        let authorizationServersChanged =
            currentState.protectedResourceMetadata?.authorizationServers
            != metadata.authorizationServers
        await core.update { state in
            if authorizationServersChanged {
                state.authorizationServerMetadata = nil
                state.selectedAuthorizationServer = nil
                state.selectedResource = nil
                state.authentication = configuration.authentication
                state.clientRegistrationAttempted = false
                state.clientSecretExpiresAt = nil
            }
            state.protectedResourceMetadata = metadata
            state.cachedProtectedResourceMetadataURL = candidates.first
        }
        return metadata
    }

    private func validateProtectedResource(
        metadata: OAuthProtectedResourceMetadata, endpoint: URL
    ) throws {
        guard let resource = metadata.resource?.trimmingCharacters(in: .whitespacesAndNewlines),
            !resource.isEmpty
        else {
            return
        }

        guard let resourceURL = URL(string: resource) else {
            throw OAuthAuthorizationError.invalidResourceURI(
                "Protected resource metadata contains an invalid resource URI: \(resource)"
            )
        }

        let expected = try discoveryClient.metadataDiscovery.canonicalResourceURI(from: endpoint)
        let actual = try discoveryClient.metadataDiscovery.canonicalResourceURI(from: resourceURL)
        guard discoveryClient.metadataDiscovery.protectedResourceMatches(
            resource: actual, endpoint: expected)
        else {
            throw OAuthAuthorizationError.protectedResourceMismatch(
                expected: expected.absoluteString,
                actual: actual.absoluteString
            )
        }
    }

    private func resolveAuthorizationServerMetadata(
        metadata: OAuthProtectedResourceMetadata,
        session: URLSession
    ) async throws -> OAuthAuthorizationServerMetadata {
        let currentState = await core.snapshot()
        if let cached = currentState.authorizationServerMetadata {
            return cached
        }

        let candidates: [URL]
        if let override = configuration.endpointOverrides.authorizationServerURL {
            try urlValidator.validateAuthorizationServer(
                override, context: "Authorization server issuer")
            candidates = [override]
        } else if let selected = currentState.selectedAuthorizationServer {
            candidates = [selected]
        } else {
            guard !metadata.authorizationServers.isEmpty else {
                throw OAuthAuthorizationError.missingAuthorizationServer
            }
            candidates = metadata.authorizationServers
        }

        let (server, asMetadata) = try await discoveryClient.fetchAuthorizationServerMetadata(
            candidates: candidates, session: session)
        await core.update { state in
            state.selectedAuthorizationServer = server
            state.authorizationServerMetadata = asMetadata
        }
        return asMetadata
    }

    // MARK: - Token Acquisition

    private func acquireToken(
        endpoint: URL,
        metadata: OAuthProtectedResourceMetadata,
        requestedScopes: Set<String>?,
        session: URLSession
    ) async throws {
        let asMetadata = try await resolveAuthorizationServerMetadata(
            metadata: metadata, session: session)
        try await maybeRegisterClient(asMetadata: asMetadata, session: session)
        let resource = try await canonicalResource(for: endpoint)
        let authorizationScopes = scopesForAuthorizationCode(
            requestedScopes: requestedScopes,
            asMetadata: asMetadata
        )

        switch configuration.grantType {
        case .clientCredentials:
            try await acquireTokenViaClientCredentials(
                resource: resource,
                requestedScopes: requestedScopes,
                asMetadata: asMetadata,
                session: session
            )
        case .authorizationCode:
            try await acquireTokenViaAuthorizationCode(
                resource: resource,
                requestedScopes: authorizationScopes,
                asMetadata: asMetadata,
                session: session
            )
        }
    }

    private func scopesForAuthorizationCode(
        requestedScopes: Set<String>?,
        asMetadata: OAuthAuthorizationServerMetadata
    ) -> Set<String>? {
        guard configuration.grantType == .authorizationCode,
            asMetadata.scopesSupported?.contains("offline_access") == true
        else {
            return requestedScopes
        }
        var scopes = requestedScopes ?? []
        scopes.insert("offline_access")
        return scopes
    }

    private func acquireTokenViaClientCredentials(
        resource: URL,
        requestedScopes: Set<String>?,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws {
        let tokenEndpoint = try resolveTokenEndpoint(asMetadata: asMetadata)
        var bodyParameters: [String: String] = configuration.additionalTokenRequestParameters
        bodyParameters[OAuthParameterName.grantType] = OAuthGrantTypeValue.clientCredentials
        bodyParameters[OAuthParameterName.resource] = resource.absoluteString
        if let scope = requestedScopes.flatMap(scopeSelector.serialize) {
            bodyParameters[OAuthParameterName.scope] = scope
        }
        let decoded = try await tokenEndpointClient.request(
            parameters: &bodyParameters,
            endpoint: tokenEndpoint,
            authentication: await core.snapshot().authentication,
            session: session
        )
        await storeTokenResponse(
            decoded,
            requestedScopes: requestedScopes,
            resource: resource
        )
    }

    private func acquireTokenViaAuthorizationCode(
        resource: URL,
        requestedScopes: Set<String>?,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws {
        guard let authorizationEndpoint = asMetadata.authorizationEndpoint else {
            throw OAuthAuthorizationError.tokenEndpointMissing
        }
        try urlValidator.validateAuthorizationServer(
            authorizationEndpoint, context: "Authorization endpoint")
        if let host = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)?
            .host?.lowercased(), urlValidator.isPrivateIPHost(host)
        {
            throw OAuthAuthorizationError.privateIPAddressBlocked(
                context: "Authorization endpoint",
                url: authorizationEndpoint.absoluteString
            )
        }
        try urlValidator.validateRedirectURI(configuration.authorizationRedirectURI)
        try PKCE.checkSupport(in: asMetadata)

        let verifier = PKCE.makeVerifier()
        let challenge = try PKCE.makeChallenge(from: verifier)
        let state = UUID().uuidString
        let currentState = await core.snapshot()
        let authentication = currentState.authentication

        let authorizationURL = try authCodeFlow.buildURL(
            authorizationEndpoint: authorizationEndpoint,
            resource: resource,
            redirectURI: configuration.authorizationRedirectURI,
            clientID: authentication.clientID,
            codeChallenge: challenge,
            scopes: requestedScopes,
            state: state,
            scopeSerializer: scopeSelector
        )

        let authorizationCode = try await authCodeFlow.perform(
            authorizationURL: authorizationURL,
            redirectURI: configuration.authorizationRedirectURI,
            state: state,
            expectedIssuer: currentState.selectedAuthorizationServer?.absoluteString,
            authorizationResponseIssParameterSupported:
                asMetadata.authorizationResponseIssParameterSupported,
            delegate: configuration.authorizationDelegate,
            session: session
        )

        let tokenEndpoint = try resolveTokenEndpoint(asMetadata: asMetadata)
        var bodyParameters: [String: String] = configuration.additionalTokenRequestParameters
        bodyParameters[OAuthParameterName.grantType] = OAuthGrantTypeValue.authorizationCode
        bodyParameters[OAuthParameterName.code] = authorizationCode
        bodyParameters[OAuthParameterName.codeVerifier] = verifier
        bodyParameters[OAuthParameterName.redirectURI] =
            configuration.authorizationRedirectURI.absoluteString
        bodyParameters[OAuthParameterName.resource] = resource.absoluteString
        if let scope = requestedScopes.flatMap(scopeSelector.serialize) {
            bodyParameters[OAuthParameterName.scope] = scope
        }

        let decoded = try await tokenEndpointClient.request(
            parameters: &bodyParameters,
            endpoint: tokenEndpoint,
            authentication: await core.snapshot().authentication,
            session: session
        )
        await storeTokenResponse(
            decoded,
            requestedScopes: requestedScopes,
            resource: resource
        )
    }

    // MARK: - Token Refresh

    private func refreshAccessToken(
        refreshToken: String,
        resource: URL,
        requestedScopes: Set<String>?,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws -> Bool {
        let tokenEndpoint: URL
        do {
            tokenEndpoint = try resolveTokenEndpoint(asMetadata: asMetadata)
        } catch {
            return false
        }

        var bodyParameters: [String: String] = configuration.additionalTokenRequestParameters
        bodyParameters[OAuthParameterName.grantType] = OAuthGrantTypeValue.refreshToken
        bodyParameters[OAuthParameterName.refreshToken] = refreshToken
        bodyParameters[OAuthParameterName.resource] = resource.absoluteString
        if let scope = requestedScopes.flatMap(scopeSelector.serialize) {
            bodyParameters[OAuthParameterName.scope] = scope
        }

        do {
            let decoded = try await tokenEndpointClient.request(
                parameters: &bodyParameters,
                endpoint: tokenEndpoint,
                authentication: await core.snapshot().authentication,
                session: session
            )
            await storeTokenResponse(
                decoded,
                requestedScopes: requestedScopes,
                resource: resource
            )
            return true
        } catch let error as OAuthAuthorizationError {
            if case .tokenRequestFailed(let statusCode, _) = error,
                (400..<500).contains(statusCode)
            {
                return false
            }
            throw error
        }
    }

    // MARK: - Client Registration

    private func maybeRegisterClient(
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws {
        let initialState = await core.snapshot()
        if let expiry = initialState.clientSecretExpiresAt, Date() >= expiry {
            await core.update { state in
                state.clientSecretExpiresAt = nil
                state.clientRegistrationAttempted = false
                state.authentication = .none(clientID: state.authentication.clientID)
            }
        }

        let currentState = await core.snapshot()
        guard !currentState.clientRegistrationAttempted else { return }
        guard case .none = currentState.authentication else { return }

        await core.update { state in
            state.clientRegistrationAttempted = true
        }

        var registrationConfiguration = configuration
        registrationConfiguration.authentication = currentState.authentication

        if let (registration, updatedAuth) = try await clientRegistrar.register(
            configuration: registrationConfiguration,
            asMetadata: asMetadata,
            session: session
        ) {
            await core.update { state in
                state.authentication = updatedAuth
                if let expiresAt = registration.clientSecretExpiresAt, expiresAt > 0 {
                    state.clientSecretExpiresAt = Date(timeIntervalSince1970: Double(expiresAt))
                }
            }
        }
    }

    // MARK: - State Helpers

    private func storeTokenResponse(
        _ decoded: OAuthTokenResponse,
        requestedScopes: Set<String>?,
        resource: URL
    ) async {
        let scopeSet: Set<String>
        if let scope = decoded.scope {
            scopeSet = scopeSelector.parseScopeString(scope)
        } else {
            scopeSet = requestedScopes ?? []
        }
        let expiresAt = decoded.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        let state = await core.snapshot()
        await core.saveToken(OAuthAccessToken(
            value: decoded.accessToken,
            tokenType: OAuthTokenType.bearer,
            expiresAt: expiresAt,
            scopes: scopeSet,
            resource: resource,
            authorizationServer: state.selectedAuthorizationServer,
            refreshToken: decoded.refreshToken,
            clientID: nonEmptyClientID(authentication: state.authentication)
        ))
    }

    /// Returns the configured `client_id` or `nil` if the authorizer has not yet been assigned one.
    private func nonEmptyClientID(
        authentication: OAuthConfiguration.TokenEndpointAuthentication
    ) -> String? {
        let id = authentication.clientID
        return id.isEmpty ? nil : id
    }

    private func resolveTokenEndpoint(
        asMetadata: OAuthAuthorizationServerMetadata
    ) throws -> URL {
        if let configuredEndpoint = configuration.endpointOverrides.tokenEndpoint {
            try urlValidator.validateAuthorizationServer(
                configuredEndpoint, context: "Configured token endpoint")
            return configuredEndpoint
        }

        guard let tokenEndpoint = asMetadata.tokenEndpoint else {
            throw OAuthAuthorizationError.tokenEndpointMissing
        }
        try urlValidator.validateAuthorizationServer(tokenEndpoint, context: "Token endpoint")
        if let host = URLComponents(url: tokenEndpoint, resolvingAgainstBaseURL: false)?.host?
            .lowercased(), urlValidator.isPrivateIPHost(host)
        {
            throw OAuthAuthorizationError.privateIPAddressBlocked(
                context: "Token endpoint",
                url: tokenEndpoint.absoluteString
            )
        }
        return tokenEndpoint
    }

    private func canonicalResource(for endpoint: URL) async throws -> URL {
        let endpointCanonical = try discoveryClient.metadataDiscovery.canonicalResourceURI(
            from: endpoint)

        let resource: URL
        if let configuredResource = configuration.endpointOverrides.resource {
            let configuredCanonical = try discoveryClient.metadataDiscovery.canonicalResourceURI(
                from: configuredResource)
            guard discoveryClient.metadataDiscovery.protectedResourceMatches(
                resource: configuredCanonical, endpoint: endpointCanonical)
            else {
                throw OAuthAuthorizationError.protectedResourceMismatch(
                    expected: endpointCanonical.absoluteString,
                    actual: configuredCanonical.absoluteString
                )
            }
            resource = configuredCanonical
        } else if let prmResourceString = (await core.snapshot().protectedResourceMetadata)?.resource,
            let prmResourceURL = URL(string: prmResourceString)
        {
            let prmCanonical = try discoveryClient.metadataDiscovery.canonicalResourceURI(
                from: prmResourceURL)
            guard discoveryClient.metadataDiscovery.protectedResourceMatches(
                resource: prmCanonical, endpoint: endpointCanonical)
            else {
                throw OAuthAuthorizationError.protectedResourceMismatch(
                    expected: endpointCanonical.absoluteString,
                    actual: prmCanonical.absoluteString
                )
            }
            resource = prmCanonical
        } else {
            resource = endpointCanonical
        }

        await core.update { state in
            state.selectedResource = resource
        }
        return resource
    }

    // MARK: - External Token Provider

    private func fetchAccessTokenFromProvider(
        context: OAuthConfiguration.AccessTokenProviderContext,
        session: URLSession
    ) async throws -> String? {
        guard let provider = configuration.accessTokenProvider else { return nil }
        guard let token = try await provider(context, session), !token.isEmpty else { return nil }
        return token
    }

    private func storeExternalAccessToken(
        _ token: String,
        requestedScopes: Set<String>?,
        authorizationServer: URL?,
        resource: URL
    ) async {
        let authentication = await core.snapshot().authentication
        await core.saveToken(OAuthAccessToken(
            value: token,
            tokenType: OAuthTokenType.bearer,
            expiresAt: nil,
            scopes: requestedScopes ?? [],
            resource: resource,
            authorizationServer: authorizationServer,
            refreshToken: nil,
            clientID: nonEmptyClientID(authentication: authentication)
        ))
    }

    private func makeAccessTokenProviderContext(
        statusCode: Int,
        endpoint: URL,
        challenge: OAuthBearerChallenge?,
        metadata: OAuthProtectedResourceMetadata,
        requestedScopes: Set<String>?,
        session: URLSession
    ) async throws -> OAuthConfiguration.AccessTokenProviderContext {
        let asMetadata = try await resolveAuthorizationServerMetadata(
            metadata: metadata, session: session)
        let resource = try await canonicalResource(for: endpoint)
        let currentState = await core.snapshot()
        let authorizationServer = configuration.endpointOverrides.authorizationServerURL
            ?? currentState.selectedAuthorizationServer
            ?? metadata.authorizationServers.first
        let tokenEndpoint = configuration.endpointOverrides.tokenEndpoint ?? asMetadata.tokenEndpoint

        return OAuthConfiguration.AccessTokenProviderContext(
            statusCode: statusCode,
            endpoint: endpoint,
            resource: resource,
            authorizationServer: authorizationServer,
            authorizationEndpoint: asMetadata.authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            registrationEndpoint: asMetadata.registrationEndpoint,
            challengedScope: challenge?.scope,
            scopesSupported: metadata.scopesSupported,
            requestedScopes: requestedScopes
        )
    }

}
