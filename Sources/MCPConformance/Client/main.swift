/**
 * Everything client - a single conformance test client that handles all scenarios.
 *
 * Usage: mcp-everything-client <server-url>
 *
 * The scenario name is read from the MCP_CONFORMANCE_SCENARIO environment variable,
 * which is set by the conformance test runner.
 *
 * This client routes to the appropriate behavior based on the scenario name,
 * consolidating all the individual test clients into one.
 */

import Foundation
import Logging
import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Scenario Handlers

typealias ScenarioHandler = @Sendable ([String]) async throws -> Void

private enum ConformanceProtocolMode: Sendable {
    case modern
    case legacy

    init(environment: [String: String]) throws {
        let requested = environment["MCP_CONFORMANCE_PROTOCOL_VERSION"] ?? Version.latest
        guard Version.allSupported.contains(requested) else {
            throw ConformanceError.invalidArguments(
                "Unsupported MCP_CONFORMANCE_PROTOCOL_VERSION: \(requested)"
            )
        }
        self = requested == Version.modern ? .modern : .legacy
    }

}

private func conformanceProtocolMode() throws -> ConformanceProtocolMode {
    try ConformanceProtocolMode(environment: ProcessInfo.processInfo.environment)
}

private func connectClient(
    _ client: Client,
    transport: HTTPClientTransport,
    mode: ConformanceProtocolMode
) async throws {
    switch mode {
    case .modern:
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .http
        )
    case .legacy:
        _ = try await client.connect(transport: transport)
    }
}

private func listTools(
    with client: Client,
    mode: ConformanceProtocolMode
) async throws -> [Tool] {
    switch mode {
    case .modern:
        return try await client.sendModern(ListTools.request(.init())).value.tools
    case .legacy:
        return try await client.listTools().tools
    }
}

private func callTool(
    with client: Client,
    mode: ConformanceProtocolMode,
    name: String,
    arguments: [String: Value]? = nil
) async throws {
    switch mode {
    case .modern:
        _ = try await client.sendModern(
            CallTool.request(.init(name: name, arguments: arguments))
        )
    case .legacy:
        _ = try await client.callTool(name: name, arguments: arguments)
    }
}

private func makeHTTPTransport(
    endpoint: URL,
    logger: Logger,
    streaming: Bool = true,
    authorizer: (any HTTPClientAuthorizer)? = nil
) -> HTTPClientTransport {
    HTTPClientTransport(
        endpoint: endpoint,
        streaming: streaming,
        authorizer: authorizer,
        logger: logger
    )
}

private let scoredAuthorizationScenarios: Set<String> = [
    "auth/metadata-default",
    "auth/metadata-var1",
    "auth/metadata-var2",
    "auth/metadata-var3",
    "auth/basic-cimd",
    "auth/scope-from-www-authenticate",
    "auth/scope-from-scopes-supported",
    "auth/scope-omitted-when-undefined",
    "auth/scope-step-up",
    "auth/scope-retry-limit",
    "auth/token-endpoint-auth-basic",
    "auth/token-endpoint-auth-post",
    "auth/token-endpoint-auth-none",
    "auth/pre-registration",
    "auth/resource-mismatch",
    "auth/offline-access-scope",
    "auth/offline-access-not-supported",
    "auth/authorization-server-migration",
    "auth/iss-supported",
    "auth/iss-not-advertised",
    "auth/iss-supported-missing",
    "auth/iss-wrong-issuer",
    "auth/iss-unexpected",
    "auth/iss-normalized",
    "auth/metadata-issuer-mismatch",
]

// MARK: - Authorization Scenarios

private func loadConformanceValueContext() throws -> [String: Value] {
    let env = ProcessInfo.processInfo.environment

    if let raw = env["MCP_CONFORMANCE_CONTEXT"] {
        do {
            return try JSONDecoder().decode([String: Value].self, from: Data(raw.utf8))
        } catch {
            throw ConformanceError.invalidArguments(
                "MCP_CONFORMANCE_CONTEXT is not valid JSON: \(error.localizedDescription)"
            )
        }
    }

    var parsed: [String: Value] = [:]
    if let clientID = env["MCP_CONFORMANCE_CLIENT_ID"] {
        parsed["client_id"] = .string(clientID)
    }
    if let clientSecret = env["MCP_CONFORMANCE_CLIENT_SECRET"] {
        parsed["client_secret"] = .string(clientSecret)
    }
    return parsed
}

