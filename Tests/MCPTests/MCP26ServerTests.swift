import Foundation
import Testing

@testable import MCP

private enum ModernServerTestError: Swift.Error {
    case missingBody
    case timedOut
    case unexpectedResponse
}

private actor ModernServerProbe {
    private(set) var authorizations: [String] = []
    private(set) var callCount = 0
    private(set) var requestStates: [String?] = []
    private(set) var barrierCount = 0

    func recordAuthorization(_ value: String?) {
        authorizations.append(value ?? "")
    }

    func recordCall(state: String?) {
        callCount += 1
        requestStates.append(state)
    }

    func recordBarrier() {
        barrierCount += 1
    }
}

private actor ModernServerGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct ModernBarrierNotification: MCP.Notification {
    static let name = "notifications/test-modern-barrier"

    struct Parameters: Hashable, Codable, Sendable {
        let marker: Bool
    }
}

private func modernMetadata(
    capabilities: [String: Value] = [:],
    logLevel: String? = nil,
    progressToken: ProgressToken? = nil
) throws -> Value {
    try Value(
        RequestMetadata(
            clientCapabilities: CapabilitySet(capabilities),
            logLevel: logLevel,
            progressToken: progressToken
        )
    )
}

private func modernServerBody(
    id: String,
    method: String,
    parameters: [String: Value],
    capabilities: [String: Value] = [:],
    logLevel: String? = nil,
    progressToken: ProgressToken? = nil
) throws -> Data {
    var parameters = parameters
    parameters["_meta"] = try modernMetadata(
        capabilities: capabilities,
        logLevel: logLevel,
        progressToken: progressToken
    )
    let request = Request<AnyMethod>(
        id: .string(id),
        method: method,
        params: .object(parameters)
    )
    return try JSONEncoder().encode(request)
}

private func modernServerRequest(
    id: String,
    method: String,
    name: String? = nil,
    parameters: [String: Value],
    capabilities: [String: Value] = [:],
    logLevel: String? = nil,
    progressToken: ProgressToken? = nil,
    additionalHeaders: [String: String] = [:]
) throws -> HTTPRequest {
    var headers: [String: String] = [
        HTTPHeaderName.contentType: ContentType.json,
        HTTPHeaderName.accept: "application/json, text/event-stream",
        HTTPHeaderName.protocolVersion: Version.modern,
        HTTPHeaderName.method: method,
    ]
    if let name {
        headers[HTTPHeaderName.name] = name
    }
    headers.merge(additionalHeaders) { _, new in new }
    return HTTPRequest(
        method: "POST",
        headers: headers,
        body: try modernServerBody(
            id: id,
            method: method,
            parameters: parameters,
            capabilities: capabilities,
            logLevel: logLevel,
            progressToken: progressToken
        ),
        path: "/mcp"
    )
}

private func modernServerResult(_ response: HTTPResponse) throws -> Value {
    guard let data = response.bodyData else { throw ModernServerTestError.missingBody }
    let decoded = try JSONDecoder().decode(AnyResponse.self, from: data)
    switch decoded.result {
    case .success(let value):
        return value
    case .failure:
        throw ModernServerTestError.unexpectedResponse
    }
}

private func modernServerError(_ response: HTTPResponse) throws -> MCPError {
    guard let data = response.bodyData else { throw ModernServerTestError.missingBody }
    let decoded = try JSONDecoder().decode(AnyResponse.self, from: data)
    switch decoded.result {
    case .success:
        throw ModernServerTestError.unexpectedResponse
    case .failure(let error):
        return error
    }
}

private func nextModernServerChunk(
    from response: HTTPResponse,
    timeout: Duration = .seconds(1)
) async throws -> Data {
    guard case .stream(let stream, _) = response else {
        throw ModernServerTestError.unexpectedResponse
    }
    return try await withThrowingTaskGroup(of: Data?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ModernServerTestError.timedOut
        }
        defer { group.cancelAll() }
        guard let chunk = try await group.next() ?? nil else {
            throw ModernServerTestError.unexpectedResponse
        }
        return chunk
    }
}

