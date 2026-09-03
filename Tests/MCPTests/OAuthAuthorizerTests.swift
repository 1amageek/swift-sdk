@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Mock Implementations

final class MockURLValidator: OAuthURLValidating, @unchecked Sendable {
    var validateHTTPSOrLoopbackCallCount = 0
    var validateAuthorizationServerCallCount = 0
    var validateRedirectURICallCount = 0
    var shouldThrow: Error?

    func validateHTTPSOrLoopback(_ url: URL, context: String) throws {
        validateHTTPSOrLoopbackCallCount += 1
        if let error = shouldThrow { throw error }
    }

    func validateAuthorizationServer(_ url: URL, context: String) throws {
        validateAuthorizationServerCallCount += 1
        if let error = shouldThrow { throw error }
    }

    func validateRedirectURI(_ url: URL) throws {
        validateRedirectURICallCount += 1
        if let error = shouldThrow { throw error }
    }

    func isPrivateIPHost(_ host: String) -> Bool { false }
}

final class MockDiscoveryClient: OAuthDiscoveryFetching, @unchecked Sendable {
    var fetchProtectedResourceMetadataCallCount = 0
    var fetchAuthorizationServerMetadataCallCount = 0
    let metadataDiscovery: any OAuthMetadataDiscovering = DefaultOAuthMetadataDiscovery()

    var protectedResourceMetadataResult: OAuthProtectedResourceMetadata
    var protectedResourceMetadataResults: [OAuthProtectedResourceMetadata] = []
    var authorizationServerMetadataResult: (server: URL, metadata: OAuthAuthorizationServerMetadata)
    var authorizationServerMetadataByIssuer: [URL: OAuthAuthorizationServerMetadata] = [:]

    init(
        authorizationServer: URL = URL(string: "https://auth.example.com")!,
        tokenEndpoint: URL = URL(string: "https://auth.example.com/token")!
    ) {
        self.protectedResourceMetadataResult = OAuthProtectedResourceMetadata(
            resource: nil,
            authorizationServers: [authorizationServer],
            scopesSupported: nil
        )
        self.authorizationServerMetadataResult = (
            server: authorizationServer,
            metadata: OAuthAuthorizationServerMetadata(
                issuer: authorizationServer,
                authorizationEndpoint: URL(string: "https://auth.example.com/authorize"),
                tokenEndpoint: tokenEndpoint,
                registrationEndpoint: nil,
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil
            )
        )
    }

    func fetchProtectedResourceMetadata(candidates: [URL], fallbackIssuer: URL?, session: URLSession) async throws -> OAuthProtectedResourceMetadata {
        fetchProtectedResourceMetadataCallCount += 1
        if !protectedResourceMetadataResults.isEmpty {
            let index = min(
                fetchProtectedResourceMetadataCallCount - 1,
                protectedResourceMetadataResults.count - 1
            )
            return protectedResourceMetadataResults[index]
        }
        return protectedResourceMetadataResult
    }

    func fetchAuthorizationServerMetadata(candidates: [URL], session: URLSession) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata) {
        fetchAuthorizationServerMetadataCallCount += 1
        if let issuer = candidates.first,
            let metadata = authorizationServerMetadataByIssuer[issuer]
        {
            return (issuer, metadata)
        }
        return authorizationServerMetadataResult
    }
}

final class MockTokenClient: OAuthTokenRequesting, @unchecked Sendable {
    var requestCallCount = 0
    var capturedParameters: [String: String]?
    var tokenResponse = OAuthTokenResponse(
        accessToken: "mock-access-token",
        tokenType: "Bearer",
        expiresIn: 3600,
        scope: nil,
        refreshToken: nil
    )

    func request(
        parameters: inout [String: String],
        endpoint: URL,
        authentication: OAuthConfiguration.TokenEndpointAuthentication,
        session: URLSession
    ) async throws -> OAuthTokenResponse {
        requestCallCount += 1
        capturedParameters = parameters
        return tokenResponse
    }
}

final class MockClientRegistrar: OAuthClientRegistering, @unchecked Sendable {
    var registerCallCount = 0
    var registrationResult: (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )?
    var registrationResults: [(
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )] = []