private func loadStringConformanceContext() throws -> [String: String] {
    try loadConformanceValueContext().compactMapValues(\.stringValue)
}

private func percentEncodeFormValue(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func formURLEncodedBody(_ parameters: [String: String]) -> Data {
    let encoded = parameters
        .sorted { $0.key < $1.key }
        .map { key, value in
            "\(percentEncodeFormValue(key))=\(percentEncodeFormValue(value))"
        }
        .joined(separator: "&")
    return Data(encoded.utf8)
}

private func clientAssertionAudience(from tokenEndpoint: URL) -> String {
    guard var components = URLComponents(url: tokenEndpoint, resolvingAgainstBaseURL: false) else {
        return tokenEndpoint.absoluteString
    }

    components.query = nil
    components.fragment = nil

    var path = components.path
    if path.hasSuffix("/token") {
        path = String(path.dropLast("/token".count))
    } else {
        let parts = path.split(separator: "/")
        if !parts.isEmpty {
            let parent = parts.dropLast()
            path = parent.isEmpty ? "" : "/" + parent.joined(separator: "/")
        }
    }
    if path == "/" {
        path = ""
    }
    components.path = path

    return components.url?.absoluteString ?? tokenEndpoint.absoluteString
}

private func parsePrivateKeyJWTSigningAlgorithm(
    _ signingAlgorithm: String
) throws -> OAuthConfiguration.PrivateKeyJWTSigningAlgorithm {
    switch signingAlgorithm.uppercased() {
    case OAuthConfiguration.PrivateKeyJWTSigningAlgorithm.ES256.rawValue:
        return .ES256
    default:
        throw ConformanceError.invalidArguments(
            "Unsupported signing algorithm: \(signingAlgorithm)"
        )
    }
}

private func makeOAuthConfiguration(
    for scenario: String,
    context: [String: String]
) -> OAuthConfiguration {
    let clientID = context["client_id"] ?? "test-client"
    let clientSecret = context["client_secret"] ?? "test-secret"

    var configuration: OAuthConfiguration
    switch scenario {
    case "auth/pre-registration":
        configuration = .init(
            grantType: .authorizationCode,
            authentication: .clientSecretBasic(
                clientID: clientID,
                clientSecret: clientSecret
            )
        )

    case "auth/token-endpoint-auth-basic":
        configuration = .init(
            grantType: .authorizationCode,
            authentication: .clientSecretBasic(
                clientID: clientID,
                clientSecret: clientSecret
            )
        )

    case "auth/token-endpoint-auth-post":
        configuration = .init(
            grantType: .authorizationCode,
            authentication: .clientSecretPost(
                clientID: clientID,
                clientSecret: clientSecret
            )
        )

    case "auth/client-credentials-basic":
        configuration = .init(
            authentication: .clientSecretBasic(
                clientID: clientID,
                clientSecret: clientSecret
            )
        )

    case "auth/client-credentials-jwt":
        let privateKeyPEM = context["private_key_pem"] ?? ""
        let signingAlgorithm = context["signing_algorithm"] ?? "ES256"
        configuration = .init(
            authentication: .privateKeyJWT(
                clientID: clientID,
                assertionFactory: { tokenEndpoint, clientID in
                    try OAuthConfiguration.makePrivateKeyJWTAssertion(
                        clientID: clientID,
                        tokenEndpoint: tokenEndpoint,
                        privateKeyPEM: privateKeyPEM,
                        signingAlgorithm: try parsePrivateKeyJWTSigningAlgorithm(signingAlgorithm),
                        audience: clientAssertionAudience(from: tokenEndpoint)
                    )
                }
            )
        )

    case "auth/basic-cimd":
        configuration = .init(
            grantType: .authorizationCode,
            authentication: .none(
                clientID: context["client_id"]
                    ?? "https://conformance-test.local/client-metadata.json")
        )

    case "auth/cross-app-access-complete-flow":
        configuration = .init(
            authentication: .clientSecretBasic(
                clientID: clientID,
                clientSecret: clientSecret
            ),
            accessTokenProvider: makeCrossAppAccessTokenProvider(context: context)
        )

    case let s where s.hasPrefix("auth/client-credentials"):
        configuration = .init(
            authentication: .none(clientID: clientID)
        )

    default:
        configuration = .init(
            grantType: .authorizationCode,
            authentication: .none(clientID: clientID)
        )
    }

    // Conformance harness currently uses loopback http AS endpoints.
    configuration.allowLoopbackHTTPAuthorizationServerEndpoints = true
    return configuration
}

private struct ConformanceTokenResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private func requestOAuthToken(
    url: URL,
    parameters: [String: String],
    authorizationHeader: String?,
    session: URLSession
) async throws -> String {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let authorizationHeader {
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
    }
    request.httpBody = formURLEncodedBody(parameters)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw ConformanceError.invalidArguments("Token endpoint returned an invalid response")
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        throw ConformanceError.invalidArguments(
            "Token endpoint error (\(httpResponse.statusCode)): \(body)"
        )
    }

    let token = try JSONDecoder().decode(ConformanceTokenResponse.self, from: data)
    guard !token.accessToken.isEmpty else {
        throw ConformanceError.invalidArguments("Token endpoint returned an empty access token")
    }
    return token.accessToken
}

