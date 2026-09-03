import Foundation

/// The modern result a server handler may return.
///
/// The generic complete value is deliberately constrained only by `Sendable`
/// at the public boundary. The three concrete registration overloads below
/// perform the Codable conversion required by the MCP wire format.
public extension Server {
    enum ModernHandlerResult<Complete: Sendable>: Sendable {
        case complete(Complete)
        case inputRequired(InputRequiredResult)
    }
}

enum ModernResultPayload: Sendable {
    case complete(value: Value, metadata: ResultMetadata?, cacheHint: CacheHint?)
    case inputRequired(InputRequiredResult)
}

struct ModernRequestHandlerBox: Sendable {
    private let invoke: @Sendable
        (AnyRequest) async throws -> ModernResultPayload

    init(
        _ invoke: @escaping @Sendable
            (AnyRequest) async throws -> ModernResultPayload
    ) {
        self.invoke = invoke
    }

    func callAsFunction(
        _ request: AnyRequest
    ) async throws -> ModernResultPayload {
        try await invoke(request)
    }
}

enum ModernSubscriptionKey: Hashable {
    case exchange(ExchangeID)
    case stream(ID)
}

struct ModernSubscription {
    let id: ID
    let exchangeID: ExchangeID?
    let filter: SubscriptionFilter
    var continuation: CheckedContinuation<Void, Never>?
}

extension Server {
    // MARK: - Modern registration

    /// Registers a modern-aware tool handler while keeping its result slot
    /// separate from the legacy `CallTool` handler slot.
    @discardableResult
    public func withMethodHandler(
        _ type: CallTool.Type,
        handler: @escaping @Sendable
            (CallTool.Parameters) async throws
            -> ModernHandlerResult<CallTool.Result>
    ) -> Self {
        modernMethodHandlers[CallTool.name] = ModernRequestHandlerBox { request in
            let typedRequest = try Self.decode(request, as: CallTool.self)
            let result = try await handler(typedRequest.params)
            return try Self.erase(result)
        }
        return self
    }

    /// Registers a modern-aware prompt handler while keeping its result slot
    /// separate from the legacy `GetPrompt` handler slot.
    @discardableResult
    public func withMethodHandler(
        _ type: GetPrompt.Type,
        handler: @escaping @Sendable
            (GetPrompt.Parameters) async throws
            -> ModernHandlerResult<GetPrompt.Result>
    ) -> Self {
        modernMethodHandlers[GetPrompt.name] = ModernRequestHandlerBox { request in
            let typedRequest = try Self.decode(request, as: GetPrompt.self)
            let result = try await handler(typedRequest.params)
            return try Self.erase(result)
        }
        return self
    }

    /// Registers a modern-aware resource handler while keeping its result slot
    /// separate from the legacy `ReadResource` handler slot.
    @discardableResult
    public func withMethodHandler(
        _ type: ReadResource.Type,
        handler: @escaping @Sendable
            (ReadResource.Parameters) async throws
            -> ModernHandlerResult<ReadResource.Result>
    ) -> Self {
        modernMethodHandlers[ReadResource.name] = ModernRequestHandlerBox { request in
            let typedRequest = try Self.decode(request, as: ReadResource.self)
            let result = try await handler(typedRequest.params)
            return try Self.erase(result)
        }
        return self
    }

    private static func decode<M: Method>(
        _ request: AnyRequest,
        as type: M.Type
    ) throws -> Request<M> {
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(Request<M>.self, from: data)
    }

    private static func erase<Complete: Codable & Sendable>(
        _ result: ModernHandlerResult<Complete>
    ) throws -> ModernResultPayload {
        switch result {
        case .complete(let value):
            return .complete(
                value: try Value(value),
                metadata: nil,
                cacheHint: nil
            )
        case .inputRequired(let value):
            return .inputRequired(value)
        }
    }

    // MARK: - Modern message loops