    func register(
        configuration: OAuthConfiguration,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws -> (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )? {
        registerCallCount += 1
        if !registrationResults.isEmpty {
            let index = min(registerCallCount - 1, registrationResults.count - 1)
            return registrationResults[index]
        }
        return registrationResult
    }
}

final class MockAuthCodeFlow: OAuthAuthorizationCodeFlowing, @unchecked Sendable {
    var buildURLCallCount = 0
    var performCallCount = 0
    var authorizationCode = "mock-auth-code"
    var capturedScopes: Set<String>?

    func buildURL(
        authorizationEndpoint: URL,
        resource: URL,
        redirectURI: URL,
        clientID: String,
        codeChallenge: String,
        scopes: Set<String>?,
        state: String,
        scopeSerializer: any OAuthScopeSelecting
    ) throws -> URL {
        buildURLCallCount += 1
        capturedScopes = scopes
        return URL(string: "https://auth.example.com/authorize?code=stub")!
    }

    func perform(
        authorizationURL: URL,
        redirectURI: URL,
        state: String,
        expectedIssuer: String?,
        authorizationResponseIssParameterSupported: Bool?,
        delegate: (any OAuthAuthorizationDelegate)?,
        session: URLSession
    ) async throws -> String {
        performCallCount += 1
        return authorizationCode
    }
}

private actor RegistrationGate {
    private var callCount = 0
    private var released = false
    private var firstEntryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        callCount += 1
        if callCount == 1 {
            firstEntryWaiter?.resume()
            firstEntryWaiter = nil
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitForFirstEntry() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstEntryWaiter = continuation
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func count() -> Int {
        callCount
    }
}

private final class BlockingRegistrar: OAuthClientRegistering, @unchecked Sendable {
    let gate: RegistrationGate
    let result: (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )

    init(gate: RegistrationGate) {
        self.gate = gate
        result = (
            response: OAuthClientRegistrationResponse(
                clientID: "registered-client",
                clientSecret: "registered-secret",
                tokenEndpointAuthMethod: nil,
                clientSecretExpiresAt: nil
            ),
            updatedAuthentication: .clientSecretBasic(
                clientID: "registered-client", clientSecret: "registered-secret")
        )
    }

    func register(
        configuration: OAuthConfiguration,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws -> (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )? {
        await gate.enter()
        return result
    }
}

private actor AuthenticationCapture {
    private var values: [OAuthConfiguration.TokenEndpointAuthentication] = []

    func append(_ value: OAuthConfiguration.TokenEndpointAuthentication) {
        values.append(value)
    }

    func allValues() -> [OAuthConfiguration.TokenEndpointAuthentication] {
        values
    }
}

private final class CapturingTokenClient: OAuthTokenRequesting, @unchecked Sendable {
    let capture: AuthenticationCapture

    init(capture: AuthenticationCapture) {
        self.capture = capture
    }

    func request(
        parameters: inout [String: String],
        endpoint: URL,
        authentication: OAuthConfiguration.TokenEndpointAuthentication,
        session: URLSession
    ) async throws -> OAuthTokenResponse {
        await capture.append(authentication)
        return OAuthTokenResponse(
            accessToken: "concurrent-access-token",
            tokenType: "Bearer",
            expiresIn: 3600,
            scope: nil,
            refreshToken: nil
        )
    }
}

private actor RefreshSequence {
    private var requestCount = 0
    private var activeRequests = 0
    private var maximumActiveRequests = 0
    private var secondRequestEntered: CheckedContinuation<Void, Never>?
    private var secondRequestRelease: CheckedContinuation<Void, Never>?

    func nextResponse() async -> OAuthTokenResponse {
        requestCount += 1
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        let currentRequest = requestCount

        if currentRequest == 2 {
            secondRequestEntered?.resume()
            secondRequestEntered = nil
            await withCheckedContinuation { continuation in
                secondRequestRelease = continuation
            }
        }

        activeRequests -= 1
        switch currentRequest {
        case 1:
            return OAuthTokenResponse(
                accessToken: "initial-token", tokenType: "Bearer", expiresIn: 1,
                scope: nil, refreshToken: "initial-refresh-token")
        case 2:
            return OAuthTokenResponse(
                accessToken: "proactive-token", tokenType: "Bearer", expiresIn: 1,
                scope: nil, refreshToken: "proactive-refresh-token")
        default:
            return OAuthTokenResponse(
                accessToken: "challenge-token", tokenType: "Bearer", expiresIn: 3600,
                scope: nil, refreshToken: "challenge-refresh-token")
        }
    }

    func waitForSecondRequest() async {
        guard requestCount < 2 else { return }
        await withCheckedContinuation { continuation in
            secondRequestEntered = continuation
        }
    }

    func releaseSecondRequest() {
        secondRequestRelease?.resume()
        secondRequestRelease = nil
    }

    func metrics() -> (requestCount: Int, maximumActiveRequests: Int) {
        (requestCount, maximumActiveRequests)
    }
}

private final class SequencedRefreshTokenClient: OAuthTokenRequesting, @unchecked Sendable {
    let sequence: RefreshSequence

    init(sequence: RefreshSequence) {
        self.sequence = sequence
    }

    func request(
        parameters: inout [String: String],
        endpoint: URL,
        authentication: OAuthConfiguration.TokenEndpointAuthentication,
        session: URLSession
    ) async throws -> OAuthTokenResponse {
        await sequence.nextResponse()
    }
}

// MARK: - OAuthAuthorizer Invocation Tests

@Suite("OAuthAuthorizer dependency invocations")
struct OAuthAuthorizerTests {

    let endpoint = URL(string: "https://mcp.example.com/mcp")!
    let headers401 = [
        "WWW-Authenticate":
            "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\""
    ]

    func makeAuthorizer(
        grantType: OAuthConfiguration.GrantType = .clientCredentials,
        urlValidator: MockURLValidator = MockURLValidator(),
        discoveryClient: MockDiscoveryClient = MockDiscoveryClient(),
        tokenClient: MockTokenClient = MockTokenClient(),
        registrar: MockClientRegistrar = MockClientRegistrar(),
        authCodeFlow: MockAuthCodeFlow = MockAuthCodeFlow()
    ) -> OAuthAuthorizer {
        let config = OAuthConfiguration(
            grantType: grantType,
            authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret")
        )
        return OAuthAuthorizer(
            configuration: config,
            urlValidator: urlValidator,
            discoveryClient: discoveryClient,
            tokenEndpointClient: tokenClient,
            clientRegistrar: registrar,
            authCodeFlow: authCodeFlow
        )
    }

    // MARK: - validateEndpointSecurity

    @Test("validateEndpointSecurity calls urlValidator")
    func testValidateEndpointSecurityCallsURLValidator() throws {
        let validator = MockURLValidator()
        let authorizer = makeAuthorizer(urlValidator: validator)

        try authorizer.validateEndpointSecurity(for: endpoint)

        #expect(validator.validateHTTPSOrLoopbackCallCount == 1)
    }

    @Test("validateEndpointSecurity propagates validation error")
    func testValidateEndpointSecurityPropagatesError() {
        let validator = MockURLValidator()
        validator.shouldThrow = OAuthAuthorizationError.insecureOAuthEndpoint(
            context: "test", url: "http://example.com")
        let authorizer = makeAuthorizer(urlValidator: validator)

        #expect(throws: OAuthAuthorizationError.self) {
            try authorizer.validateEndpointSecurity(for: endpoint)
        }
    }

    // MARK: - handleChallenge (401 — client_credentials)

    @Test("handleChallenge 401 calls discovery and token clients")
    func testHandleChallenge401CallsDiscoveryAndTokenClient() async throws {
        let discovery = MockDiscoveryClient()
        let tokenClient = MockTokenClient()

        let authorizer = makeAuthorizer(
            discoveryClient: discovery,
            tokenClient: tokenClient
        )

        let handled = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == true)
        #expect(discovery.fetchProtectedResourceMetadataCallCount >= 1)
        #expect(discovery.fetchAuthorizationServerMetadataCallCount >= 1)
        #expect(tokenClient.requestCallCount == 1)
    }

    @Test("handleChallenge 401 uses client_credentials grant type parameter")
    func testHandleChallenge401ClientCredentialsGrantType() async throws {
        let tokenClient = MockTokenClient()
        let authorizer = makeAuthorizer(tokenClient: tokenClient)

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(tokenClient.capturedParameters?["grant_type"] == "client_credentials")
    }

    @Test("handleChallenge 401 attaches resource parameter")
    func testHandleChallenge401AttachesResourceParameter() async throws {
        let tokenClient = MockTokenClient()
        let authorizer = makeAuthorizer(tokenClient: tokenClient)

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(tokenClient.capturedParameters?["resource"] != nil)
    }

    // MARK: - handleChallenge (authorization_code)

    #if canImport(CryptoKit)
    @Test("handleChallenge 401 calls authCodeFlow for authorization_code grant")
    func testHandleChallenge401AuthorizationCodeCallsFlow() async throws {
        let authCodeFlow = MockAuthCodeFlow()
        let tokenClient = MockTokenClient()

        let config = OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: .none(clientID: "my-client"),
            authorizationRedirectURI: URL(string: "https://app.example.com/callback")!
        )
        let authorizer = OAuthAuthorizer(
            configuration: config,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: tokenClient,
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: authCodeFlow
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(authCodeFlow.buildURLCallCount == 1)
        #expect(authCodeFlow.performCallCount == 1)
        #expect(tokenClient.capturedParameters?["grant_type"] == "authorization_code")
        #expect(tokenClient.capturedParameters?["code"] == "mock-auth-code")
    }

    @Test(
        "authorization_code requests offline_access only when advertised",
        arguments: [true, false]
    )
    func testAuthorizationCodeOfflineAccessSelection(advertised: Bool) async throws {
        let authCodeFlow = MockAuthCodeFlow()
        let tokenClient = MockTokenClient()
        let discovery = MockDiscoveryClient()
        let server = URL(string: "https://auth.example.com")!
        discovery.authorizationServerMetadataResult = (
            server: server,
            metadata: OAuthAuthorizationServerMetadata(
                issuer: server,
                authorizationEndpoint: URL(string: "https://auth.example.com/authorize"),
                tokenEndpoint: URL(string: "https://auth.example.com/token"),
                registrationEndpoint: nil,
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil,
                scopesSupported: advertised
                    ? ["mcp:basic", "offline_access"]
                    : ["mcp:basic"]
            )
        )

        let config = OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: .none(clientID: "my-client"),
            authorizationRedirectURI: URL(string: "https://app.example.com/callback")!
        )
        let authorizer = OAuthAuthorizer(
            configuration: config,
            urlValidator: MockURLValidator(),
            discoveryClient: discovery,
            tokenEndpointClient: tokenClient,
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: authCodeFlow
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect((authCodeFlow.capturedScopes?.contains("offline_access") ?? false) == advertised)
        #expect(
            (tokenClient.capturedParameters?["scope"]?.contains("offline_access") ?? false)
                == advertised
        )
    }
    #endif