private func makeCrossAppAccessTokenProvider(
    context: [String: String]
) -> OAuthConfiguration.AccessTokenProvider {
    return { discovery, session in
        guard let clientID = context["client_id"],
            let clientSecret = context["client_secret"],
            let idpClientID = context["idp_client_id"],
            let idpIDToken = context["idp_id_token"],
            let idpTokenEndpointValue = context["idp_token_endpoint"],
            let idpTokenEndpoint = URL(string: idpTokenEndpointValue)
        else {
            throw ConformanceError.invalidArguments(
                "Cross-app scenario requires client_id, client_secret, idp_client_id, idp_id_token, and idp_token_endpoint"
            )
        }

        guard let authorizationServer = discovery.authorizationServer else {
            throw ConformanceError.invalidArguments(
                "SDK did not provide authorization server discovery context"
            )
        }
        guard let tokenEndpoint = discovery.tokenEndpoint else {
            throw ConformanceError.invalidArguments(
                "SDK did not provide token endpoint discovery context"
            )
        }
        let resource = discovery.resource.absoluteString

        let idJag = try await requestOAuthToken(
            url: idpTokenEndpoint,
            parameters: [
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "subject_token": idpIDToken,
                "subject_token_type": "urn:ietf:params:oauth:token-type:id_token",
                "requested_token_type": "urn:ietf:params:oauth:token-type:id-jag",
                "audience": authorizationServer.absoluteString,
                "resource": resource,
                "client_id": idpClientID,
            ],
            authorizationHeader: nil,
            session: session
        )

        var accessTokenParameters: [String: String] = [
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": idJag,
            "resource": resource,
        ]
        if let requestedScopes = discovery.requestedScopes, !requestedScopes.isEmpty {
            accessTokenParameters["scope"] = requestedScopes.sorted().joined(separator: " ")
        }

        let basicCredentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        let accessToken = try await requestOAuthToken(
            url: tokenEndpoint,
            parameters: accessTokenParameters,
            authorizationHeader: "Basic \(basicCredentials)",
            session: session
        )

        return accessToken
    }
}

func runAuthorizationScenario(scenario: String, args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.auth",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting auth scenario", metadata: ["scenario": "\(scenario)"])

    guard let serverURLString = args.last,
        let serverURL = URL(string: serverURLString)
    else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    let mode = try conformanceProtocolMode()
    let context = try loadStringConformanceContext()
    let oauthConfig = makeOAuthConfiguration(for: scenario, context: context)

    let transport = makeHTTPTransport(
        endpoint: serverURL,
        logger: logger,
        streaming: true,
        authorizer: OAuthAuthorizer(configuration: oauthConfig)
    )

    let client = Client(name: "test-client", version: "1.0.0")

    // Scenarios that expect the connection to fail with a specific error.
    if scenario == "auth/resource-mismatch" {
        do {
            try await connectClient(client, transport: transport, mode: mode)
            throw ConformanceError.invalidArguments(
                "Expected authorization to fail with resource mismatch, but connection succeeded"
            )
        } catch let error as MCPError {
            guard case .internalError(let detail) = error,
                detail?.contains("resource mismatch") == true
            else {
                throw ConformanceError.invalidArguments(
                    "Connection failed, but not due to resource mismatch: \(error.localizedDescription)"
                )
            }
            logger.debug("Client correctly rejected mismatched PRM resource")
        }
        return
    }

    try await connectClient(client, transport: transport, mode: mode)

    // Exercise both initialization and regular request paths.
    let tools = try await listTools(with: client, mode: mode)
    logger.debug("Auth scenario listed tools", metadata: ["count": "\(tools.count)"])

    // Trigger an additional request for scenarios that involve runtime scope behavior.
    if scenario.contains("scope") {
        guard let firstTool = tools.first else {
            throw ConformanceError.invalidArguments(
                "Scope scenario did not expose a tool for the runtime scope request"
            )
        }
        try await callTool(with: client, mode: mode, name: firstTool.name, arguments: [:])
    }
    if scenario == "auth/authorization-server-migration" {
        _ = try await listTools(with: client, mode: mode)
    }

    await client.disconnect()
    logger.debug("Auth scenario completed", metadata: ["scenario": "\(scenario)"])
}

