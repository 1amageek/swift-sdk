import Foundation
import Testing

@testable import MCP

private enum ModernTransportTestError: Swift.Error {
    case timedOut
    case unexpectedResponse
}

private func makeModernBody(
    id: String? = "same",
    method: String = "tools/call",
    name: String = "echo",
    metadataVersion: String = Version.modern
) -> Data {
    var message: [String: Any] = [
        "jsonrpc": "2.0",
        "method": method,
        "params": [
            "name": name,
            "arguments": [:] as [String: Any],
            "_meta": [
                RequestMetadata.protocolVersionKey: metadataVersion,
                RequestMetadata.clientCapabilitiesKey: [:] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
    ]
    if let id {
        message["id"] = id
    }
    return try! JSONSerialization.data(withJSONObject: message)
}

private func makeModernResponseBody() -> Data {
    let body: [String: Any] = [
        "jsonrpc": "2.0",
        "id": "same",
        "result": ["resultType": "complete"] as [String: Any],
    ]
    return try! JSONSerialization.data(withJSONObject: body)
}

private func makeModernRequest(
    path: String,
    body: Data? = nil,
    headers overrides: [String: String] = [:]
) -> HTTPRequest {
    var headers: [String: String] = [
        HTTPHeaderName.contentType: "application/json",
        HTTPHeaderName.accept: "application/json, text/event-stream",
        HTTPHeaderName.protocolVersion: Version.modern,
        HTTPHeaderName.method: "tools/call",
        HTTPHeaderName.name: "echo",
    ]
    for (key, value) in overrides {
        headers = headers.filter { $0.key.lowercased() != key.lowercased() }
        headers[key] = value
    }
    return HTTPRequest(
        method: "POST",
        headers: headers,
        body: body ?? makeModernBody(),
        path: path
    )
}

private func makeModernRequestWithoutHeader(
    path: String = "/mcp",
    body: Data? = nil,
    removing header: String
) -> HTTPRequest {
    var request = makeModernRequest(path: path, body: body)
    request = HTTPRequest(
        method: request.method,
        headers: request.headers.filter { $0.key.lowercased() != header.lowercased() },
        body: request.body,
        path: request.path
    )
    return request
}

private func makeModernRequestWithoutHeaders(
    path: String = "/mcp",
    body: Data? = nil,
    removing headersToRemove: Set<String>
) -> HTTPRequest {
    let request = makeModernRequest(path: path, body: body)
    return HTTPRequest(
        method: request.method,
        headers: request.headers.filter {
            !headersToRemove.contains($0.key.lowercased())
        },
        body: request.body,
        path: request.path
    )
}

private func errorCode(_ response: HTTPResponse) -> Int? {
    guard let data = response.bodyData else { return nil }
    do {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let object = object as? [String: Any],
            let error = object["error"] as? [String: Any]
        else {
            return nil
        }
        return error["code"] as? Int
    } catch {
        return nil
    }
}

private func nextResponseChunk(
    from response: HTTPResponse,
    timeout: Duration = .seconds(1)
) async throws -> Data {
    guard case .stream(let stream, _) = response else {
        throw ModernTransportTestError.unexpectedResponse
    }

    return try await withThrowingTaskGroup(of: Data?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ModernTransportTestError.timedOut
        }
        defer { group.cancelAll() }
        guard let chunk = try await group.next() ?? nil else {
            throw ModernTransportTestError.unexpectedResponse
        }
        return chunk
    }
}

private actor SendCompletion {
    private(set) var didStart = false
    private(set) var didComplete = false

    func markStarted() {
        didStart = true
    }

    func markComplete() {
        didComplete = true
    }
}

@Suite("MCP 2026 Transport Tests")
struct MCP26TransportTests {
    @Test(
        "Concurrent modern POSTs with the same JSON-RPC ID remain exchange isolated",
        .timeLimit(.minutes(1))
    )
    func modernConcurrentPOSTsWithSameJSONRPCIDRemainExchangeIsolated() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let exchangeStream = await transport.receiveExchanges()
        var iterator = exchangeStream.makeAsyncIterator()

        let firstTask = Task {
            await transport.handleRequest(makeModernRequest(path: "/one"))
        }
        let secondTask = Task {
            await transport.handleRequest(makeModernRequest(path: "/two"))
        }

        for _ in 0..<2 {
            guard let envelope = try await iterator.next(),
                case .request(let exchangeID, _, _, let context, _) = envelope
            else {
                await transport.disconnect()
                firstTask.cancel()
                secondTask.cancel()
                throw ModernTransportTestError.unexpectedResponse
            }

            let path = context.path ?? ""
            let responseBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": "same",
                "result": ["path": path] as [String: Any],
            ])
            try await transport.send(
                .data(exchangeID: exchangeID, data: responseBody, terminal: false)
            )

            let response: HTTPResponse
            if path == "/one" {
                response = await firstTask.value
            } else {
                response = await secondTask.value
            }
            let firstChunk = try await nextResponseChunk(from: response)
            #expect(String(decoding: firstChunk, as: UTF8.self).contains(path))

            try await transport.send(
                .data(exchangeID: exchangeID, data: responseBody, terminal: true)
            )
            let finalChunk = try await nextResponseChunk(from: response)
            #expect(String(decoding: finalChunk, as: UTF8.self).contains(path))
        }

        await transport.disconnect()
    }

    @Test("Modern terminal errors map status without rewriting JSON-RPC bytes")
    func modernTerminalErrorPreservesIDAndData() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let exchangeStream = await transport.receiveExchanges()
        var iterator = exchangeStream.makeAsyncIterator()
        let requestTask = Task {
            await transport.handleRequest(makeModernRequest(path: "/error"))
        }
        guard let envelope = try await iterator.next(),
            case .request(let exchangeID, _, _, _, _) = envelope
        else {
            throw ModernTransportTestError.unexpectedResponse
        }

        let responseBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "same",
            "error": [
                "code": -32601,
                "message": "unknown method",
                "data": ["trace": "retained"],
            ] as [String: Any],
        ])
        try await transport.send(
            .data(exchangeID: exchangeID, data: responseBody, terminal: true)
        )

        let response = await requestTask.value
        #expect(response.statusCode == 404)
        #expect(response.bodyData == responseBody)
        #expect(errorCode(response) == -32601)
        await transport.disconnect()
    }

    @Test("Modern application errors remain HTTP 200 JSON-RPC responses")
    func modernApplicationErrorRemainsSuccessStatus() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let exchangeStream = await transport.receiveExchanges()
        var iterator = exchangeStream.makeAsyncIterator()
        let requestTask = Task {
            await transport.handleRequest(makeModernRequest(path: "/application-error"))
        }
        guard let envelope = try await iterator.next(),
            case .request(let exchangeID, _, _, _, _) = envelope
        else {
            throw ModernTransportTestError.unexpectedResponse
        }

        let responseBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "same",
            "error": [
                "code": -32603,
                "message": "handler failed",
                "data": ["trace": "retained"],
            ] as [String: Any],
        ])
        try await transport.send(
            .data(exchangeID: exchangeID, data: responseBody, terminal: true)
        )

        let response = await requestTask.value
        #expect(response.statusCode == 200)
        #expect(response.bodyData == responseBody)
        #expect(errorCode(response) == -32603)
        await transport.disconnect()
    }

    @Test("Modern standard headers and origin admission are typed and era-gated")
    func modernAdmissionRejectsInvalidStandardHeaders() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let missingVersion = await transport.handleRequest(
            makeModernRequestWithoutHeader(removing: HTTPHeaderName.protocolVersion)
        )
        #expect(missingVersion.statusCode == 400)
        #expect(errorCode(missingVersion) == -32020)

        let unsupportedVersion = await transport.handleRequest(
            makeModernRequest(
                path: "/unsupported",
                headers: [HTTPHeaderName.protocolVersion: "2027-01-01"]
            )
        )
        #expect(unsupportedVersion.statusCode == 400)
        #expect(errorCode(unsupportedVersion) == -32022)

        let responseBody = makeModernResponseBody()
        let response = await transport.handleRequest(
            makeModernRequest(path: "/response", body: responseBody)
        )
        #expect(response.statusCode == 400)
        #expect(errorCode(response) == -32600)

        await transport.disconnect()
    }

    @Test("Modern POST requires JSON and SSE in Accept")
    func modernAcceptRequiresBothResponseMediaTypes() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let response = await transport.handleRequest(
            makeModernRequest(
                path: "/accept",
                headers: [HTTPHeaderName.accept: ContentType.json]
            )
        )
        #expect(response.statusCode == 406)
        await transport.disconnect()
    }

    @Test("Modern headers are case-insensitive and values are normalized for the exchange")
    func modernStandardHeaderNormalizationAndNameEncoding() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let body = makeModernBody(name: "名前")
        let encodedName = Data("名前".utf8).base64EncodedString()
        let exchangeStream = await transport.receiveExchanges()
        var iterator = exchangeStream.makeAsyncIterator()
        let requestTask = Task {
            await transport.handleRequest(
                makeModernRequest(
                    path: "/headers",
                    body: body,
                    headers: [
                        "mcp-protocol-version": " \(Version.modern) ",
                        "mCP-METHOD": " tools/call ",
                        "mcp-name": " =?base64?\(encodedName)?= ",
                    ]
                )
            )
        }

        guard let envelope = try await iterator.next(),
            case .request(let exchangeID, _, let headers, let context, .modern) = envelope
        else {
            throw ModernTransportTestError.unexpectedResponse
        }
        #expect(headers[HTTPHeaderName.protocolVersion] == Version.modern)
        #expect(headers[HTTPHeaderName.method] == "tools/call")
        #expect(headers[HTTPHeaderName.name] == "=?base64?\(encodedName)?=")
        #expect(context.header(HTTPHeaderName.protocolVersion) == Version.modern)
        #expect(context.header(HTTPHeaderName.method) == "tools/call")

        try await transport.send(
            .data(
                exchangeID: exchangeID,
                data: makeModernResponseBody(),
                terminal: true
            )
        )
        let response = await requestTask.value
        #expect(response.statusCode == 200)
        await transport.disconnect()
    }

    @Test("Modern transport rejects unsafe standard header values")
    func modernStandardHeaderSyntaxRejectsUnsafeValues() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let cases: [(String, String)] = [
            (HTTPHeaderName.name, "名前"),
            (HTTPHeaderName.name, "control\nvalue"),
        ]
        for (index, entry) in cases.enumerated() {
            let response = await transport.handleRequest(
                makeModernRequest(
                    path: "/name-\(index)",
                    headers: [entry.0: entry.1]
                )
            )
            #expect(response.statusCode == 400)
            #expect(errorCode(response) == -32020)
        }
        await transport.disconnect()
    }

    @Test(
        "Modern transport forwards method, name, and metadata semantics to Server",
        .timeLimit(.minutes(1))
    )
    func modernSemanticValuesAreForwardedToServer() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let exchangeStream = await transport.receiveExchanges()
        var iterator = exchangeStream.makeAsyncIterator()
        let requestTask = Task {
            await transport.handleRequest(
                makeModernRequest(
                    path: "/server-validation",
                    body: makeModernBody(name: "body-name", metadataVersion: "2025-11-25"),
                    headers: [
                        HTTPHeaderName.method: "resources/read",
                        HTTPHeaderName.name: "header-name",
                    ]
                )
            )
        }

        guard let envelope = try await iterator.next(),
            case .request(let exchangeID, _, let headers, let context, .modern) = envelope
        else {
            throw ModernTransportTestError.unexpectedResponse
        }
        #expect(headers[HTTPHeaderName.method] == "resources/read")
        #expect(headers[HTTPHeaderName.name] == "header-name")
        #expect(context.header(HTTPHeaderName.method) == "resources/read")
        #expect(context.header(HTTPHeaderName.name) == "header-name")

        try await transport.send(
            .data(
                exchangeID: exchangeID,
                data: makeModernResponseBody(),
                terminal: true
            )
        )
        #expect((await requestTask.value).statusCode == 200)
        await transport.disconnect()
    }

    @Test("Modern admission rejects case-insensitive duplicate standard headers")
    func modernDuplicateStandardHeadersAreRejected() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let request = makeModernRequest(path: "/duplicate")
        var headers = request.headers
        headers["mcp-method"] = "tools/call"
        let duplicate = HTTPRequest(
            method: request.method,
            headers: headers,
            body: request.body,
            path: request.path
        )
        let response = await transport.handleRequest(duplicate)
        #expect(response.statusCode == 400)
        #expect(errorCode(response) == -32020)
        await transport.disconnect()
    }

    @Test(
        "Invalid modern method header syntax is not accepted through whitespace trimming",
        .timeLimit(.minutes(1))
    )
    func modernMethodRejectsUnsafeHeaderSyntax() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let response = await transport.handleRequest(
            makeModernRequest(
                path: "/method-syntax",
                headers: [HTTPHeaderName.method: "\ntools/call\n"]
            )
        )
        #expect(response.statusCode == 400)
        #expect(errorCode(response) == -32020)
        await transport.disconnect()
    }

    @Test("Configured HTTP validators run before modern admission")
    func modernConfiguredPipelineIsNotBypassed() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(
                validators: [
                    RejectingModernTransportValidator()
                ]
            )
        )
        try await transport.connect()

        let response = await transport.handleRequest(
            makeModernRequest(path: "/configured")
        )
        #expect(response.statusCode == 418)
        #expect(errorCode(response) == -32600)
        await transport.disconnect()
    }

    @Test(
        "Cancelling a modern SSE consumer cancels only its exchange",
        .timeLimit(.minutes(1))
    )
    func modernSSEConsumerCancellationCleansExchange() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let exchangeStream = await transport.receiveExchanges()
        var iterator = exchangeStream.makeAsyncIterator()
        let requestTask = Task {
            await transport.handleRequest(makeModernRequest(path: "/stream-cancel"))
        }
        guard let envelope = try await iterator.next(),
            case .request(let exchangeID, _, _, _, _) = envelope
        else {
            throw ModernTransportTestError.unexpectedResponse
        }

        let firstBody = makeModernResponseBody()
        try await transport.send(
            .data(exchangeID: exchangeID, data: firstBody, terminal: false)
        )
        let response = await requestTask.value
        guard case .stream(let stream, _) = response else {
            throw ModernTransportTestError.unexpectedResponse
        }

        var firstIterator = stream.makeAsyncIterator()
        guard try await firstIterator.next() != nil else {
            throw ModernTransportTestError.unexpectedResponse
        }

        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            do {
                let value = try await iterator.next()
                return value == nil
            } catch {
                return true
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        consumer.cancel()
        #expect(await consumer.value)

        guard let cancellation = try await iterator.next(),
            case .cancellation(let cancelledID) = cancellation
        else {
            throw ModernTransportTestError.unexpectedResponse
        }
        #expect(cancelledID == exchangeID)

        do {
            try await transport.send(
                .data(exchangeID: exchangeID, data: firstBody, terminal: true)
            )
            Issue.record("Expected a cancelled exchange to reject late responses")
        } catch let error as MCPError {
            #expect(error == .invalidRequest("Unknown or terminated HTTP exchange"))
        }
        await transport.disconnect()
    }

    @Test(
        "Modern SSE queues one terminal event without blocking shutdown",
        .timeLimit(.minutes(1))
    )
    func modernSSEQueuesTerminalWithoutBlocking() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let exchangeStream = await transport.receiveExchanges()
        var iterator = exchangeStream.makeAsyncIterator()
        let requestTask = Task {
            await transport.handleRequest(makeModernRequest(path: "/stream-overflow"))
        }
        guard let envelope = try await iterator.next(),
            case .request(let exchangeID, _, _, _, _) = envelope
        else {
            throw ModernTransportTestError.unexpectedResponse
        }

        let responseBody = makeModernResponseBody()
        try await transport.send(
            .data(exchangeID: exchangeID, data: responseBody, terminal: false)
        )
        let response = await requestTask.value
        guard case .stream(let stream, _) = response else {
            throw ModernTransportTestError.unexpectedResponse
        }

        var streamIterator = stream.makeAsyncIterator()
        let secondBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "same",
            "result": ["resultType": "complete", "sequence": 2] as [String: Any],
        ])
        let completion = SendCompletion()
        let secondSend = Task {
            await completion.markStarted()
            try await transport.send(
                .data(exchangeID: exchangeID, data: secondBody, terminal: true)
            )
            await completion.markComplete()
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(await completion.didStart)
        #expect(await completion.didComplete)

        guard let firstChunk = try await streamIterator.next() else {
            throw ModernTransportTestError.unexpectedResponse
        }
        #expect(String(decoding: firstChunk, as: UTF8.self).contains("\"id\":\"same\""))
        guard let secondChunk = try await streamIterator.next() else {
            throw ModernTransportTestError.unexpectedResponse
        }
        #expect(String(decoding: secondChunk, as: UTF8.self).contains("\"sequence\":2"))
        try await secondSend.value
        let streamEnd = try await streamIterator.next()
        #expect(streamEnd == nil)

        await transport.disconnect()
    }

    @Test(
        "Disconnect terminates each pending modern exchange exactly once",
        .timeLimit(.minutes(1))
    )
    func modernDisconnectCleansPendingExchange() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let exchangeStream = await transport.receiveExchanges()
        var iterator = exchangeStream.makeAsyncIterator()
        let requestTask = Task {
            await transport.handleRequest(makeModernRequest(path: "/disconnect"))
        }
        guard let envelope = try await iterator.next(),
            case .request(let exchangeID, _, _, _, _) = envelope
        else {
            throw ModernTransportTestError.unexpectedResponse
        }

        await transport.disconnect()
        let response = await requestTask.value
        #expect(response.statusCode == 500)

        guard let cancellation = try await iterator.next(),
            case .cancellation(let cancelledID) = cancellation
        else {
            throw ModernTransportTestError.unexpectedResponse
        }
        #expect(cancelledID == exchangeID)
        let end = try await iterator.next()
        #expect(end == nil)

        do {
            try await transport.send(
                .data(exchangeID: exchangeID, data: makeModernResponseBody(), terminal: true)
            )
            Issue.record("Expected a disconnected exchange to reject late responses")
        } catch let error as MCPError {
            #expect(error == .connectionClosed)
        }
    }

    @Test(
        "A wrong exchange response cannot terminate a valid modern exchange",
        .timeLimit(.minutes(1))
    )
    func modernWrongExchangeDoesNotStealWaiter() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let exchangeStream = await transport.receiveExchanges()
        var iterator = exchangeStream.makeAsyncIterator()
        let requestTask = Task {
            await transport.handleRequest(makeModernRequest(path: "/valid"))
        }
        guard let envelope = try await iterator.next(),
            case .request(let exchangeID, _, _, _, _) = envelope
        else {
            throw ModernTransportTestError.unexpectedResponse
        }

        do {
            try await transport.send(
                .data(
                    exchangeID: ExchangeID(),
                    data: makeModernResponseBody(),
                    terminal: true
                )
            )
            Issue.record("Expected an unknown exchange response to be rejected")
        } catch let error as MCPError {
            #expect(error == .invalidRequest("Unknown or terminated HTTP exchange"))
        }

        try await transport.send(
            .data(
                exchangeID: exchangeID,
                data: makeModernResponseBody(),
                terminal: true
            )
        )
        #expect((await requestTask.value).statusCode == 200)

        do {
            try await transport.send(
                .data(
                    exchangeID: exchangeID,
                    data: makeModernResponseBody(),
                    terminal: true
                )
            )
            Issue.record("Expected a terminal exchange to reject duplicate responses")
        } catch let error as MCPError {
            #expect(error == .invalidRequest("Unknown or terminated HTTP exchange"))
        }
        await transport.disconnect()
    }

    @Test("Modern notifications do not require request-only method/name headers")
    func modernNotificationAdmissionDoesNotRequireRequestHeaders() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let request = makeModernRequestWithoutHeaders(
            body: makeModernBody(id: nil, method: "notifications/initialized"),
            removing: [
                HTTPHeaderName.method.lowercased(),
                HTTPHeaderName.name.lowercased(),
            ]
        )
        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 202)
        await transport.disconnect()
    }

    @Test("Modern origin policy is supplied by the configured validation pipeline")
    func modernInvalidOriginReturnsForbidden() async throws {
        let transport = StatelessHTTPServerTransport()
        try await transport.connect()

        let response = await transport.handleRequest(
            makeModernRequest(
                path: "/origin",
                headers: [HTTPHeaderName.origin: "https://attacker.example"]
            )
        )
        #expect(response.statusCode == 403)
        await transport.disconnect()
    }

    @Test("Modern exchange cancellation is scoped and rejects late responses")
    func modernCancellationCleansExchangeExactlyOnce() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let exchangeStream = await transport.receiveExchanges()
        var iterator = exchangeStream.makeAsyncIterator()
        let requestTask = Task {
            await transport.handleRequest(makeModernRequest(path: "/cancel"))
        }
        guard let envelope = try await iterator.next(),
            case .request(let exchangeID, _, _, _, _) = envelope
        else {
            throw ModernTransportTestError.unexpectedResponse
        }

        await transport.cancel(exchangeID: exchangeID)
        let response = await requestTask.value
        #expect(response.statusCode == 500)
        guard let cancellation = try await iterator.next(),
            case .cancellation(let cancelledID) = cancellation
        else {
            throw ModernTransportTestError.unexpectedResponse
        }
        #expect(cancelledID == exchangeID)

        do {
            try await transport.send(
                .data(
                    exchangeID: exchangeID,
                    data: makeModernResponseBody(),
                    terminal: true
                )
            )
            Issue.record("Expected a late response to be rejected")
        } catch let error as MCPError {
            #expect(error == .invalidRequest("Unknown or terminated HTTP exchange"))
        }
        await transport.disconnect()
    }
}

private struct RejectingModernTransportValidator: HTTPRequestValidator {
    func validate(
        _ request: HTTPRequest,
        context: HTTPValidationContext
    ) -> HTTPResponse? {
        guard context.supportedProtocolVersions.contains(Version.modern) else {
            return .error(statusCode: 500, .internalError("Missing modern context"))
        }
        return .error(statusCode: 418, .invalidRequest("configured"))
    }
}