    // MARK: - handleChallenge (403)

    @Test("handleChallenge 403 returns false for non-insufficient_scope error")
    func testHandleChallenge403NonInsufficientScope() async throws {
        let authorizer = makeAuthorizer()

        let handled = try await authorizer.handleChallenge(
            statusCode: 403,
            headers: ["WWW-Authenticate": "Bearer error=\"access_denied\""],
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == false)
    }

    @Test("handleChallenge 403 insufficient_scope acquires token with upgraded scopes")
    func testHandleChallenge403InsufficientScope() async throws {
        let tokenClient = MockTokenClient()
        let discovery = MockDiscoveryClient()

        let authorizer = makeAuthorizer(
            discoveryClient: discovery,
            tokenClient: tokenClient
        )

        let handled = try await authorizer.handleChallenge(
            statusCode: 403,
            headers: [
                "WWW-Authenticate":
                    "Bearer error=\"insufficient_scope\", scope=\"admin\""
            ],
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == true)
        #expect(tokenClient.requestCallCount == 1)
    }

    @Test("Serializes concurrent scope step-up flows without sharing retry budgets")
    func testConcurrentScopeStepUpFlowsAreIndependent() async throws {
        let tokenClient = MockTokenClient()
        let config = OAuthConfiguration(
            authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret"),
            retryPolicy: OAuthConfiguration.RetryPolicy(maxScopeUpgradeAttempts: 1)
        )
        let authorizer = OAuthAuthorizer(
            configuration: config,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: tokenClient,
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: MockAuthCodeFlow()
        )
        let headers = [
            "WWW-Authenticate":
                "Bearer error=\"insufficient_scope\", scope=\"admin\""
        ]

        let first = Task {
            try await authorizer.handleChallenge(
                statusCode: 403,
                headers: headers,
                endpoint: endpoint,
                operationKey: "tools/call",
                session: .shared
            )
        }
        let second = Task {
            try await authorizer.handleChallenge(
                statusCode: 403,
                headers: headers,
                endpoint: endpoint,
                operationKey: "tools/call",
                session: .shared
            )
        }

        let firstHandled = try await first.value
        let secondHandled = try await second.value
        #expect(firstHandled)
        #expect(secondHandled)
        #expect(tokenClient.requestCallCount == 2)
    }