// MARK: - Basic Scenarios

/// Basic client that connects, initializes, and lists tools
func runInitializeScenario(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.initialize",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting initialize scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    let mode = try conformanceProtocolMode()

    // Create HTTP transport
    let transport = makeHTTPTransport(
        endpoint: serverURL,
        logger: logger
    )

    // Create client
    let client = Client(name: "test-client", version: "1.0.0")

    // Connect
    try await connectClient(client, transport: transport, mode: mode)
    logger.debug("Successfully connected to MCP server")

    // List tools
    let tools = try await listTools(with: client, mode: mode)
    logger.debug("Successfully listed tools", metadata: [
        "toolCount": "\(tools.count)"
    ])

    // Disconnect
    await client.disconnect()

    logger.debug("Initialize scenario completed successfully")
}

/// Client that calls the add_numbers tool
func runToolsCallScenario(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.tools_call",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting tools_call scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    let mode = try conformanceProtocolMode()

    // Create HTTP transport
    let transport = makeHTTPTransport(
        endpoint: serverURL,
        logger: logger
    )

    // Create client
    let client = Client(name: "test-client", version: "1.0.0")

    // Connect
    try await connectClient(client, transport: transport, mode: mode)
    logger.debug("Successfully connected to MCP server")

    // List tools
    let tools = try await listTools(with: client, mode: mode)
    logger.debug("Successfully listed tools", metadata: [
        "toolCount": "\(tools.count)"
    ])

    // Call the add_numbers tool
    guard tools.contains(where: { $0.name == "add_numbers" }) else {
        throw ConformanceError.invalidArguments("add_numbers tool not found")
    }
    try await callTool(
        with: client,
        mode: mode,
        name: "add_numbers",
        arguments: ["a": 5, "b": 3]
    )
    logger.debug("Tool call completed")

    // Disconnect
    await client.disconnect()

    logger.debug("Tools call scenario completed successfully")
}

// MARK: - SSE Scenarios

/// Handler for SSE-related scenarios (retry, reconnection, etc.)
func runSSEScenario(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.sse",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting SSE scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    let mode = try conformanceProtocolMode()

    // Create HTTP transport with streaming enabled
    let transport = makeHTTPTransport(
        endpoint: serverURL,
        logger: logger,
        streaming: true
    )

    // Create client
    let client = Client(name: "test-client", version: "1.0.0")

    // Connect - this will start the SSE stream in the background
    try await connectClient(client, transport: transport, mode: mode)
    logger.debug("Successfully connected to MCP server")

    // Give the GET SSE stream time to establish
    try await Task.sleep(for: .milliseconds(500))

    // Call the test_reconnection tool to trigger SSE stream closure and retry test.
    // The server will close the POST SSE stream without the response,
    // then deliver it on the GET SSE stream after we reconnect.
    logger.debug("Calling test_reconnection tool...")
    try await callTool(
        with: client,
        mode: mode,
        name: "test_reconnection",
        arguments: [:]
    )
    logger.debug("Tool call result received")

    // Keep the connection open briefly for the test to collect timing data
    try await Task.sleep(for: .seconds(2))

    // Disconnect
    await client.disconnect()

    logger.debug("SSE scenario completed")
}