private func modernServerSSEObject(_ data: Data) throws -> [String: Value] {
    let text = String(decoding: data, as: UTF8.self)
    guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }) else {
        throw ModernServerTestError.unexpectedResponse
    }
    return try JSONDecoder().decode(
        [String: Value].self,
        from: Data(line.dropFirst("data: ".count).utf8)
    )
}

private func waitForModernSubscriptionCleanup(_ server: Server) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while !(await server.modernSubscriptions.isEmpty) {
        guard clock.now < deadline else { throw ModernServerTestError.timedOut }
        await Task.yield()
    }
}

private func waitForModernStreamTask(
    _ server: Server,
    id: ID,
    present: Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while (await server.modernStreamRequestTasks[id] != nil) != present {
        guard clock.now < deadline else { throw ModernServerTestError.timedOut }
        await Task.yield()
    }
}

private let modernHeaderTool = Tool(
    name: "echo",
    description: "Echoes a tenant",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "tenant": .object([
                "type": .string("string"),
                "x-mcp-header": .string("Tenant"),
            ])
        ]),
    ])
)

private let invalidModernHeaderTool = Tool(
    name: "invalid",
    description: nil,
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "value": .object([
                "type": .string("array"),
                "x-mcp-header": .string("Value"),
            ])
        ]),
    ])
)