    @Test("Serializes proactive refresh with a simultaneous challenge")
    func testProactiveRefreshAndChallengeDoNotOverwriteEachOther() async throws {
        let storage = InMemoryTokenStorage()
        let sequence = RefreshSequence()
        let tokenClient = SequencedRefreshTokenClient(sequence: sequence)
        let config = OAuthConfiguration(
            authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret"),
            proactiveRefreshWindowSeconds: 60
        )
        let authorizer = OAuthAuthorizer(
            configuration: config,
            tokenStorage: storage,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: tokenClient,
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: MockAuthCodeFlow()
        )

        #expect(try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        ))

        let proactiveRefresh = Task {
            try await authorizer.prepareAuthorization(for: endpoint, session: .shared)
        }
        await sequence.waitForSecondRequest()
        let challenge = Task {
            try await authorizer.handleChallenge(
                statusCode: 401,
                headers: headers401,
                endpoint: endpoint,
                operationKey: nil,
                session: .shared
            )
        }

        #expect(await sequence.metrics().requestCount == 2)
        await sequence.releaseSecondRequest()
        try await proactiveRefresh.value
        #expect(try await challenge.value)

        let metrics = await sequence.metrics()
        #expect(metrics.requestCount == 3)
        #expect(metrics.maximumActiveRequests == 1)
        #expect(storage.load()?.value == "challenge-token")
    }

