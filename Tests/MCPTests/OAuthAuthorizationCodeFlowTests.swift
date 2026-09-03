import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("OAuthAuthorizationCodeFlow")
struct OAuthAuthorizationCodeFlowTests {

    let flow = OAuthAuthorizationCodeFlow()
    let authEndpoint = URL(string: "https://auth.example.com/authorize")!
    let resource = URL(string: "https://api.example.com")!
    let redirectURI = URL(string: "https://app.example.com/callback")!
    let scopeSelector = DefaultOAuthScopeSelector()

    // MARK: - buildURL

    @Test("buildURL includes all required parameters")
    func testBuildURLRequiredParams() throws {
        let url = try flow.buildURL(
            authorizationEndpoint: authEndpoint,
            resource: resource,
            redirectURI: redirectURI,
            clientID: "my-client",
            codeChallenge: "abc123",
            scopes: nil,
            state: "state-xyz",
            scopeSerializer: scopeSelector
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(
            uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })

        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "my-client")
        #expect(items["redirect_uri"] == redirectURI.absoluteString)
        #expect(items["state"] == "state-xyz")
        #expect(items["resource"] == resource.absoluteString)
        #expect(items["code_challenge"] == "abc123")
        #expect(items["code_challenge_method"] == "S256")
    }

    @Test("buildURL includes scope when provided")
    func testBuildURLWithScope() throws {
        let url = try flow.buildURL(
            authorizationEndpoint: authEndpoint,
            resource: resource,
            redirectURI: redirectURI,
            clientID: "my-client",
            codeChallenge: "abc123",
            scopes: Set(["read", "write"]),
            state: "state-xyz",
            scopeSerializer: scopeSelector
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(
            uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })

        let scope = items["scope"] ?? ""
        #expect(scope.contains("read"))
        #expect(scope.contains("write"))
    }

    @Test("buildURL omits scope for nil scopes")
    func testBuildURLOmitsScopeWhenNil() throws {
        let url = try flow.buildURL(
            authorizationEndpoint: authEndpoint,
            resource: resource,
            redirectURI: redirectURI,
            clientID: "my-client",
            codeChallenge: "abc123",
            scopes: nil,
            state: "state-xyz",
            scopeSerializer: scopeSelector
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = components.queryItems ?? []
        #expect(!items.contains(where: { $0.name == "scope" }))
    }

    @Test("buildURL omits scope for empty scope set")
    func testBuildURLOmitsScopeWhenEmpty() throws {
        let url = try flow.buildURL(
            authorizationEndpoint: authEndpoint,
            resource: resource,
            redirectURI: redirectURI,
            clientID: "my-client",
            codeChallenge: "abc123",
            scopes: Set(),
            state: "state-xyz",
            scopeSerializer: scopeSelector
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = components.queryItems ?? []
        #expect(!items.contains(where: { $0.name == "scope" }))
    }

    // MARK: - extractCode

    @Test("extractCode returns code from valid redirect URL")
    func testExtractCodeSuccess() throws {
        let redirectURL = URL(string:
            "https://app.example.com/callback?code=auth-code-123&state=my-state")!
        let code = try flow.extractCode(
            from: redirectURL,
            expectedRedirectURI: redirectURI,
            expectedState: "my-state"
        )
        #expect(code == "auth-code-123")
    }

    @Test("extractCode throws state mismatch")
    func testExtractCodeThrowsStateMismatch() {
        let redirectURL = URL(string:
            "https://app.example.com/callback?code=auth-code-123&state=wrong-state")!
        #expect(throws: OAuthAuthorizationError.self) {
            try flow.extractCode(
                from: redirectURL,
                expectedRedirectURI: redirectURI,
                expectedState: "my-state"
            )
        }
    }

    @Test("extractCode throws missing state")
    func testExtractCodeThrowsMissingState() {
        let redirectURL = URL(string:
            "https://app.example.com/callback?code=auth-code-123")!
        #expect(throws: OAuthAuthorizationError.self) {
            try flow.extractCode(
                from: redirectURL,
                expectedRedirectURI: redirectURI,
                expectedState: "my-state"
            )
        }
    }

    @Test("extractCode throws missing code")
    func testExtractCodeThrowsMissingCode() {
        let redirectURL = URL(string:
            "https://app.example.com/callback?state=my-state")!
        #expect(throws: OAuthAuthorizationError.self) {
            try flow.extractCode(
                from: redirectURL,
                expectedRedirectURI: redirectURI,
                expectedState: "my-state"
            )
        }
    }

    @Test("extractCode throws redirect URI mismatch")
    func testExtractCodeThrowsRedirectMismatch() {
        let redirectURL = URL(string:
            "https://evil.example.com/callback?code=auth-code-123&state=my-state")!
        #expect(throws: OAuthAuthorizationError.self) {
            try flow.extractCode(
                from: redirectURL,
                expectedRedirectURI: redirectURI,
                expectedState: "my-state"
            )
        }
    }

    @Test("extractCode normalizes host case in redirect URI comparison")
    func testExtractCodeCaseInsensitiveHost() throws {
        let redirectURL = URL(string:
            "https://APP.EXAMPLE.COM/callback?code=auth-code-123&state=my-state")!
        let code = try flow.extractCode(
            from: redirectURL,
            expectedRedirectURI: redirectURI,
            expectedState: "my-state"
        )
        #expect(code == "auth-code-123")
    }

    @Test("extractCode accepts an exact authorization response issuer")
    func testExtractCodeAcceptsMatchingIssuer() throws {
        let issuer = "https://auth.example.com"
        let redirectURL = URL(string:
            "https://app.example.com/callback?code=auth-code-123&state=my-state&iss=\(issuer)")!
        let code = try flow.extractCode(
            from: redirectURL,
            expectedRedirectURI: redirectURI,
            expectedState: "my-state",
            expectedIssuer: issuer,
            authorizationResponseIssParameterSupported: true
        )
        #expect(code == "auth-code-123")
    }

    @Test("extractCode accepts an absent issuer when support is not advertised")
    func testExtractCodeAcceptsAbsentUnadvertisedIssuer() throws {
        let redirectURL = URL(string:
            "https://app.example.com/callback?code=auth-code-123&state=my-state")!
        let code = try flow.extractCode(
            from: redirectURL,
            expectedRedirectURI: redirectURI,
            expectedState: "my-state",
            expectedIssuer: "https://auth.example.com",
            authorizationResponseIssParameterSupported: nil
        )
        #expect(code == "auth-code-123")
    }

    @Test("extractCode rejects a missing required authorization response issuer")
    func testExtractCodeRejectsMissingRequiredIssuer() {
        let redirectURL = URL(string:
            "https://app.example.com/callback?code=auth-code-123&state=my-state")!
        #expect(throws: OAuthAuthorizationError.self) {
            try flow.extractCode(
                from: redirectURL,
                expectedRedirectURI: redirectURI,
                expectedState: "my-state",
                expectedIssuer: "https://auth.example.com",
                authorizationResponseIssParameterSupported: true
            )
        }
    }

    @Test("extractCode compares authorization response issuer as an exact string")
    func testExtractCodeRejectsNormalizedIssuer() {
        let redirectURL = URL(string:
            "https://app.example.com/callback?code=auth-code-123&state=my-state&iss=https://auth.example.com/")!
        #expect(throws: OAuthAuthorizationError.self) {
            try flow.extractCode(
                from: redirectURL,
                expectedRedirectURI: redirectURI,
                expectedState: "my-state",
                expectedIssuer: "https://auth.example.com",
                authorizationResponseIssParameterSupported: false
            )
        }
    }

    @Test("extractCode rejects duplicate authorization response parameters")
    func testExtractCodeRejectsDuplicateAuthorizationResponseParameters() {
        let redirectURL = URL(string:
            "https://app.example.com/callback?code=one&code=two&state=my-state&iss=https://auth.example.com")!
        #expect(throws: OAuthAuthorizationError.self) {
            try flow.extractCode(
                from: redirectURL,
                expectedRedirectURI: redirectURI,
                expectedState: "my-state",
                expectedIssuer: "https://auth.example.com",
                authorizationResponseIssParameterSupported: true
            )
        }
    }
}