@Suite("MCP 2026 Server Tests")
struct MCP26ServerTests {
    @Test("Discovery is mandatory and returns modern server metadata", .timeLimit(.minutes(1)))
    func discoveryReturnsModernContract() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "modern-server",
            version: "2.0",
            capabilities: .init(tools: .init(listChanged: true))
        )
        try await server.start(transport: transport)

        let response = await transport.handleRequest(
            try modernServerRequest(
                id: "discover",
                method: ServerDiscover.name,
                parameters: [:]
            )
        )
        let result = try modernServerResult(response)
        let fields = try #require(result.objectValue)
        let metadata = try #require(fields["_meta"]?.objectValue)
        let serverInfo = try #require(
            metadata[ResultMetadata.serverInfoKey]?.objectValue
        )

        #expect(fields["supportedVersions"] == .array([.string(Version.modern)]))
        #expect(fields["resultType"] == .string(ResultType.complete.rawValue))
        #expect(fields["cacheScope"] == .string(CacheScope.private.rawValue))
        #expect(fields["ttlMs"] == .int(0))
        #expect(serverInfo["name"] == .string("modern-server"))
        #expect(fields["capabilities"]?.objectValue?["tools"] != nil)
        await server.stop()
    }

    @Test(
        "Tool header validation uses paginated discovery in the current authorization context",
        .timeLimit(.minutes(1))
    )
    func toolHeadersUseCurrentAuthorizedPaginationAndBounds() async throws {
        let probe = ModernServerProbe()
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "modern-server",
            version: "2.0",
            capabilities: .init(tools: .init()),
            configuration: .init(maxToolSchemaLookupPages: 2)
        )

        await server.withMethodHandler(ListTools.self) { parameters in
            let authorization = Server.currentHandlerContext?.httpContext?.header(
                HTTPHeaderName.authorization
            )
            await probe.recordAuthorization(authorization)
            switch authorization {
            case "Bearer page":
                return parameters.cursor == nil
                    ? .init(tools: [], nextCursor: "page-2")
                    : .init(tools: [modernHeaderTool])
            case "Cycle":
                return .init(tools: [], nextCursor: "same")
            case "Exhaust":
                return .init(
                    tools: [],
                    nextCursor: parameters.cursor == nil ? "one" : "two"
                )
            case "Filter":
                return .init(tools: [invalidModernHeaderTool])
            default:
                return .init(tools: [modernHeaderTool])
            }
        }
        await server.withMethodHandler(CallTool.self) {
            _ async throws -> Server.ModernHandlerResult<CallTool.Result> in
            await probe.recordCall(state: Server.currentHandlerContext?.requestState)
            return .complete(.init())
        }
        try await server.start(transport: transport)

        let valid = await transport.handleRequest(
            try modernServerRequest(
                id: "valid",
                method: CallTool.name,
                name: "echo",
                parameters: [
                    "name": .string("echo"),
                    "arguments": .object(["tenant": .string("東京")]),
                ],
                additionalHeaders: [
                    HTTPHeaderName.authorization: "Bearer page",
                    "Mcp-Param-Tenant": "=?base64?5p2x5Lqs?=",
                ]
            )
        )
        #expect(try modernServerResult(valid).objectValue?["resultType"] == .string("complete"))
        #expect(await probe.callCount == 1)
        #expect(await probe.authorizations == ["Bearer page", "Bearer page"])

        let mismatch = await transport.handleRequest(
            try modernServerRequest(
                id: "mismatch",
                method: CallTool.name,
                name: "echo",
                parameters: [
                    "name": .string("echo"),
                    "arguments": .object(["tenant": .string("acme")]),
                ],
                additionalHeaders: ["Mcp-Param-Tenant": "wrong"]
            )
        )
        #expect(try modernServerError(mismatch).code == MCPError.headerMismatch(nil).code)
        #expect(await probe.callCount == 1)

        let missing = await transport.handleRequest(
            try modernServerRequest(
                id: "missing-header",
                method: CallTool.name,
                name: "echo",
                parameters: [
                    "name": .string("echo"),
                    "arguments": .object(["tenant": .string("acme")]),
                ]
            )
        )
        #expect(try modernServerError(missing).code == MCPError.headerMismatch(nil).code)

        let unexpected = await transport.handleRequest(
            try modernServerRequest(
                id: "unexpected-header",
                method: CallTool.name,
                name: "echo",
                parameters: ["name": .string("echo"), "arguments": .object([:])],
                additionalHeaders: ["Mcp-Param-Tenant": "acme"]
            )
        )
        #expect(try modernServerError(unexpected).code == MCPError.headerMismatch(nil).code)
        #expect(await probe.callCount == 1)

        let cycle = await transport.handleRequest(
            try modernServerRequest(
                id: "cycle",
                method: CallTool.name,
                name: "missing",
                parameters: ["name": .string("missing"), "arguments": .object([:])],
                additionalHeaders: [HTTPHeaderName.authorization: "Cycle"]
            )
        )
        #expect(try modernServerError(cycle).code == MCPError.invalidParams(nil).code)

        let exhausted = await transport.handleRequest(
            try modernServerRequest(
                id: "exhausted",
                method: CallTool.name,
                name: "missing",
                parameters: ["name": .string("missing"), "arguments": .object([:])],
                additionalHeaders: [HTTPHeaderName.authorization: "Exhaust"]
            )
        )
        #expect(
            try modernServerError(exhausted).code
                == MCPError.localLimitExceeded(resource: "", limit: 1).code
        )

        let filtered = await transport.handleRequest(
            try modernServerRequest(
                id: "filtered",
                method: ListTools.name,
                parameters: [:],
                additionalHeaders: [HTTPHeaderName.authorization: "Filter"]
            )
        )
        let filteredTools = try #require(
            modernServerResult(filtered).objectValue?["tools"]?.arrayValue
        )
        #expect(filteredTools.isEmpty)
        await server.stop()
    }

    @Test(
        "Method, capability, and metadata gates run before application handlers",
        .timeLimit(.minutes(1))
    )
    func modernGatesPrecedeApplicationHandlers() async throws {
        let probe = ModernServerProbe()
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "modern-server",
            version: "2.0",
            capabilities: .init(tools: .init())
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [modernHeaderTool])
        }
        await server.withMethodHandler(CallTool.self) {
            _ async throws -> Server.ModernHandlerResult<CallTool.Result> in
            await probe.recordCall(state: nil)
            return .complete(.init())
        }
        try await server.start(transport: transport)

        let headerMismatch = await transport.handleRequest(
            try modernServerRequest(
                id: "header-mismatch",
                method: CallTool.name,
                name: "echo",
                parameters: ["name": .string("echo"), "arguments": .object([:])],
                additionalHeaders: [HTTPHeaderName.method: ListTools.name]
            )
        )
        #expect(try modernServerError(headerMismatch).code == MCPError.headerMismatch(nil).code)

        let missingCapability = await transport.handleRequest(
            try modernServerRequest(
                id: "missing-capability",
                method: ListResources.name,
                parameters: [:]
            )
        )
        #expect(try modernServerError(missingCapability).code == MCPError.methodNotFound(nil).code)

        let removed = await transport.handleRequest(
            try modernServerRequest(
                id: "removed",
                method: Initialize.name,
                parameters: [:]
            )
        )
        #expect(try modernServerError(removed).code == MCPError.methodNotFound(nil).code)

        let invalidLogLevel = await transport.handleRequest(
            try modernServerRequest(
                id: "invalid-log",
                method: CallTool.name,
                name: "echo",
                parameters: ["name": .string("echo"), "arguments": .object([:])],
                logLevel: "verbose"
            )
        )
        #expect(try modernServerError(invalidLogLevel).code == MCPError.invalidParams(nil).code)
        #expect(await probe.callCount == 0)
        await server.stop()
    }

    @Test(
        "MRTR remains request-scoped and application owns opaque state integrity",
        .timeLimit(.minutes(1))
    )
    func mrtrIsRequestScopedAndApplicationValidatesState() async throws {
        let probe = ModernServerProbe()
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "modern-server",
            version: "2.0",
            capabilities: .init(tools: .init())
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [modernHeaderTool])
        }
        await server.withMethodHandler(CallTool.self) {
            _ async throws -> Server.ModernHandlerResult<CallTool.Result> in
            let state = Server.currentHandlerContext?.requestState
            await probe.recordCall(state: state)
            if let state {
                guard state == "signed-state" else {
                    throw MCPError.invalidParams("Application rejected requestState")
                }
                return .complete(.init())
            }
            return .inputRequired(
                InputRequiredResult(
                    inputRequests: [
                        "roots": InputRequest(method: .rootsList)
                    ],
                    requestState: "signed-state"
                )
            )
        }
        try await server.start(transport: transport)

        let first = await transport.handleRequest(
            try modernServerRequest(
                id: "first",
                method: CallTool.name,
                name: "echo",
                parameters: ["name": .string("echo"), "arguments": .object([:])],
                capabilities: ["roots": .object([:])]
            )
        )
        let firstFields = try #require(modernServerResult(first).objectValue)
        #expect(firstFields["resultType"] == .string(ResultType.inputRequired.rawValue))
        #expect(firstFields["requestState"] == .string("signed-state"))

        let missingCapability = await transport.handleRequest(
            try modernServerRequest(
                id: "missing-capability",
                method: CallTool.name,
                name: "echo",
                parameters: ["name": .string("echo"), "arguments": .object([:])]
            )
        )
        #expect(
            try modernServerError(missingCapability).code
                == MCPError.missingRequiredClientCapability(required: [:]).code
        )

        let tampered = await transport.handleRequest(
            try modernServerRequest(
                id: "tampered",
                method: CallTool.name,
                name: "echo",
                parameters: [
                    "name": .string("echo"),
                    "arguments": .object([:]),
                    "requestState": .string("tampered"),
                ],
                capabilities: ["roots": .object([:])]
            )
        )
        #expect(try modernServerError(tampered).code == MCPError.invalidParams(nil).code)
        #expect(await probe.requestStates == [nil, nil, "tampered"])
        await server.stop()
    }

    @Test(
        "Progress and filtered logs stay on their request exchange",
        .timeLimit(.minutes(1))
    )
    func requestScopedProgressAndLogging() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "modern-server",
            version: "2.0",
            capabilities: .init(logging: .init(), tools: .init())
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [modernHeaderTool])
        }
        await server.withMethodHandler(CallTool.self) {
            _ async throws -> Server.ModernHandlerResult<CallTool.Result> in
            try await server.notify(
                ProgressNotification.message(
                    .init(progressToken: .string("p"), progress: 1)
                )
            )
            try await server.log(level: .debug, data: .string("hidden"))
            try await server.log(level: .error, data: .string("shown"))
            return .complete(.init())
        }
        try await server.start(transport: transport)

        let response = await transport.handleRequest(
            try modernServerRequest(
                id: "streamed",
                method: CallTool.name,
                name: "echo",
                parameters: ["name": .string("echo"), "arguments": .object([:])],
                logLevel: LogLevel.warning.rawValue,
                progressToken: .string("p")
            )
        )
        let progress = try modernServerSSEObject(
            await nextModernServerChunk(from: response)
        )
        let log = try modernServerSSEObject(
            await nextModernServerChunk(from: response)
        )
        let terminal = try modernServerSSEObject(
            await nextModernServerChunk(from: response)
        )

        #expect(progress["method"] == .string(ProgressNotification.name))
        #expect(log["method"] == .string(LogMessageNotification.name))
        #expect(log["params"]?.objectValue?["level"] == .string(LogLevel.error.rawValue))
        #expect(terminal["result"]?.objectValue?["resultType"] == .string("complete"))
        await server.stop()
    }

    @Test(
        "Subscriptions acknowledge first, isolate equal IDs, filter, and close on stop",
        .timeLimit(.minutes(1))
    )
    func subscriptionsFilterAndClosePerExchange() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "modern-server",
            version: "2.0",
            capabilities: .init(
                resources: .init(subscribe: true),
                tools: .init(listChanged: true)
            )
        )
        try await server.start(transport: transport)

        let toolTask = Task {
            await transport.handleRequest(
                try modernServerRequest(
                    id: "same",
                    method: SubscriptionsListenRequest.name,
                    parameters: [
                        "notifications": try Value(
                            SubscriptionFilter(toolsListChanged: true)
                        )
                    ]
                )
            )
        }
        let resourceTask = Task {
            await transport.handleRequest(
                try modernServerRequest(
                    id: "same",
                    method: SubscriptionsListenRequest.name,
                    parameters: [
                        "notifications": try Value(
                            SubscriptionFilter(resourceSubscriptions: ["file:///a"])
                        )
                    ]
                )
            )
        }
        let toolResponse = try await toolTask.value
        let resourceResponse = try await resourceTask.value

        let toolAcknowledgement = try modernServerSSEObject(
            await nextModernServerChunk(from: toolResponse)
        )
        let resourceAcknowledgement = try modernServerSSEObject(
            await nextModernServerChunk(from: resourceResponse)
        )
        #expect(toolAcknowledgement["method"] == .string(SubscriptionsAcknowledgedNotification.name))
        #expect(resourceAcknowledgement["method"] == .string(SubscriptionsAcknowledgedNotification.name))

        try await server.notify(ToolListChangedNotification.message())
        try await server.notify(
            ResourceUpdatedNotification.message(.init(uri: "file:///a"))
        )
        let toolNotification = try modernServerSSEObject(
            await nextModernServerChunk(from: toolResponse)
        )
        let resourceNotification = try modernServerSSEObject(
            await nextModernServerChunk(from: resourceResponse)
        )
        #expect(toolNotification["method"] == .string(ToolListChangedNotification.name))
        #expect(resourceNotification["method"] == .string(ResourceUpdatedNotification.name))
        #expect(
            toolNotification["params"]?.objectValue?["_meta"]?.objectValue?[
                NotificationMetadata.subscriptionIDKey
            ] == .string("same")
        )

        let toolTerminalTask = Task { try await nextModernServerChunk(from: toolResponse) }
        let resourceTerminalTask = Task { try await nextModernServerChunk(from: resourceResponse) }
        await Task.yield()
        await server.stop()
        let toolTerminal = try modernServerSSEObject(try await toolTerminalTask.value)
        let resourceTerminal = try modernServerSSEObject(try await resourceTerminalTask.value)
        #expect(toolTerminal["result"]?.objectValue?["resultType"] == .string("complete"))
        #expect(resourceTerminal["result"]?.objectValue?["resultType"] == .string("complete"))
    }

    @Test(
        "Server stop does not wait for an unconsumed subscription acknowledgement",
        .timeLimit(.minutes(1))
    )
    func stopWithUnconsumedSubscriptionAcknowledgement() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "modern-server",
            version: "2.0",
            capabilities: .init(tools: .init(listChanged: true))
        )
        try await server.start(transport: transport)

        let response = await transport.handleRequest(
            try modernServerRequest(
                id: "unconsumed",
                method: SubscriptionsListenRequest.name,
                parameters: [
                    "notifications": try Value(
                        SubscriptionFilter(toolsListChanged: true)
                    )
                ]
            )
        )
        guard case .stream = response else {
            throw ModernServerTestError.unexpectedResponse
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await server.stop() }
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                throw ModernServerTestError.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    @Test(
        "Stdio modern cancellation has no metadata and cancels only modern work",
        .timeLimit(.minutes(1))
    )
    func stdioModernCancellationWithoutMetadata() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "modern-server",
            version: "2.0",
            capabilities: .init(tools: .init())
        )
        try await server.start(transport: transport)
        await server.withMethodHandler(CallTool.self) {
            _ async throws -> Server.ModernHandlerResult<CallTool.Result> in
            try await Task.sleep(for: .seconds(10))
            return .complete(.init())
        }

        let requestID = ID.string("modern-stdio")
        await transport.queue(
            data: try modernServerBody(
                id: "modern-stdio",
                method: CallTool.name,
                parameters: ["name": .string("echo"), "arguments": .object([:])]
            )
        )
        try await waitForModernStreamTask(server, id: requestID, present: true)

        try await transport.queue(
            notification: CancelledNotification.message(
                .init(requestId: requestID, reason: "stop")
            )
        )
        try await waitForModernStreamTask(server, id: requestID, present: false)
        await server.stop()
    }

    @Test(
        "Modern HTTP cancellation cannot cancel a legacy request with the same ID",
        .timeLimit(.minutes(1))
    )
    func modernHTTPCancellationDoesNotTouchLegacyTask() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(name: "modern-server", version: "2.0")
        let gate = ModernServerGate()
        let probe = ModernServerProbe()
        try await server.start(transport: transport)
        await server.withMethodHandler(Ping.self) { _ in
            await gate.wait()
            try Task.checkCancellation()
            return Empty()
        }
        await server.onNotification(ModernBarrierNotification.self) { _ in
            await probe.recordBarrier()
        }

        let legacyRequest = Request<Ping>(
            id: .string("same"),
            method: Ping.name,
            params: Empty()
        )
        let legacyTask = Task {
            await transport.handleRequest(
                HTTPRequest(
                    method: "POST",
                    headers: [
                        HTTPHeaderName.contentType: ContentType.json,
                        HTTPHeaderName.accept: ContentType.json,
                    ],
                    body: try JSONEncoder().encode(legacyRequest),
                    path: "/mcp"
                )
            )
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !(await gate.started) {
            guard clock.now < deadline else { throw ModernServerTestError.timedOut }
            await Task.yield()
        }

        let modernHeaders = [
            HTTPHeaderName.contentType: ContentType.json,
            HTTPHeaderName.accept: "application/json, text/event-stream",
            HTTPHeaderName.protocolVersion: Version.modern,
        ]
        let cancellation = CancelledNotification.message(
            .init(requestId: .string("same"), reason: "modern-only")
        )
        #expect(
            await transport.handleRequest(
                HTTPRequest(
                    method: "POST",
                    headers: modernHeaders,
                    body: try JSONEncoder().encode(cancellation),
                    path: "/mcp"
                )
            ).statusCode == 202
        )
        #expect(
            await transport.handleRequest(
                HTTPRequest(
                    method: "POST",
                    headers: modernHeaders,
                    body: try JSONEncoder().encode(
                        ModernBarrierNotification.message(.init(marker: true))
                    ),
                    path: "/mcp"
                )
            ).statusCode == 202
        )
        while await probe.barrierCount == 0 {
            guard clock.now < deadline else { throw ModernServerTestError.timedOut }
            await Task.yield()
        }

        await gate.release()
        let legacyResponse = try await legacyTask.value
        guard let body = legacyResponse.bodyData else {
            throw ModernServerTestError.missingBody
        }
        let decoded = try JSONDecoder().decode(Response<Ping>.self, from: body)
        guard case .success = decoded.result else {
            throw ModernServerTestError.unexpectedResponse
        }
        await server.stop()
    }

    @Test("Subscription bounds fail explicitly", .timeLimit(.minutes(1)))
    func subscriptionBoundIsTyped() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "modern-server",
            version: "2.0",
            capabilities: .init(tools: .init(listChanged: true)),
            configuration: .init(maxSubscriptions: 1)
        )
        try await server.start(transport: transport)

        let firstTask = Task {
            await transport.handleRequest(
                try modernServerRequest(
                    id: "one",
                    method: SubscriptionsListenRequest.name,
                    parameters: [
                        "notifications": try Value(
                            SubscriptionFilter(toolsListChanged: true)
                        )
                    ]
                )
            )
        }
        let first = try await firstTask.value
        _ = try await nextModernServerChunk(from: first)

        let second = await transport.handleRequest(
            try modernServerRequest(
                id: "two",
                method: SubscriptionsListenRequest.name,
                parameters: [
                    "notifications": try Value(
                        SubscriptionFilter(toolsListChanged: true)
                    )
                ]
            )
        )
        #expect(
            try modernServerError(second).code
                == MCPError.localLimitExceeded(resource: "", limit: 1).code
        )

        guard let firstKey = await server.modernSubscriptions.keys.first,
            case .exchange(let firstExchangeID) = firstKey
        else {
            throw ModernServerTestError.unexpectedResponse
        }
        await transport.cancel(exchangeID: firstExchangeID)
        try await waitForModernSubscriptionCleanup(server)

        let replacementTask = Task {
            await transport.handleRequest(
                try modernServerRequest(
                    id: "three",
                    method: SubscriptionsListenRequest.name,
                    parameters: [
                        "notifications": try Value(
                            SubscriptionFilter(toolsListChanged: true)
                        )
                    ]
                )
            )
        }
        let replacement = try await replacementTask.value
        let acknowledgement = try modernServerSSEObject(
            await nextModernServerChunk(from: replacement)
        )
        #expect(acknowledgement["method"] == .string(SubscriptionsAcknowledgedNotification.name))

        await transport.disconnect()
        await server.waitUntilCompleted()
        #expect(await server.modernSubscriptions.isEmpty)
        #expect(await server.modernRequestTasks.isEmpty)
        await server.stop()
    }

    @Test("Configuration decoding preserves legacy defaults and rejects invalid bounds")
    func configurationDecodingPreservesPositiveBounds() throws {
        let legacy = try JSONDecoder().decode(
            Server.Configuration.self,
            from: Data(#"{"strict":true}"#.utf8)
        )
        #expect(legacy.strict)
        #expect(legacy.maxSubscriptions == 1024)
        #expect(legacy.maxToolSchemaLookupPages == 64)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                Server.Configuration.self,
                from: Data(#"{"strict":false,"maxSubscriptions":0}"#.utf8)
            )
        }
    }
}