    // MARK: - Client registration

    @Test("handleChallenge calls client registrar when authentication is .none")
    func testHandleChallengeCallsRegistrar() async throws {
        let registrar = MockClientRegistrar()
        let config = OAuthConfiguration(
            authentication: .none(clientID: "plain-client"))
        let authorizer = OAuthAuthorizer(
            configuration: config,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(registrar.registerCallCount == 1)
    }

    @Test("Serializes concurrent dynamic registration before token requests")
    func testConcurrentDynamicRegistrationDoesNotUseStaleAuthentication() async throws {
        let gate = RegistrationGate()
        let registrar = BlockingRegistrar(gate: gate)
        let authenticationCapture = AuthenticationCapture()
        let tokenClient = CapturingTokenClient(capture: authenticationCapture)
        let config = OAuthConfiguration(authentication: .none(clientID: ""))
        let authorizer = OAuthAuthorizer(
            configuration: config,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: tokenClient,
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        let first = Task {
            try await authorizer.handleChallenge(
                statusCode: 401,
                headers: headers401,
                endpoint: endpoint,
                operationKey: nil,
                session: .shared
            )
        }
        await gate.waitForFirstEntry()

        let second = Task {
            try await authorizer.handleChallenge(
                statusCode: 401,
                headers: headers401,
                endpoint: endpoint,
                operationKey: nil,
                session: .shared
            )
        }
        #expect(await gate.count() == 1)

        await gate.release()
        #expect(try await first.value == true)
        #expect(try await second.value == true)

        let values = await authenticationCapture.allValues()
        #expect(values.count == 2)
        #expect(values.allSatisfy { value in
            if case .none = value { return false }
            return true
        })
    }

