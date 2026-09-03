import Foundation
import Logging

/// A stateless HTTP server transport for legacy JSON and modern per-POST SSE.
///
/// This transport implements a minimal subset of the MCP Streamable HTTP specification:
/// - No session management (no `Mcp-Session-Id` header)
/// - Legacy POST requests receive direct JSON responses
/// - Modern POST requests receive a request-scoped, non-resumable SSE stream
/// - GET and DELETE requests return 405 Method Not Allowed
///
/// ## Usage
///
/// ```swift
/// let transport = StatelessHTTPServerTransport()
///
/// // Start the MCP server with this transport
/// try await server.start(transport: transport)
///
/// // In your HTTP framework handler:
/// let response = await transport.handleRequest(httpRequest)
/// // Convert response to your framework's response type and return it
/// ```
///
/// ## When to Use
///
/// Use this transport when:
/// - You don't need server-initiated messages (no GET SSE stream)
/// - You want simple request-response semantics
/// - Session management is handled externally or not needed
///
/// For full streaming and session support, use ``StatefulHTTPServerTransport`` instead.
public actor StatelessHTTPServerTransport: Transport, HTTPContextProviding, ExchangeTransport {
    public nonisolated let logger: Logger

    // MARK: - Dependencies

    private let validationPipeline: any HTTPRequestValidationPipeline

    // MARK: - State

    private var terminated = false
    private var started = false

    private static let modernStreamHeaders: [String: String] = [
        HTTPHeaderName.contentType: ContentType.sse,
        HTTPHeaderName.cacheControl: "no-cache, no-transform",
        HTTPHeaderName.connection: "keep-alive",
    ]

    private static let modernStandardHeaderNames = [
        HTTPHeaderName.sessionID,
        HTTPHeaderName.protocolVersion,
        HTTPHeaderName.method,
        HTTPHeaderName.name,
        HTTPHeaderName.lastEventID,
        HTTPHeaderName.accept,
        HTTPHeaderName.contentType,
        HTTPHeaderName.authorization,
        HTTPHeaderName.origin,
        HTTPHeaderName.host,
    ]

    // MARK: - Incoming message stream (client → server)

    private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    // The raw stream remains available for existing Transport consumers. The
    // exchange stream is the package-internal path used by Server for modern
    // HTTP, where an HTTP POST is the delivery identity.
    private let exchangeStream: AsyncThrowingStream<ExchangeEnvelope, Swift.Error>
    private let exchangeContinuation: AsyncThrowingStream<ExchangeEnvelope, Swift.Error>.Continuation

    // MARK: - Response waiters

    /// Maps request ID → continuation waiting for the server's response.
    /// When the server calls `send()` with a response, the matching continuation is resumed.
    private var responseWaiters: [String: CheckedContinuation<Data, any Error>] = [:]

    /// Maps request ID → originating HTTP request, surfaced to handlers via
    /// ``Server/currentHTTPContext``. Entries live only while a JSON-RPC request
    /// is in flight.
    private var httpRequestContexts: [String: HTTPRequest] = [:]

    private struct WaitingModernProducer {
        let data: Data
        let terminal: Bool
        let continuation: CheckedContinuation<Void, any Error>?
    }

    private struct ModernStream {
        var bufferedData: Data?
        var bufferedTerminal = false
        var waitingConsumer: CheckedContinuation<Data?, any Error>?
        var waitingProducer: WaitingModernProducer?
        var failure: MCPError?
    }

    private enum ModernExchangeState {
        case pending(CheckedContinuation<HTTPResponse, Never>)
        case streaming(ModernStream)
    }

    private struct ModernExchange {
        var state: ModernExchangeState
    }

    /// Modern exchanges are keyed only by the transport-owned ExchangeID.
    private var modernExchanges: [ExchangeID: ModernExchange] = [:]

    // MARK: - Init

    /// Creates a new stateless HTTP server transport.
    ///
    /// - Parameters:
    ///   - validationPipeline: Custom validation pipeline. If `nil`, uses sensible defaults:
    ///     origin validation (localhost), Accept header (JSON only), Content-Type,
    ///     and protocol version validation.
    ///   - logger: Optional logger. If `nil`, a no-op logger is used.
    public init(
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        logger: Logger? = nil
    ) {
        self.validationPipeline = validationPipeline ?? StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
        self.logger = logger ?? Logger(
            label: "mcp.transport.http.server.stateless",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.incomingStream = stream
        self.incomingContinuation = continuation

        let (exchangeStream, exchangeContinuation) =
            AsyncThrowingStream<ExchangeEnvelope, Swift.Error>.makeStream()
        self.exchangeStream = exchangeStream
        self.exchangeContinuation = exchangeContinuation
    }

    // MARK: - Transport Conformance

    public func connect() async throws {
        guard !started else {
            throw MCPError.internalError("Transport already started")
        }
        started = true
        logger.debug("Stateless HTTP server transport started")
    }

    public func disconnect() async {
        await terminate()
    }

    /// Routes outgoing server messages to the appropriate waiting HTTP handler.
    ///
    /// - Responses are matched by JSON-RPC ID and delivered to the waiting `handleRequest` call.
    /// - Notifications and server-initiated requests are logged and dropped
    ///   (no streaming channel available in stateless mode).
    public func send(_ data: Data) async throws {
        guard !terminated else {
            throw MCPError.connectionClosed
        }

        guard let kind = JSONRPCMessageKind(data: data) else {
            logger.warning("Could not classify outgoing message for routing")
            return
        }

        switch kind {
        case .response(let id):
            guard let continuation = responseWaiters.removeValue(forKey: id) else {
                logger.debug(
                    "No waiter for response, may have timed out",
                    metadata: ["requestID": "\(id)"]
                )
                return
            }
            httpRequestContexts.removeValue(forKey: id)
            continuation.resume(returning: data)

        case .notification(let method):
            logger.debug(
                "Server-initiated notification dropped in stateless mode (no GET SSE stream)",
                metadata: ["method": "\(method)"]
            )

        case .request(_, let method):
            logger.debug(
                "Server-initiated request dropped in stateless mode (no GET SSE stream)",
                metadata: ["method": "\(method)"]
            )
        }
    }

    /// Routes one response event to the exchange that admitted it.
    package func send(_ event: ExchangeEvent) async throws {
        guard !terminated else {
            throw MCPError.connectionClosed
        }

        switch event {
        case .data(let exchangeID, let data, let terminal):
            guard var exchange = modernExchanges[exchangeID] else {
                throw MCPError.invalidRequest("Unknown or terminated HTTP exchange")
            }
            switch exchange.state {
            case .pending(let responseContinuation):
                if terminal {
                    modernExchanges.removeValue(forKey: exchangeID)
                    responseContinuation.resume(returning: terminalResponse(for: data))
                } else {
                    let stream = makeModernStream(exchangeID: exchangeID)
                    let streamData = SSEEvent.message(data: data).formatted()
                    exchange.state = .streaming(
                        ModernStream(bufferedData: streamData)
                    )
                    modernExchanges[exchangeID] = exchange
                    responseContinuation.resume(
                        returning: .stream(stream, headers: Self.modernStreamHeaders)
                    )
                }

            case .streaming(var stream):
                let streamData = SSEEvent.message(data: data).formatted()
                guard stream.failure == nil,
                    stream.bufferedTerminal == false
                else {
                    throw MCPError.invalidRequest("Unknown or terminated HTTP exchange")
                }

                if let consumer = stream.waitingConsumer {
                    stream.waitingConsumer = nil
                    if terminal {
                        modernExchanges.removeValue(forKey: exchangeID)
                    } else {
                        exchange.state = .streaming(stream)
                        modernExchanges[exchangeID] = exchange
                    }
                    consumer.resume(returning: streamData)
                    return
                }

                guard stream.bufferedData == nil else {
                    guard stream.waitingProducer == nil else {
                        throw MCPError.localLimitExceeded(
                            resource: "modern SSE producer waiters",
                            limit: 1
                        )
                    }
                    if terminal {
                        stream.waitingProducer = WaitingModernProducer(
                            data: streamData,
                            terminal: true,
                            continuation: nil
                        )
                        exchange.state = .streaming(stream)
                        modernExchanges[exchangeID] = exchange
                        return
                    }
                    return try await awaitModernProducer(
                        exchangeID: exchangeID,
                        data: streamData,
                        terminal: terminal
                    )
                }

                stream.bufferedData = streamData
                stream.bufferedTerminal = terminal
                exchange.state = .streaming(stream)
                modernExchanges[exchangeID] = exchange
            }

        case .failure(let exchangeID, let error):
            guard var exchange = modernExchanges[exchangeID] else {
                throw MCPError.invalidRequest("Unknown or terminated HTTP exchange")
            }
            switch exchange.state {
            case .pending(let responseContinuation):
                modernExchanges.removeValue(forKey: exchangeID)
                responseContinuation.resume(returning: terminalResponse(for: error))
            case .streaming(var stream):
                guard stream.failure == nil, !stream.bufferedTerminal else {
                    throw MCPError.invalidRequest("Unknown or terminated HTTP exchange")
                }
                stream.failure = error
                stream.bufferedTerminal = false
                if let producer = stream.waitingProducer {
                    stream.waitingProducer = nil
                    producer.continuation?.resume(throwing: error)
                }
                if let consumer = stream.waitingConsumer {
                    stream.waitingConsumer = nil
                    modernExchanges.removeValue(forKey: exchangeID)
                    consumer.resume(throwing: error)
                } else {
                    exchange.state = .streaming(stream)
                    modernExchanges[exchangeID] = exchange
                }
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        incomingStream
    }

    package func receiveExchanges() -> AsyncThrowingStream<ExchangeEnvelope, Swift.Error> {
        exchangeStream
    }

    /// Cancels one modern exchange and notifies the Server-side exchange loop.
    package func cancel(exchangeID: ExchangeID) async {
        guard let exchange = modernExchanges.removeValue(forKey: exchangeID) else { return }
        switch exchange.state {
        case .pending(let responseContinuation):
            responseContinuation.resume(
                returning: .error(statusCode: 500, .connectionClosed)
            )
        case .streaming(let stream):
            stream.waitingConsumer?.resume(throwing: MCPError.connectionClosed)
            stream.waitingProducer?.continuation?.resume(throwing: MCPError.connectionClosed)
        }
        exchangeContinuation.yield(.cancellation(exchangeID: exchangeID))
    }

    private func awaitModernProducer(
        exchangeID: ExchangeID,
        data: Data,
        terminal: Bool
    ) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: MCPError.connectionClosed)
                    return
                }
                guard var exchange = modernExchanges[exchangeID],
                    case .streaming(var stream) = exchange.state,
                    stream.failure == nil,
                    !stream.bufferedTerminal,
                    stream.bufferedData != nil,
                    stream.waitingProducer == nil
                else {
                    continuation.resume(
                        throwing: MCPError.invalidRequest(
                            "Unknown or terminated HTTP exchange"
                        )
                    )
                    return
                }
                stream.waitingProducer = WaitingModernProducer(
                    data: data,
                    terminal: terminal,
                    continuation: continuation
                )
                exchange.state = .streaming(stream)
                modernExchanges[exchangeID] = exchange
            }
        }, onCancel: {
            Task { await self.cancel(exchangeID: exchangeID) }
        })
    }

    private func makeModernStream(exchangeID: ExchangeID) -> AsyncThrowingStream<Data, Swift.Error> {
        let transport = self
        return AsyncThrowingStream<Data, Swift.Error>(unfolding: { [weak transport] in
            guard let transport else {
                throw MCPError.connectionClosed
            }
            return try await transport.nextModernEvent(exchangeID: exchangeID)
        })
    }

    private func nextModernEvent(exchangeID: ExchangeID) async throws -> Data? {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: MCPError.connectionClosed)
                    return
                }
                guard var exchange = modernExchanges[exchangeID],
                    case .streaming(var stream) = exchange.state
                else {
                    continuation.resume(returning: nil)
                    return
                }

                if let data = stream.bufferedData {
                    let isTerminal = stream.bufferedTerminal
                    stream.bufferedData = nil
                    stream.bufferedTerminal = false

                    if isTerminal {
                        modernExchanges.removeValue(forKey: exchangeID)
                        continuation.resume(returning: data)
                        return
                    }

                    if let producer = stream.waitingProducer {
                        stream.waitingProducer = nil
                        stream.bufferedData = producer.data
                        stream.bufferedTerminal = producer.terminal
                        producer.continuation?.resume()
                    }
                    exchange.state = .streaming(stream)
                    modernExchanges[exchangeID] = exchange
                    continuation.resume(returning: data)
                    return
                }

                if let failure = stream.failure {
                    modernExchanges.removeValue(forKey: exchangeID)
                    continuation.resume(throwing: failure)
                    return
                }

                guard stream.waitingConsumer == nil else {
                    continuation.resume(
                        throwing: MCPError.invalidRequest(
                            "Concurrent reads on one modern SSE exchange"
                        )
                    )
                    return
                }
                stream.waitingConsumer = continuation
                exchange.state = .streaming(stream)
                modernExchanges[exchangeID] = exchange
            }
        }, onCancel: {
            Task { await self.cancel(exchangeID: exchangeID) }
        })
    }

    // MARK: - HTTP Request Handler

    /// Handles an incoming HTTP request from the framework adapter.
    ///
    /// Only POST is supported:
    /// - **POST**: JSON-RPC messages (requests, notifications)
    /// - **GET**: 405 Method Not Allowed
    /// - **DELETE**: 405 Method Not Allowed
    /// - Others: 405 Method Not Allowed
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if terminated {
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found: Transport has been terminated")
            )
        }

        switch request.method.uppercased() {
        case "POST":
            return await handlePost(request)
        default:
            return .error(
                statusCode: 405,
                .invalidRequest("Method Not Allowed"),
                extraHeaders: [HTTPHeaderName.allow: "POST"]
            )
        }
    }

    // MARK: - POST Handler

    private func handlePost(_ request: HTTPRequest) async -> HTTPResponse {
        // Parse body first to determine message type
        guard let body = request.body, !body.isEmpty else {
            return .error(
                statusCode: 400,
                .parseError("Empty request body")
            )
        }

        guard let messageKind = JSONRPCMessageKind(data: body) else {
            return .error(
                statusCode: 400,
                .parseError("Invalid JSON-RPC message")
            )
        }

        let bodyFields = decodedJSONObject(from: body)
        if isModernCandidate(request, bodyFields: bodyFields) {
            return await handleModernPost(
                request,
                body: body,
                bodyFields: bodyFields,
                messageKind: messageKind
            )
        }

        // Build validation context
        let context = HTTPValidationContext(
            httpMethod: "POST",
            sessionID: nil,
            isInitializationRequest: messageKind.isInitializeRequest,
            supportedProtocolVersions: Version.supported
        )

        // Run validation pipeline
        if let errorResponse = validationPipeline.validate(request, context: context) {
            return errorResponse
        }

        // Handle by message type
        switch messageKind {
        case .notification, .response:
            // Yield to server and return 202 Accepted
            incomingContinuation.yield(body)
            return .accepted()

        case .request(let id, _):
            return await handleJSONRPCRequest(body, requestID: id, request: request)
        }
    }

    /// Determines whether the request explicitly selects the modern HTTP era.
    /// A modern marker is required so legacy requests that happen to carry an
    /// older protocol version continue through the existing stateful-compatible
    /// path.
    private func isModernCandidate(
        _ request: HTTPRequest,
        bodyFields: [String: Value]?
    ) -> Bool {
        let hasModernHeader = request.headers.keys.contains { key in
            let lowercased = key.lowercased()
            return lowercased == HTTPHeaderName.method.lowercased()
                || lowercased == HTTPHeaderName.name.lowercased()
                || lowercased.hasPrefix(HTTPHeaderName.parameterPrefix.lowercased())
        }
        let hasMetadataVersion = bodyFields.flatMap { fields in
            guard let params = fields["params"]?.objectValue,
                let metadata = params["_meta"]?.objectValue
            else { return false }
            return metadata[RequestMetadata.protocolVersionKey] != nil
        } ?? false
        let explicitModernVersion = trimmedHeader(request, HTTPHeaderName.protocolVersion).map {
            $0 == Version.modern || !Version.supported.contains($0)
        } ?? false
        return explicitModernVersion || hasModernHeader || hasMetadataVersion
    }

    /// Admits one modern POST and creates its exchange-scoped response stream.
    /// This method owns only HTTP syntax, standard headers, and delivery
    /// identity. Method and tool-schema semantics remain in Server.
    private func handleModernPost(
        _ request: HTTPRequest,
        body: Data,
        bodyFields: [String: Value]?,
        messageKind: JSONRPCMessageKind
    ) async -> HTTPResponse {
        if let errorResponse = validateModernAdmission(
            request,
            bodyFields: bodyFields,
            messageKind: messageKind
        ) {
            return errorResponse
        }

        let exchangeID = ExchangeID()
        let normalizedRequest = normalizedRequest(request)
        let envelope = ExchangeEnvelope.request(
            exchangeID: exchangeID,
            body: body,
            headers: normalizedRequest.headers,
            context: normalizedRequest,
            era: .modern
        )

        switch messageKind {
        case .notification:
            // Deliver notifications without retaining an exchange waiter;
            // Server applies any request-method/header semantics.
            exchangeContinuation.yield(envelope)
            return .accepted()

        case .request:
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    modernExchanges[exchangeID] = ModernExchange(
                        state: .pending(continuation)
                    )
                    exchangeContinuation.yield(envelope)
                }
            }, onCancel: {
                Task { await self.cancel(exchangeID: exchangeID) }
            })

        case .response:
            // Admission rejects responses before reaching this branch.
            return .error(
                statusCode: 400,
                .invalidRequest("Modern HTTP POST body must be a request or notification")
            )
        }
    }

    /// Validates the standard modern HTTP admission contract before delivery.
    private func validateModernAdmission(
        _ request: HTTPRequest,
        bodyFields: [String: Value]?,
        messageKind: JSONRPCMessageKind
    ) -> HTTPResponse? {
        let context = HTTPValidationContext(
            httpMethod: "POST",
            sessionID: nil,
            isInitializationRequest: messageKind.isInitializeRequest,
            supportedProtocolVersions: Version.allSupported
        )

        // Existing validators own configured Origin, authentication, and
        // other deployment policy. Modern-specific syntax is checked only
        // after that configured pipeline has accepted the request.
        if let configuredError = validationPipeline.validate(request, context: context) {
            return configuredError
        }

        if let duplicateHeader = Self.modernStandardHeaderNames.first(where: {
            hasDuplicateHeader(request, named: $0)
        }) {
            return .error(
                statusCode: 400,
                .headerMismatch("Duplicate \(duplicateHeader) header")
            )
        }

        if let acceptError = AcceptHeaderValidator(mode: .sseRequired)
            .validate(request, context: context)
        {
            return acceptError
        }

        if let contentTypeError = ContentTypeValidator().validate(request, context: context) {
            return contentTypeError
        }

        guard let rawVersion = request.header(HTTPHeaderName.protocolVersion) else {
            return .error(
                statusCode: 400,
                .headerMismatch("Missing \(HTTPHeaderName.protocolVersion) header")
            )
        }
        let version = trimHTTPWhitespace(rawVersion)
        guard !version.isEmpty else {
            return .error(
                statusCode: 400,
                .headerMismatch("Empty \(HTTPHeaderName.protocolVersion) header")
            )
        }
        if let metadataVersion = bodyFields?["params"]?.objectValue?["_meta"]?
            .objectValue?[RequestMetadata.protocolVersionKey]?.stringValue,
            metadataVersion != version
        {
            return modernAdmissionError(
                .headerMismatch("\(HTTPHeaderName.protocolVersion) does not match _meta"),
                bodyFields: bodyFields
            )
        }
        guard Version.allSupported.contains(version) else {
            return modernAdmissionError(
                .unsupportedProtocolVersion(
                    requested: version,
                    supported: [Version.modern]
                ),
                bodyFields: bodyFields
            )
        }
        guard version == Version.modern else {
            return modernAdmissionError(
                .unsupportedProtocolVersion(
                    requested: version,
                    supported: [Version.modern]
                ),
                bodyFields: bodyFields
            )
        }

        if let requestID = bodyFields?["id"] {
            switch requestID {
            case .string, .int:
                break
            default:
                return .error(
                    statusCode: 400,
                    .invalidRequest("Modern HTTP request id must be a string or integer")
                )
            }
        }

        switch messageKind {
        case .request, .notification:
            break
        case .response:
            return .error(
                statusCode: 400,
                .invalidRequest("Modern HTTP POST body must be a request or notification")
            )
        }

        guard let fields = bodyFields,
            fields["jsonrpc"]?.stringValue == "2.0",
            fields["method"]?.stringValue != nil
        else {
            return .error(
                statusCode: 400,
                .invalidRequest("Modern HTTP POST body must be a JSON-RPC request")
            )
        }

        // The Server owns method/header meaning and body comparisons. The
        // transport only rejects unsafe values at the HTTP boundary and
        // forwards normalized values for request-scoped semantic validation.
        if let rawMethod = trimmedHeader(request, HTTPHeaderName.method),
            !isValidMethodHeaderValue(rawMethod)
        {
            return .error(
                statusCode: 400,
                .headerMismatch("Invalid \(HTTPHeaderName.method) header")
            )
        }
        if let rawName = trimmedHeader(request, HTTPHeaderName.name),
            !isValidHeaderFieldValue(rawName)
        {
            return .error(
                statusCode: 400,
                .headerMismatch("Invalid \(HTTPHeaderName.name) header")
            )
        }
        for (name, rawValue) in request.headers
        where name.lowercased().hasPrefix(HTTPHeaderName.parameterPrefix.lowercased()) {
            let suffix = name.dropFirst(HTTPHeaderName.parameterPrefix.count)
            guard !suffix.isEmpty, suffix.utf8.allSatisfy(isTChar),
                isValidHeaderFieldValue(trimHTTPWhitespace(rawValue))
            else {
                return .error(
                    statusCode: 400,
                    .headerMismatch("Invalid custom MCP header")
                )
            }
        }

        return nil
    }

    private func modernAdmissionError(
        _ error: MCPError,
        bodyFields: [String: Value]?
    ) -> HTTPResponse {
        let requestID: ID?
        switch bodyFields?["id"] {
        case .string(let value):
            requestID = .string(value)
        case .int(let value):
            requestID = .number(value)
        default:
            requestID = nil
        }
        guard let requestID else {
            return .error(statusCode: 400, error)
        }
        do {
            let data = try JSONEncoder().encode(
                AnyMethod.response(id: requestID, error: error)
            )
            return .dataWithStatus(
                statusCode: 400,
                data: data,
                headers: [HTTPHeaderName.contentType: ContentType.json]
            )
        } catch {
            return .error(
                statusCode: 500,
                .internalError("Failed to encode admission error")
            )
        }
    }

    private func decodedJSONObject(from body: Data) -> [String: Value]? {
        do {
            let value = try JSONDecoder().decode(Value.self, from: body)
            return value.objectValue
        } catch {
            return nil
        }
    }

    private func trimmedHeader(_ request: HTTPRequest, _ name: String) -> String? {
        request.header(name).map(trimHTTPWhitespace)
    }

    private func hasDuplicateHeader(_ request: HTTPRequest, named name: String) -> Bool {
        request.headers.keys.reduce(into: 0) { count, key in
            if key.caseInsensitiveCompare(name) == .orderedSame {
                count += 1
            }
        } > 1
    }

    private func trimHTTPWhitespace(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    private func isValidMethodHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    private func isValidHeaderFieldValue(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy { byte in
                (0x20...0x7E).contains(byte) || byte == 0x09
            }
    }

    private func isTChar(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x30...0x39,
            0x41...0x5A, 0x5E, 0x5F, 0x60, 0x61...0x7A, 0x7C, 0x7E:
            return true
        default:
            return false
        }
    }

    private func normalizedRequest(_ request: HTTPRequest) -> HTTPRequest {
        let standardNames = [
            HTTPHeaderName.sessionID,
            HTTPHeaderName.protocolVersion,
            HTTPHeaderName.method,
            HTTPHeaderName.name,
            HTTPHeaderName.lastEventID,
            HTTPHeaderName.accept,
            HTTPHeaderName.contentType,
            HTTPHeaderName.authorization,
            HTTPHeaderName.origin,
            HTTPHeaderName.host,
        ]
        var headers = request.headers
        for canonicalName in standardNames {
            let matchingKeys = headers.keys.filter {
                $0.lowercased() == canonicalName.lowercased()
            }
            let value = request.header(canonicalName)
            for key in matchingKeys {
                headers.removeValue(forKey: key)
            }
            if let value {
                headers[canonicalName] = trimHTTPWhitespace(value)
            }
        }
        for key in Array(headers.keys)
        where key.lowercased().hasPrefix(HTTPHeaderName.parameterPrefix.lowercased()) {
            headers[key] = headers[key].map(trimHTTPWhitespace)
        }
        return HTTPRequest(
            method: request.method,
            headers: headers,
            body: request.body,
            path: request.path
        )
    }

    /// Keeps a terminal JSON-RPC error's typed code while selecting the
    /// modern HTTP status mapping owned by this transport.
    private func terminalResponse(for data: Data) -> HTTPResponse {
        guard let fields = decodedJSONObject(from: data),
            let errorFields = fields["error"]?.objectValue,
            let code = errorFields["code"]?.intValue
        else {
            return .data(data, headers: [HTTPHeaderName.contentType: ContentType.json])
        }
        return .dataWithStatus(
            statusCode: statusCode(forJSONRPCErrorCode: code),
            data: data,
            headers: [HTTPHeaderName.contentType: ContentType.json]
        )
    }

    private func terminalResponse(for error: MCPError) -> HTTPResponse {
        let mappedStatusCode: Int
        switch error {
        case .connectionClosed, .transportError:
            mappedStatusCode = 500
        default:
            mappedStatusCode = statusCode(forJSONRPCErrorCode: error.code)
        }
        return .error(statusCode: mappedStatusCode, error)
    }

    private func statusCode(forJSONRPCErrorCode code: Int) -> Int {
        switch code {
        case -32700, -32600, -32602, -32020, -32021, -32022:
            return 400
        case -32601:
            return 404
        default:
            return 200
        }
    }

    private func handleJSONRPCRequest(
        _ body: Data,
        requestID: String,
        request: HTTPRequest
    ) async -> HTTPResponse {
        httpRequestContexts[requestID] = request
        // Wait for the server to process and send a response
        let responseData: Data
        do {
            responseData = try await withCheckedThrowingContinuation { continuation in
                responseWaiters[requestID] = continuation
                // Register the waiter before yielding so a synchronous server
                // response cannot race the response map.
                incomingContinuation.yield(body)
            }
        } catch {
            httpRequestContexts.removeValue(forKey: requestID)
            return .error(
                statusCode: 500,
                .internalError("Error processing request: \(error.localizedDescription)")
            )
        }

        httpRequestContexts.removeValue(forKey: requestID)
        return .data(responseData, headers: [HTTPHeaderName.contentType: ContentType.json])
    }

    // MARK: - HTTPContextProviding

    public func httpRequestContext(for id: ID) -> HTTPRequest? {
        httpRequestContexts[id.description]
    }

    // MARK: - Termination

    private func terminate() async {
        guard !terminated else { return }
        terminated = true

        logger.debug("Stateless HTTP server transport terminated")

        // Cancel all waiting continuations
        for (id, continuation) in responseWaiters {
            continuation.resume(throwing: MCPError.connectionClosed)
            logger.debug("Cancelled waiter for request", metadata: ["requestID": "\(id)"])
        }
        responseWaiters.removeAll()
        httpRequestContexts.removeAll()

        // Close every modern response stream and publish one cancellation per
        // admitted exchange before closing the exchange delivery stream.
        for (exchangeID, exchange) in modernExchanges {
            switch exchange.state {
            case .pending(let responseContinuation):
                responseContinuation.resume(
                    returning: .error(statusCode: 500, .connectionClosed)
                )
            case .streaming(let stream):
                stream.waitingConsumer?.resume(throwing: MCPError.connectionClosed)
                stream.waitingProducer?.continuation?.resume(throwing: MCPError.connectionClosed)
            }
            exchangeContinuation.yield(.cancellation(exchangeID: exchangeID))
        }
        modernExchanges.removeAll()
        exchangeContinuation.finish()

        // Close incoming stream
        incomingContinuation.finish()
    }
}