/// Client that handles elicitation-sep1034-client-defaults scenario
/// Tests that client properly applies default values for omitted fields
func runElicitationSEP1034ClientDefaults(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.elicitation_client_defaults",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting elicitation-sep1034-client-defaults scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    let mode = try conformanceProtocolMode()

    // Create HTTP transport with streaming enabled for bidirectional communication
    let transport = makeHTTPTransport(
        endpoint: serverURL,
        logger: logger,
        streaming: true
    )

    // Create client with elicitation capabilities
    let client = Client(
        name: "test-client",
        version: "1.0.0",
        capabilities: Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: .init(), url: .init())
        )
    )

    // Set up elicitation handler that accepts defaults BEFORE connecting
    await client.withElicitationHandler { [logger] params in
        let message: String
        switch params {
        case .form(let formParams):
            message = formParams.message
        case .url(let urlParams):
            message = urlParams.message
        }

        logger.debug("Elicitation handler invoked", metadata: [
            "message": "\(message)"
        ])

        // Accept with default values applied
        // The schema has optional fields with defaults:
        // name: "John Doe", age: 30, score: 95.5, status: "active", verified: true
        return CreateElicitation.Result(
            action: .accept,
            content: [
                "name": "John Doe",
                "age": 30,
                "score": 95.5,
                "status": "active",
                "verified": true
            ]
        )
    }

    // Connect
    try await connectClient(client, transport: transport, mode: mode)
    logger.debug("Successfully connected to MCP server")

    // List tools
    let tools = try await listTools(with: client, mode: mode)
    logger.debug("Successfully listed tools", metadata: [
        "toolCount": "\(tools.count)"
    ])

    // Call the test_client_elicitation_defaults tool
    guard tools.contains(where: { $0.name == "test_client_elicitation_defaults" }) else {
        throw ConformanceError.invalidArguments(
            "test_client_elicitation_defaults tool not found"
        )
    }
    try await callTool(
        with: client,
        mode: mode,
        name: "test_client_elicitation_defaults",
        arguments: [:]
    )
    logger.debug("Tool call completed")

    // Disconnect
    await client.disconnect()

    logger.debug("Elicitation client defaults scenario completed successfully")
}

// MARK: - Modern Scored Scenarios

private func runModernScoredScenario(scenario: String, args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.modern",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    guard let serverURLString = args.last,
        let serverURL = URL(string: serverURLString)
    else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }
    let mode = try conformanceProtocolMode()
    guard case .modern = mode else {
        throw ConformanceError.invalidArguments(
            "Scenario \(scenario) requires protocol version \(Version.modern)"
        )
    }

    let transport = makeHTTPTransport(
        endpoint: serverURL,
        logger: logger
    )
    let client = Client(
        name: "test-client",
        version: "1.0.0",
        capabilities: .init(
            sampling: .init(),
            elicitation: .init(),
            roots: .init()
        )
    )
    await client.withRootsHandler {
        [Root(uri: "file:///workspace", name: "conformance-workspace")]
    }
    await client.withSamplingHandler { _ in
        CreateSamplingMessage.Result(
            model: "conformance-model",
            stopReason: .endTurn,
            role: .assistant,
            content: .text("conformance response")
        )
    }
    await client.withElicitationHandler { _ in
        CreateElicitation.Result(action: .accept, content: ["confirmed": true])
    }

    try await connectClient(client, transport: transport, mode: mode)
    do {
        switch scenario {
        case "request-metadata":
            _ = try await listTools(with: client, mode: mode)

        case "sep-2322-client-request-state":
            for name in [
                "test_mrtr_echo_state",
                "test_mrtr_no_state",
                "test_mrtr_unrelated",
                "test_mrtr_no_result_type",
            ] {
                try await callTool(with: client, mode: mode, name: name, arguments: [:])
            }

        case "http-standard-headers":
            let tools = try await listTools(with: client, mode: mode)
            guard let tool = tools.first else {
                throw ConformanceError.invalidArguments("Header scenario returned no tools")
            }
            try await callTool(with: client, mode: mode, name: tool.name, arguments: [:])

            let resources = try await client.sendModern(
                ListResources.request(.init())
            ).value.resources
            guard let resource = resources.first else {
                throw ConformanceError.invalidArguments("Header scenario returned no resources")
            }
            _ = try await client.sendModern(
                ReadResource.request(.init(uri: resource.uri))
            )

            let prompts = try await client.sendModern(
                ListPrompts.request(.init())
            ).value.prompts
            guard let prompt = prompts.first else {
                throw ConformanceError.invalidArguments("Header scenario returned no prompts")
            }
            _ = try await client.sendModern(
                GetPrompt.request(.init(name: prompt.name))
            )

        case "http-custom-headers":
            guard let calls = try loadConformanceValueContext()["toolCalls"]?.arrayValue else {
                throw ConformanceError.invalidArguments(
                    "http-custom-headers requires context.toolCalls"
                )
            }
            for call in calls {
                guard let fields = call.objectValue,
                    let name = fields["name"]?.stringValue,
                    let arguments = fields["arguments"]?.objectValue
                else {
                    throw ConformanceError.invalidArguments(
                        "Each context.toolCalls entry requires name and arguments"
                    )
                }
                try await callTool(
                    with: client,
                    mode: mode,
                    name: name,
                    arguments: arguments
                )
            }

        case "http-invalid-tool-headers":
            try await callTool(
                with: client,
                mode: mode,
                name: "valid_tool",
                arguments: ["region": "us-west1"]
            )

        case "json-schema-ref-no-deref":
            _ = try await listTools(with: client, mode: mode)

        default:
            throw ConformanceError.invalidArguments("Unsupported modern scenario: \(scenario)")
        }
        await client.disconnect()
    } catch {
        await client.disconnect()
        throw error
    }
}