    @Test("Cancels an authorization operation while it waits for the serialized flow")
    func testCancelledAuthorizationWaiterDoesNotStart() async throws {
        let gate = RegistrationGate()
        let registrar = BlockingRegistrar(gate: gate)
        let authorizer = OAuthAuthorizer(
            configuration: OAuthConfiguration(authentication: .none(clientID: "")),
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        let first = Task {
            try await authorizer.handleChallenge(
                statusCode: 401,
                headers: headers401,
                endpoint: endpoint,
                operationKey: nil,
                session: .shared
            )
        }
        await gate.waitForFirstEntry()

        let cancelled = Task {
            try await authorizer.handleChallenge(
                statusCode: 401,
                headers: headers401,
                endpoint: endpoint,
                operationKey: nil,
                session: .shared
            )
        }
        cancelled.cancel()
        await gate.release()

        #expect(try await first.value)
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(await gate.count() == 1)
    }

    @Test("Re-registers when refreshed resource metadata changes authorization server")
    func testAuthorizationServerMigrationReRegisters() async throws {
        let firstIssuer = URL(string: "https://first-auth.example.com")!
        let secondIssuer = URL(string: "https://second-auth.example.com")!
        let discovery = MockDiscoveryClient()
        discovery.protectedResourceMetadataResults = [firstIssuer, secondIssuer].map { issuer in
            OAuthProtectedResourceMetadata(
                resource: nil,
                authorizationServers: [issuer],
                scopesSupported: nil
            )
        }
        discovery.authorizationServerMetadataByIssuer = Dictionary(
            uniqueKeysWithValues: [firstIssuer, secondIssuer].map { issuer in
                (issuer, OAuthAuthorizationServerMetadata(
                    issuer: issuer,
                    authorizationEndpoint: issuer.appendingPathComponent("authorize"),
                    tokenEndpoint: issuer.appendingPathComponent("token"),
                    registrationEndpoint: issuer.appendingPathComponent("register"),
                    codeChallengeMethodsSupported: ["S256"],
                    tokenEndpointAuthMethodsSupported: nil,
                    clientIDMetadataDocumentSupported: nil
                ))
            }
        )

        let registrar = MockClientRegistrar()
        registrar.registrationResults = ["first-client", "second-client"].map { clientID in
            let authentication = OAuthConfiguration.TokenEndpointAuthentication.clientSecretBasic(
                clientID: clientID, clientSecret: "secret")
            return (
                OAuthClientRegistrationResponse(
                    clientID: clientID,
                    clientSecret: "secret",
                    tokenEndpointAuthMethod: nil,
                    clientSecretExpiresAt: nil
                ),
                authentication
            )
        }
        let authenticationCapture = AuthenticationCapture()
        let authorizer = OAuthAuthorizer(
            configuration: OAuthConfiguration(authentication: .none(clientID: "")),
            urlValidator: MockURLValidator(),
            discoveryClient: discovery,
            tokenEndpointClient: CapturingTokenClient(capture: authenticationCapture),
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        for _ in 0..<2 {
            #expect(try await authorizer.handleChallenge(
                statusCode: 401,
                headers: headers401,
                endpoint: endpoint,
                operationKey: nil,
                session: .shared
            ))
        }

        #expect(registrar.registerCallCount == 2)
        let clientIDs = await authenticationCapture.allValues().map(\.clientID)
        #expect(clientIDs == ["first-client", "second-client"])
    }

    @Test("handleChallenge skips client registrar when credentials are already configured")
    func testHandleChallengeSkipsRegistrarWithCredentials() async throws {
        let registrar = MockClientRegistrar()
        let authorizer = makeAuthorizer(registrar: registrar)

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(registrar.registerCallCount == 0)
    }

    @Test("handleChallenge persists the DCR-assigned clientID on the saved token")
    func testHandleChallengePersistsDCRClientIDOnToken() async throws {
        let assignedClientID = "dcr-assigned-client-id"
        let tokenStorage = InMemoryTokenStorage()
        let registrar = MockClientRegistrar()
        registrar.registrationResult = (
            response: OAuthClientRegistrationResponse(
                clientID: assignedClientID,
                clientSecret: nil,
                tokenEndpointAuthMethod: nil,
                clientSecretExpiresAt: nil
            ),
            updatedAuthentication: .none(clientID: assignedClientID)
        )

        let config = OAuthConfiguration(
            authentication: .none(clientID: "")
        )
        let authorizer = OAuthAuthorizer(
            configuration: config,
            tokenStorage: tokenStorage,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        let handled = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == true)
        #expect(registrar.registerCallCount == 1)
        #expect(tokenStorage.load()?.clientID == assignedClientID)
    }
}