    func runMessageLoops(transport: any Transport) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                await self.runLegacyMessageLoop(transport: transport)
            }

            if let exchangeTransport = transport as? any ExchangeTransport {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.runExchangeMessageLoop(transport: exchangeTransport)
                }
            }

            await group.waitForAll()
        }
        await finishModernSubscriptions()
        cancelModernRequests()
        await logger?.debug("Server finished", metadata: [:])
    }

    private func runLegacyMessageLoop(transport: any Transport) async {
        do {
            let stream = await transport.receive()
            for try await data in stream {
                if Task.isCancelled { break }

                var requestID: ID?
                do {
                    let decoder = JSONDecoder()
                    if let batch = try? decoder.decode(Server.Batch.self, from: data) {
                        try await handleBatch(batch)
                    } else if let response = try? decoder.decode(AnyResponse.self, from: data) {
                        await handleResponse(response)
                    } else if let request = try? decoder.decode(AnyRequest.self, from: data) {
                        if isModernRequest(request) {
                            enqueueModernRequest(request, exchangeID: nil, httpContext: nil)
                        } else {
                            Task {
                                _ = try? await self.handleRequest(request, sendResponse: true)
                            }
                        }
                    } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                        if isModernNotification(message) {
                            await processModernNotification(
                                message,
                                exchangeID: nil,
                                httpContext: nil
                            )
                        } else {
                            try await handleMessage(message)
                        }
                    } else {
                        if let json = try? JSONDecoder().decode(
                            [String: Value].self, from: data),
                            let idValue = json["id"]
                        {
                            if let strValue = idValue.stringValue {
                                requestID = .string(strValue)
                            } else if let intValue = idValue.intValue {
                                requestID = .number(intValue)
                            }
                        }
                        throw MCPError.parseError("Invalid message format")
                    }
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                } catch {
                    await logger?.error(
                        "Error processing message", metadata: ["error": "\(error)"])
                    let response = AnyMethod.response(
                        id: requestID ?? .random,
                        error: error as? MCPError
                            ?? MCPError.internalError(error.localizedDescription)
                    )
                    try? await send(response)
                }
            }
        } catch {
            await logger?.error(
                "Fatal error in message handling loop", metadata: ["error": "\(error)"])
        }
    }

    private func runExchangeMessageLoop(transport: any ExchangeTransport) async {
        do {
            let stream = await transport.receiveExchanges()
            for try await envelope in stream {
                if Task.isCancelled { break }
                switch envelope {
                case .request(let exchangeID, let body, _, let httpContext, let era):
                    guard era == .modern else { continue }
                    let decoder = JSONDecoder()
                    if let request = try? decoder.decode(AnyRequest.self, from: body) {
                        enqueueModernRequest(
                            request,
                            exchangeID: exchangeID,
                            httpContext: httpContext
                        )
                    } else if let message = try? decoder.decode(AnyMessage.self, from: body) {
                        await processModernNotification(
                            message,
                            exchangeID: exchangeID,
                            httpContext: httpContext
                        )
                    } else {
                        let error = MCPError.invalidRequest("Invalid modern JSON-RPC request")
                        do {
                            try await transport.send(
                                .failure(exchangeID: exchangeID, error: error)
                            )
                        } catch {
                            await logger?.debug(
                                "Invalid modern request could not be delivered",
                                metadata: ["exchangeID": "\(exchangeID)", "error": "\(error)"]
                            )
                        }
                    }

                case .cancellation(let exchangeID):
                    cancelModernSubscription(for: .exchange(exchangeID))
                    if let requestTask = modernRequestTasks.removeValue(forKey: exchangeID) {
                        requestTask.cancel()
                    }
                }
            }
        } catch {
            await logger?.error(
                "Fatal error in modern exchange loop", metadata: ["error": "\(error)"])
        }
    }

    private func enqueueModernRequest(
        _ request: AnyRequest,
        exchangeID: ExchangeID?,
        httpContext: HTTPRequest?
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.processModernRequest(
                request,
                exchangeID: exchangeID,
                httpContext: httpContext
            )
        }
        if let exchangeID {
            modernRequestTasks[exchangeID] = task
        } else {
            modernStreamRequestTasks[request.id] = task
        }
    }

    private func isModernRequest(_ request: AnyRequest) -> Bool {
        guard let fields = request.params.objectValue,
            let metadata = fields["_meta"]?.objectValue,
            let version = metadata[RequestMetadata.protocolVersionKey]?.stringValue
        else {
            return false
        }
        return version == Version.modern
    }

    private func isModernNotification(_ message: AnyMessage) -> Bool {
        guard let fields = message.params.objectValue else { return false }
        if let metadata = fields["_meta"]?.objectValue,
            let version = metadata[RequestMetadata.protocolVersionKey]?.stringValue
        {
            return version == Version.modern
        }
        guard message.method == CancelledNotification.name,
            let requestID = cancellationRequestID(from: fields)
        else { return false }
        return modernStreamRequestTasks[requestID] != nil
            || modernSubscriptions[.stream(requestID)] != nil
    }

    private func cancellationRequestID(from fields: [String: Value]) -> ID? {
        guard let value = fields["requestId"] else { return nil }
        if let string = value.stringValue {
            return .string(string)
        }
        if let number = value.intValue {
            return .number(number)
        }
        return nil
    }

    // MARK: - Modern dispatch

    private func processModernNotification(
        _ message: AnyMessage,
        exchangeID: ExchangeID?,
        httpContext: HTTPRequest?
    ) async {
        let context: HandlerContext
        do {
            context = try makeHandlerContext(
                id: .random,
                params: try Value(message.params),
                exchangeID: exchangeID,
                httpContext: httpContext,
                requireMetadata: false
            )
        } catch {
            await logger?.warning(
                "Rejected modern notification",
                metadata: ["error": "\(error)"]
            )
            return
        }

        await Server.$currentHandlerContext.withValue(context) {
            do {
                try await handleModernNotification(message)
            } catch {
                await logger?.warning(
                    "Error handling modern notification",
                    metadata: ["method": "\(message.method)", "error": "\(error)"]
                )
            }
        }
    }

    private func processModernRequest(
        _ request: AnyRequest,
        exchangeID: ExchangeID?,
        httpContext: HTTPRequest?
    ) async {
        defer {
            if let exchangeID {
                modernRequestTasks.removeValue(forKey: exchangeID)
            } else {
                modernStreamRequestTasks.removeValue(forKey: request.id)
            }
        }

        do {
            let context = try makeHandlerContext(
                id: request.id,
                params: try Value(request.params),
                exchangeID: exchangeID,
                httpContext: httpContext,
                requireMetadata: true
            )
            if request.method == SubscriptionsListenRequest.name {
                try await Server.$currentHandlerContext.withValue(context) {
                    try await handleModernSubscription(request, context: context)
                }
                return
            }
            let payload = try await Server.$currentHandlerContext.withValue(context) {
                try await handleModernRequest(request, context: context)
            }
            let data = try encodeModernResponse(id: request.id, payload: payload)
            try await sendModern(data: data, exchangeID: exchangeID, terminal: true)
        } catch is CancellationError {
            return
        } catch {
            let mcpError = modernMCPError(error)
            do {
                let data = try encodeModernError(id: request.id, error: mcpError)
                try await sendModern(data: data, exchangeID: exchangeID, terminal: true)
            } catch {
                await logger?.debug(
                    "Modern response could not be delivered",
                    metadata: ["id": "\(request.id)", "error": "\(error)"]
                )
            }
        }
    }

    private func makeHandlerContext(
        id: ID,
        params: Value,
        exchangeID: ExchangeID?,
        httpContext: HTTPRequest?,
        requireMetadata: Bool
    ) throws -> HandlerContext {
        guard case .object(let fields) = params else {
            throw MCPError.invalidParams("Modern request params must be an object")
        }

        let metadata: RequestMetadata?
        if let rawMetadata = fields["_meta"] {
            metadata = try _protocolCoreDecodeValue(rawMetadata, as: RequestMetadata.self)
            if let logLevel = metadata?.logLevel, LogLevel(rawValue: logLevel) == nil {
                throw ProtocolCoreError.invalidRequestMetadata(RequestMetadata.logLevelKey)
            }
        } else if requireMetadata {
            throw ProtocolCoreError.missingRequestMetadata("_meta")
        } else {
            metadata = nil
        }

        var requestState: String?
        var inputResponses: InputResponses?
        if fields["requestState"] != nil || fields["inputResponses"] != nil {
            guard metadata != nil else {
                throw ProtocolCoreError.missingRequestMetadata("_meta")
            }
            let responseParameters = try _protocolCoreDecodeValue(
                params,
                as: InputResponseRequestParams.self
            )
            requestState = responseParameters.requestState
            inputResponses = responseParameters.inputResponses
        } else {
            requestState = nil
            inputResponses = nil
        }

        return HandlerContext(
            id: id,
            era: .modern,
            requestMetadata: metadata,
            requestState: requestState,
            inputResponses: inputResponses,
            httpContext: httpContext,
            exchangeID: exchangeID
        )
    }

    private func handleModernRequest(
        _ request: AnyRequest,
        context: HandlerContext
    ) async throws -> ModernResultPayload {
        try validateModernHeaders(request: request, context: context)
        try validateModernMethod(request.method)

        if request.method == ServerDiscover.name {
            return .complete(
                value: try Value(makeDiscoveryResult()),
                metadata: nil,
                cacheHint: nil
            )
        }

        try validateModernCapability(for: request.method)

        if request.method == CallTool.name {
            try await validateModernToolHeaders(request: request, context: context)
        }

        if request.method == ListTools.name {
            let page = try await invokeToolsList(request)
            let filtered = await filterValidTools(page)
            return .complete(
                value: try Value(filtered),
                metadata: nil,
                cacheHint: try conservativeCacheHint(for: request.method)
            )
        }

        guard let handler = modernMethodHandlers[request.method]
            ?? methodHandlers[request.method].map({ legacyHandler in
                ModernRequestHandlerBox { request in
                    let response = try await legacyHandler(request)
                    switch response.result {
                    case .success(let value):
                        return .complete(value: value, metadata: nil, cacheHint: nil)
                    case .failure(let error):
                        throw error
                    }
                }
            })
        else {
            throw MCPError.methodNotFound("Unknown method: \(request.method)")
        }

        let result = try await handler(request)
        try validateModernResult(result, for: request.method, metadata: context.requestMetadata)
        switch result {
        case .complete(let value, let metadata, let cacheHint):
            let resolvedCacheHint = try cacheHint ?? conservativeCacheHint(for: request.method)
            return .complete(
                value: value,
                metadata: metadata,
                cacheHint: resolvedCacheHint
            )
        case .inputRequired:
            return result
        }
    }

    private func handleModernNotification(_ message: AnyMessage) async throws {
        if message.method == CancelledNotification.name {
            let data = try JSONEncoder().encode(message)
            let cancellation = try JSONDecoder().decode(
                Message<CancelledNotification>.self,
                from: data
            )
            if let id = cancellation.params.requestId {
                cancelModernSubscription(for: .stream(id))
                if let task = modernStreamRequestTasks.removeValue(forKey: id) {
                    task.cancel()
                }
            }
            return
        }
        guard let handlers = notificationHandlers[message.method] else { return }
        for handler in handlers {
            try await handler(message)
        }
    }

    private func handleModernSubscription(
        _ request: AnyRequest,
        context: HandlerContext
    ) async throws {
        try validateModernHeaders(request: request, context: context)
        try validateModernMethod(request.method)
        let typedRequest = try Self.decode(request, as: SubscriptionsListenRequest.self)
        let key = context.exchangeID.map(ModernSubscriptionKey.exchange)
            ?? .stream(request.id)
        guard modernSubscriptions[key] == nil else {
            throw MCPError.invalidRequest("Subscription is already active")
        }
        guard modernSubscriptions.count < configuration.maxSubscriptions else {
            throw MCPError.localLimitExceeded(
                resource: "subscriptions",
                limit: configuration.maxSubscriptions
            )
        }

        let accepted = acceptedSubscriptionFilter(typedRequest.params.notifications)
        modernSubscriptions[key] = ModernSubscription(
            id: request.id,
            exchangeID: context.exchangeID,
            filter: accepted,
            continuation: nil
        )
        defer {
            if let subscription = modernSubscriptions.removeValue(forKey: key) {
                subscription.continuation?.resume()
            }
        }

        let acknowledgement = SubscriptionsAcknowledgedNotification.message(
            .init(subscriptionID: request.id, notifications: accepted)
        )
        try await sendModern(
            data: try JSONEncoder().encode(acknowledgement),
            exchangeID: context.exchangeID,
            terminal: false
        )

        await withTaskCancellationHandler(operation: {
            await waitForModernSubscription(key)
        }, onCancel: {
            Task { await self.cancelModernSubscription(for: key) }
        })
    }

    private func acceptedSubscriptionFilter(_ requested: SubscriptionFilter) -> SubscriptionFilter {
        SubscriptionFilter(
            toolsListChanged: requested.toolsListChanged == true
                && capabilities.tools?.listChanged == true ? true : nil,
            promptsListChanged: requested.promptsListChanged == true
                && capabilities.prompts?.listChanged == true ? true : nil,
            resourcesListChanged: requested.resourcesListChanged == true
                && capabilities.resources?.listChanged == true ? true : nil,
            resourceSubscriptions: capabilities.resources?.subscribe == true
                ? requested.resourceSubscriptions : nil
        )
    }

    private func waitForModernSubscription(_ key: ModernSubscriptionKey) async {
        await withCheckedContinuation { continuation in
            guard var subscription = modernSubscriptions[key] else {
                continuation.resume()
                return
            }
            subscription.continuation = continuation
            modernSubscriptions[key] = subscription
        }
    }

    func cancelModernSubscription(for key: ModernSubscriptionKey) {
        modernSubscriptions.removeValue(forKey: key)?.continuation?.resume()
    }

    func cancelModernRequests() {
        let tasks = Array(modernRequestTasks.values) + Array(modernStreamRequestTasks.values)
        modernRequestTasks.removeAll()
        modernStreamRequestTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    func finishModernSubscriptions() async {
        let subscriptions = Array(modernSubscriptions.values)
        modernSubscriptions.removeAll()
        for subscription in subscriptions {
            do {
                let result = SubscriptionsListenResult(
                    subscriptionID: subscription.id,
                    metadata: ResultMetadata(serverInfo: serverImplementationInfo())
                )
                let response = SubscriptionsListenRequest.response(
                    id: subscription.id,
                    result: result
                )
                try await sendModern(
                    data: try JSONEncoder().encode(response),
                    exchangeID: subscription.exchangeID,
                    terminal: true
                )
            } catch {
                await logger?.debug(
                    "Subscription could not close gracefully",
                    metadata: ["id": "\(subscription.id)", "error": "\(error)"]
                )
            }
            subscription.continuation?.resume()
        }
    }

    func sendModernNotificationIfNeeded(
        method: String,
        data: Data
    ) async throws -> Bool {
        if let context = Self.currentHandlerContext, context.era == .modern {
            switch method {
            case ProgressNotification.name:
                try await sendModern(
                    data: data,
                    exchangeID: context.exchangeID,
                    terminal: false
                )
                return true
            case LogMessageNotification.name:
                guard let requestedName = context.requestMetadata?.logLevel,
                    let requested = LogLevel(rawValue: requestedName)
                else {
                    return true
                }
                let message = try JSONDecoder().decode(
                    Message<LogMessageNotification>.self,
                    from: data
                )
                guard Self.logLevelRank(message.params.level) >= Self.logLevelRank(requested) else {
                    return true
                }
                try await sendModern(
                    data: data,
                    exchangeID: context.exchangeID,
                    terminal: false
                )
                return true
            default:
                break
            }
        }

        guard Self.isSubscriptionNotification(method) else {
            return connection is any ExchangeTransport
                && Self.currentHandlerContext?.era == .modern
        }

        var subscriptions: [ModernSubscription] = []
        for subscription in modernSubscriptions.values where try Self.subscription(
            subscription,
            accepts: method,
            data: data
        ) {
            subscriptions.append(subscription)
        }
        for subscription in subscriptions {
            try await sendModern(
                data: try Self.notificationData(
                    data,
                    subscriptionID: subscription.id
                ),
                exchangeID: subscription.exchangeID,
                terminal: false
            )
        }

        return !modernSubscriptions.isEmpty
            || connection is any ExchangeTransport
            || Self.currentHandlerContext?.era == .modern
    }

    private static func isSubscriptionNotification(_ method: String) -> Bool {
        switch method {
        case ToolListChangedNotification.name,
             PromptListChangedNotification.name,
             ResourceListChangedNotification.name,
             ResourceUpdatedNotification.name:
            return true
        default:
            return false
        }
    }

    private static func subscription(
        _ subscription: ModernSubscription,
        accepts method: String,
        data: Data
    ) throws -> Bool {
        switch method {
        case ToolListChangedNotification.name:
            return subscription.filter.toolsListChanged == true
        case PromptListChangedNotification.name:
            return subscription.filter.promptsListChanged == true
        case ResourceListChangedNotification.name:
            return subscription.filter.resourcesListChanged == true
        case ResourceUpdatedNotification.name:
            let message = try JSONDecoder().decode(
                Message<ResourceUpdatedNotification>.self,
                from: data
            )
            return subscription.filter.resourceSubscriptions?.contains(message.params.uri) == true
        default:
            return false
        }
    }

    private static func notificationData(
        _ data: Data,
        subscriptionID: ID
    ) throws -> Data {
        var fields = try JSONDecoder().decode([String: Value].self, from: data)
        var parameters = fields["params"]?.objectValue ?? [:]
        var metadata = parameters["_meta"]?.objectValue ?? [:]
        metadata[NotificationMetadata.subscriptionIDKey] = try Value(subscriptionID)
        parameters["_meta"] = .object(metadata)
        fields["params"] = .object(parameters)
        return try JSONEncoder().encode(fields)
    }

    private static func logLevelRank(_ level: LogLevel) -> Int {
        switch level {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .warning: 3
        case .error: 4
        case .critical: 5
        case .alert: 6
        case .emergency: 7
        }
    }

    private func validateModernHeaders(
        request: AnyRequest,
        context: HandlerContext
    ) throws {
        guard let metadata = context.requestMetadata else {
            throw MCPError.invalidParams("Modern requests require _meta")
        }
        guard let httpContext = context.httpContext else { return }

        if let version = httpContext.header(HTTPHeaderName.protocolVersion),
            version != metadata.protocolVersion
        {
            throw MCPError.headerMismatch("\(HTTPHeaderName.protocolVersion) does not match _meta")
        }

        guard let method = httpContext.header(HTTPHeaderName.method) else {
            throw MCPError.headerMismatch("Missing \(HTTPHeaderName.method) header")
        }
        guard method == request.method else {
            throw MCPError.headerMismatch("\(HTTPHeaderName.method) does not match method")
        }

        let nameMethods: Set<String> = [
            CallTool.name,
            GetPrompt.name,
            ReadResource.name,
        ]
        if nameMethods.contains(request.method) {
            guard let expectedName = modernHeaderName(for: request) else {
                throw MCPError.invalidParams("Modern method name is missing")
            }
            guard let name = httpContext.header(HTTPHeaderName.name) else {
                throw MCPError.headerMismatch("Missing \(HTTPHeaderName.name) header")
            }
            let decodedName = try ToolHeaderResolver.decodeHeaderValue(name)
            guard decodedName == expectedName else {
                throw MCPError.headerMismatch("\(HTTPHeaderName.name) does not match request")
            }
        } else if httpContext.header(HTTPHeaderName.name) != nil {
            throw MCPError.headerMismatch("Unexpected \(HTTPHeaderName.name) header")
        }
    }

    private func modernHeaderName(for request: AnyRequest) -> String? {
        guard let fields = request.params.objectValue else { return nil }
        switch request.method {
        case CallTool.name, GetPrompt.name:
            return fields["name"]?.stringValue
        case ReadResource.name:
            return fields["uri"]?.stringValue
        default:
            return nil
        }
    }

    private func validateModernToolHeaders(
        request: AnyRequest,
        context: HandlerContext
    ) async throws {
        guard let httpContext = context.httpContext else { return }
        let call = try Self.decode(request, as: CallTool.self)
        let resolver = try await resolveToolHeaderSchema(named: call.params.name)
        let expected = try resolver.resolveValues(arguments: call.params.arguments ?? [:])
        let expectedByName = Dictionary(
            uniqueKeysWithValues: expected.map { ($0.key.lowercased(), $0.value) }
        )

        for headerName in resolver.recognizedHeaderNames {
            let matches = httpContext.headers.filter { $0.key.lowercased() == headerName }
            guard matches.count <= 1 else {
                throw MCPError.headerMismatch("Duplicate custom MCP header")
            }
            guard let expectedValue = expectedByName[headerName] else {
                guard matches.isEmpty else {
                    throw MCPError.headerMismatch("Unexpected custom MCP header")
                }
                continue
            }
            guard let rawValue = matches.values.first else {
                throw MCPError.headerMismatch("Missing custom MCP header")
            }
            let decodedValue = try ToolHeaderResolver.decodeHeaderValue(rawValue)
            guard Self.headerValue(decodedValue, matches: expectedValue) else {
                throw MCPError.headerMismatch("Custom MCP header does not match request")
            }
        }
    }

    private static func headerValue(_ header: String, matches expected: Value) -> Bool {
        switch expected {
        case .string(let value):
            return header == value
        case .int(let value):
            return Int(header) == value
        case .bool(let value):
            return header == (value ? "true" : "false")
        default:
            return false
        }
    }

    private func resolveToolHeaderSchema(named name: String) async throws -> ToolHeaderResolver {
        var cursor: String?
        var seenCursors: Set<String> = []
        var sawInvalidTarget = false

        for _ in 0..<configuration.maxToolSchemaLookupPages {
            let request: AnyRequest
            if let cursor {
                request = try AnyRequest(ListTools.request(.init(cursor: cursor)))
            } else {
                request = try AnyRequest(ListTools.request(ListTools.Parameters()))
            }
            let page = try await invokeToolsList(request)
            for tool in page.tools where tool.name == name {
                do {
                    return try ToolHeaderResolver(schema: tool.inputSchema)
                } catch {
                    sawInvalidTarget = true
                }
            }

            guard let nextCursor = page.nextCursor else {
                if sawInvalidTarget {
                    throw ProtocolCoreError.invalidToolSchema("Tool '\(name)' has an invalid inputSchema")
                }
                throw MCPError.methodNotFound("Unknown tool: \(name)")
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw MCPError.invalidParams("tools/list cursor cycle")
            }
            cursor = nextCursor
        }

        throw MCPError.localLimitExceeded(
            resource: "toolSchemaLookupPages",
            limit: configuration.maxToolSchemaLookupPages
        )
    }

    private func invokeToolsList(_ request: AnyRequest) async throws -> ListTools.Result {
        guard let handler = methodHandlers[ListTools.name] else {
            throw MCPError.methodNotFound("Unknown method: \(ListTools.name)")
        }
        let response = try await handler(request)
        switch response.result {
        case .success(let value):
            return try _protocolCoreDecodeValue(value, as: ListTools.Result.self)
        case .failure(let error):
            throw error
        }
    }

    private func filterValidTools(_ page: ListTools.Result) async -> ListTools.Result {
        var tools: [Tool] = []
        tools.reserveCapacity(page.tools.count)
        for tool in page.tools {
            do {
                _ = try ToolHeaderResolver(schema: tool.inputSchema)
                tools.append(tool)
            } catch {
                await logger?.warning(
                    "Ignoring tool with invalid input schema",
                    metadata: ["tool": "\(tool.name)", "error": "\(error)"]
                )
            }
        }
        return ListTools.Result(tools: tools, nextCursor: page.nextCursor, _meta: page._meta)
    }

    private func validateModernMethod(_ method: String) throws {
        // Modern HTTP is stateless and has no initialize/initialized session
        // phase. Other methods remain available through their registered slots.
        if method == Initialize.name || method == Ping.name || method == SetLoggingLevel.name
            || method == ResourceSubscribe.name || method == ResourceUnsubscribe.name
        {
            throw MCPError.methodNotFound("Method is not available in the modern era: \(method)")
        }
    }

    private func validateModernCapability(for method: String) throws {
        switch method {
        case CallTool.name, ListTools.name:
            guard capabilities.tools != nil else {
                throw MCPError.methodNotFound("Tools capability is not enabled")
            }
        case GetPrompt.name, ListPrompts.name:
            guard capabilities.prompts != nil else {
                throw MCPError.methodNotFound("Prompts capability is not enabled")
            }
        case ReadResource.name, ListResources.name, ListResourceTemplates.name,
             ResourceSubscribe.name, ResourceUnsubscribe.name:
            guard capabilities.resources != nil else {
                throw MCPError.methodNotFound("Resources capability is not enabled")
            }
        default:
            break
        }
    }

    private func validateModernResult(
        _ result: ModernResultPayload,
        for method: String,
        metadata: RequestMetadata?
    ) throws {
        guard let metadata else {
            throw MCPError.invalidParams("Modern requests require _meta")
        }
        switch result {
        case .complete:
            return
        case .inputRequired(let input):
            guard [CallTool.name, GetPrompt.name, ReadResource.name].contains(method) else {
                throw ProtocolCoreError.invalidResultInput
            }
            guard input.inputRequests != nil || input.requestState != nil else {
                throw ProtocolCoreError.invalidResultInput
            }
            try validateInputRequests(input.inputRequests, capabilities: metadata.clientCapabilities)
        }
    }

    private func validateInputRequests(
        _ requests: InputRequests?,
        capabilities: CapabilitySet
    ) throws {
        guard let requests else { return }
        for inputRequest in requests.values {
            let requiredKey: String
            switch inputRequest.method {
            case .samplingCreateMessage:
                requiredKey = "sampling"
            case .rootsList:
                requiredKey = "roots"
            case .elicitationCreate:
                requiredKey = "elicitation"
            }
            guard capabilities[requiredKey] != nil else {
                throw MCPError.missingRequiredClientCapability(
                    required: [requiredKey: .object([:])]
                )
            }
        }
    }

    private func conservativeCacheHint(for method: String) throws -> CacheHint? {
        switch method {
        case ListTools.name, ListPrompts.name, ListResources.name,
             ListResourceTemplates.name, ReadResource.name:
            return try CacheHint(scope: .private, ttlMs: 0)
        default:
            return nil
        }
    }

    // MARK: - Modern encoding and discovery

    private func makeDiscoveryResult() throws -> DiscoverResult {
        let fields = capabilityFields()
        let serverImplementation = ImplementationInfo(
            name: serverInfo.name,
            version: serverInfo.version,
            title: serverInfo.title,
            description: serverInfo.description,
            websiteUrl: serverInfo.websiteUrl,
            icons: serverInfo.icons
        )
        return try DiscoverResult(
            supportedVersions: [Version.modern],
            capabilities: CapabilitySet(fields),
            instructions: instructions,
            cacheHint: CacheHint(scope: .private, ttlMs: 0),
            metadata: ResultMetadata(serverInfo: serverImplementation)
        )
    }

    private func capabilityFields() -> [String: Value] {
        var fields: [String: Value] = [:]
        if let completions = capabilities.completions, completions == .init() {
            fields["completions"] = .object([:])
        }
        if let logging = capabilities.logging, logging == .init() {
            fields["logging"] = .object([:])
        }
        if let prompts = capabilities.prompts {
            var value: [String: Value] = [:]
            if let listChanged = prompts.listChanged { value["listChanged"] = .bool(listChanged) }
            fields["prompts"] = .object(value)
        }
        if let resources = capabilities.resources {
            var value: [String: Value] = [:]
            if let subscribe = resources.subscribe { value["subscribe"] = .bool(subscribe) }
            if let listChanged = resources.listChanged { value["listChanged"] = .bool(listChanged) }
            fields["resources"] = .object(value)
        }
        if let tools = capabilities.tools {
            var value: [String: Value] = [:]
            if let listChanged = tools.listChanged { value["listChanged"] = .bool(listChanged) }
            fields["tools"] = .object(value)
        }
        return fields
    }

    private func encodeModernResponse(
        id: ID,
        payload: ModernResultPayload
    ) throws -> Data {
        let resultValue: Value
        switch payload {
        case .complete(let value, let metadata, let cacheHint):
            resultValue = try completeValue(
                value,
                metadata: metadata,
                cacheHint: cacheHint
            )
        case .inputRequired(let input):
            resultValue = try inputRequiredValue(input)
        }
        return try JSONEncoder().encode(
            AnyResponse(id: id, result: .success(resultValue))
        )
    }

    private func completeValue(
        _ value: Value,
        metadata: ResultMetadata?,
        cacheHint: CacheHint?
    ) throws -> Value {
        guard case .object(var fields) = value else {
            throw ProtocolCoreError.invalidResultInput
        }
        var metadataFields = fields["_meta"]?.objectValue ?? [:]
        if let metadata {
            metadataFields.merge(metadata.additionalFields) { _, new in new }
        }
        metadataFields[ResultMetadata.serverInfoKey] = try Value(serverImplementationInfo())
        fields["_meta"] = .object(metadataFields)
        fields["resultType"] = .string(ResultType.complete.rawValue)
        if let cacheHint {
            fields["cacheScope"] = .string(cacheHint.scope.rawValue)
            fields["ttlMs"] = .int(cacheHint.ttlMs)
        }
        return .object(fields)
    }

    private func inputRequiredValue(_ value: InputRequiredResult) throws -> Value {
        guard case .object(var fields) = try Value(value) else {
            throw ProtocolCoreError.invalidResultInput
        }
        var metadataFields = fields["_meta"]?.objectValue ?? [:]
        metadataFields[ResultMetadata.serverInfoKey] = try Value(serverImplementationInfo())
        fields["_meta"] = .object(metadataFields)
        return .object(fields)
    }

    private func serverImplementationInfo() -> ImplementationInfo {
        ImplementationInfo(
            name: serverInfo.name,
            version: serverInfo.version,
            title: serverInfo.title,
            description: serverInfo.description,
            websiteUrl: serverInfo.websiteUrl,
            icons: serverInfo.icons
        )
    }

    private func encodeModernError(id: ID, error: MCPError) throws -> Data {
        try JSONEncoder().encode(AnyResponse(id: id, error: error))
    }

    private func sendModern(
        data: Data,
        exchangeID: ExchangeID?,
        terminal: Bool
    ) async throws {
        guard let connection else {
            throw MCPError.internalError("Server connection not initialized")
        }
        if let exchangeID, let transport = connection as? any ExchangeTransport {
            try await transport.send(
                .data(exchangeID: exchangeID, data: data, terminal: terminal)
            )
        } else {
            try await connection.send(data)
        }
    }

    private func modernMCPError(_ error: Swift.Error) -> MCPError {
        if let error = error as? MCPError { return error }
        if let error = error as? ProtocolCoreError {
            return .invalidParams(error.localizedDescription)
        }
        return .internalError(error.localizedDescription)
    }
}