// MARK: - Scenario Registry

let scenarioHandlers: [String: ScenarioHandler] = [
    "initialize": runInitializeScenario,
    "tools_call": runToolsCallScenario,
    "sse-retry": runSSEScenario,
    "elicitation-sep1034-client-defaults": runElicitationSEP1034ClientDefaults,
    "request-metadata": { try await runModernScoredScenario(scenario: "request-metadata", args: $0) },
    "sep-2322-client-request-state": {
        try await runModernScoredScenario(scenario: "sep-2322-client-request-state", args: $0)
    },
    "http-standard-headers": {
        try await runModernScoredScenario(scenario: "http-standard-headers", args: $0)
    },
    "http-custom-headers": {
        try await runModernScoredScenario(scenario: "http-custom-headers", args: $0)
    },
    "http-invalid-tool-headers": {
        try await runModernScoredScenario(scenario: "http-invalid-tool-headers", args: $0)
    },
    "json-schema-ref-no-deref": {
        try await runModernScoredScenario(scenario: "json-schema-ref-no-deref", args: $0)
    },
]

// MARK: - Error Types

enum ConformanceError: Error, CustomStringConvertible {
    case missingScenario
    case invalidArguments(String)

    var description: String {
        switch self {
        case .missingScenario:
            return "MCP_CONFORMANCE_SCENARIO environment variable not set"
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        }
    }
}

struct ConformanceClient {
    static func run() async {
        do {
            // Get scenario from environment
            guard let scenario = ProcessInfo.processInfo.environment["MCP_CONFORMANCE_SCENARIO"] else {
                var stderr = StandardError()
                print("Error: MCP_CONFORMANCE_SCENARIO environment variable not set", to: &stderr)
                Foundation.exit(1)
            }

            // Get server URL from arguments (last argument)
            let args = Array(CommandLine.arguments.dropFirst())
            guard !args.isEmpty else {
                var stderr = StandardError()
                print("Usage: mcp-everything-client <server-url>", to: &stderr)
                print("Error: Server URL is required", to: &stderr)
                Foundation.exit(1)
            }

            // Get handler for scenario
            let handler: ScenarioHandler
            if let explicitHandler = scenarioHandlers[scenario] {
                handler = explicitHandler
            } else if scoredAuthorizationScenarios.contains(scenario) {
                handler = { args in
                    try await runAuthorizationScenario(scenario: scenario, args: args)
                }
            } else {
                throw ConformanceError.invalidArguments("Unsupported scenario: \(scenario)")
            }

            // Run the scenario
            try await handler(args)
            Foundation.exit(0)
        } catch {
            var stderr = StandardError()
            print("Error: \(error)", to: &stderr)
            Foundation.exit(1)
        }
    }
}

// MARK: - Helpers

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

await ConformanceClient.run()
