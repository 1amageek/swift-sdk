import Foundation

extension Client {
    /// Selects whether connection negotiation may fall back to the legacy handshake.
    public enum ConnectionPreference: String, Codable, Hashable, Sendable {
        case modernOnly
        case modernThenLegacy
    }

    /// Declares the wire semantics of the supplied transport.
    public enum TransportDelivery: String, Codable, Hashable, Sendable {
        case byteStream
        case http
    }

    /// A decoded modern result plus its request-scoped metadata and cache hint.
    public struct ModernResult<Output: Hashable & Codable & Sendable>: Hashable, Sendable {
        public let value: Output
        public let metadata: ResultMetadata?
        public let cacheHint: CacheHint?

        public init(value: Output, metadata: ResultMetadata?, cacheHint: CacheHint?) {
            self.value = value
            self.metadata = metadata
            self.cacheHint = cacheHint
        }
    }

    /// One notification delivered by a modern subscription.
    public struct SubscriptionEvent: Hashable, Sendable {
        public let method: String
        public let parameters: Value

        public init(method: String, parameters: Value) {
            self.method = method
            self.parameters = parameters
        }
    }

    /// An acknowledged modern subscription and its finite event stream.
    public struct Subscription: Sendable {
        public let id: ID
        public let notifications: SubscriptionFilter
        public let events: AsyncThrowingStream<SubscriptionEvent, Swift.Error>

        public init(
            id: ID,
            notifications: SubscriptionFilter,
            events: AsyncThrowingStream<SubscriptionEvent, Swift.Error>
        ) {
            self.id = id
            self.notifications = notifications
            self.events = events
        }
    }

    /// Connects with explicit modern-only or modern-then-legacy negotiation.
    @discardableResult
    public func connect(
        transport: any Transport,
        preference: ConnectionPreference,
        delivery: TransportDelivery
    ) async throws -> ConnectionInfo {
        try await establishConnection(transport: transport, delivery: delivery)
        do {
            let info = try await negotiateConnection(preference: preference)
            connectionInfo = info
            return info
        } catch {
            await disconnect()
            throw error
        }
    }

    /// Sends one modern request and exposes its result metadata without retaining a cache.
    public func sendModern<M: Method>(
        _ request: Request<M>,
        metadata: RequestMetadata? = nil
    ) async throws -> ModernResult<M.Result> {
        guard connectionInfo?.era == .modern else {
            throw MCPError.negotiationFailed("A modern connection is required")
        }
        let requestMetadata = try metadata ?? makeRequestMetadata()
        let parameters = try modernParameters(from: request.params, metadata: requestMetadata)
        let completed = try await performModernCall(
            method: request.method,
            initialParameters: parameters,
            metadata: requestMetadata
        )
        let value = completed.value
        let output = try decode(M.Result.self, from: value)
        return ModernResult(
            value: output,
            metadata: completed.envelope.metadata,
            cacheHint: completed.envelope.cacheHint
        )
    }

    /// Starts a modern subscription and returns only after acknowledgement.
    public func listen(
        notifications: SubscriptionFilter,
        metadata: RequestMetadata? = nil
    ) async throws -> Subscription {
        guard connectionInfo?.era == .modern else {
            throw MCPError.negotiationFailed("A modern connection is required")
        }
        return try await startSubscription(
            notifications: notifications,
            metadata: try metadata ?? makeRequestMetadata()
        )
    }

    /// Cancels one active modern subscription.
    public func cancelSubscription(_ id: ID, reason: String? = nil) async {
        await stopSubscription(id, reason: reason, notifyServer: true)
    }
}

struct ClientSubscriptionState {
    var acknowledgement: CheckedContinuation<Client.Subscription, Swift.Error>?
    let stream: AsyncThrowingStream<Client.SubscriptionEvent, Swift.Error>
    let continuation: AsyncThrowingStream<Client.SubscriptionEvent, Swift.Error>.Continuation
    var deliveryTask: Task<Void, Never>?
    var acknowledged = false
    var notifications: SubscriptionFilter?
}

struct CompletedModernValue {
    let value: Value
    let envelope: ResultEnvelope
}

extension Client {
    func establishConnection(
        transport: any Transport,
        delivery: TransportDelivery
    ) async throws {
        guard connection == nil else {
            throw MCPError.internalError("Client already connected")
        }
        if delivery == .http {
            guard let httpTransport = transport as? any HTTPRequestSendingTransport else {
                throw MCPError.negotiationFailed(
                    "HTTP delivery requires an HTTP request-capable transport"
                )
            }
            await httpTransport.updateNegotiatedProtocolVersion(Version.modern)
        }
        connection = transport
        transportDelivery = delivery
        do {
            try await transport.connect()
        } catch {
            connection = nil
            transportDelivery = nil
            throw error
        }

        task = Task { await self.runMessageLoop(on: transport) }
        if !cancellationHandlerRegistered {
            cancellationHandlerRegistered = true
            await onNotification(CancelledNotification.self) { [weak self] message in
                guard let self, let requestID = message.params.requestId else { return }
                await self.handleRemoteCancellation(requestID)
            }
        }

        await logger?.debug(
            "Client connected",
            metadata: ["name": "\(name)", "version": "\(version)"]
        )
    }

    private func negotiateConnection(
        preference: ConnectionPreference
    ) async throws -> ConnectionInfo {
        let metadata = try makeRequestMetadata()
        let parameters = try Value(ModernRequestParameters(metadata: metadata))
        do {
            return try await discoverModernServer(parameters: parameters)
        } catch let remote as DiscoveryRemoteError {
            if case .unsupportedProtocolVersion(_, let supported) = remote.error,
                supported.contains(Version.modern)
            {
                return try await discoverModernServer(parameters: parameters)
            }
            if Self.isRecognizedModernError(remote.error) || preference == .modernOnly {
                throw remote.error
            }
            return try await fallBackToLegacy()
        } catch is DiscoveryProbeTimeout {
            guard preference == .modernThenLegacy else {
                throw MCPError.negotiationFailed("Modern discovery timed out")
            }
            return try await fallBackToLegacy()
        }
    }

    private func discoverModernServer(parameters: Value) async throws -> ConnectionInfo {
        let value = try await sendDiscoveryProbe(parameters: parameters)
        let result = try decode(DiscoverResult.self, from: value)
        guard result.supportedVersions.contains(Version.modern) else {
            throw MCPError.unsupportedProtocolVersion(
                requested: Version.modern,
                supported: result.supportedVersions
            )
        }
        serverVersion = Version.modern
        instructions = result.instructions
        return try ConnectionInfo(
            era: .modern,
            protocolVersion: Version.modern,
            serverCapabilities: result.capabilities,
            serverInfo: result.metadata?.serverInfo,
            instructions: result.instructions
        )
    }

    private func fallBackToLegacy() async throws -> ConnectionInfo {
        if let httpTransport = connection as? any HTTPRequestSendingTransport {
            await httpTransport.updateNegotiatedProtocolVersion(Version.latest)
        }
        let result = try await _initialize()
        return try ConnectionInfo(
            era: .legacy,
            protocolVersion: result.protocolVersion,
            serverCapabilities: try capabilitySet(from: result.capabilities),
            serverInfo: implementationInfo(from: result.serverInfo),
            instructions: result.instructions
        )
    }

    private func sendDiscoveryProbe(parameters: Value) async throws -> Value {
        let requestID = ID.random
        negotiationProbeID = requestID
        let timeout = configuration.discoveryProbeTimeout
        let timer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
                await self?.expireDiscoveryProbe(requestID)
            } catch is CancellationError {
                return
            } catch {
                await self?.expireDiscoveryProbe(requestID)
            }
        }
        defer {
            timer.cancel()
            if negotiationProbeID == requestID {
                negotiationProbeID = nil
            }
        }
        return try await sendModernValue(
            id: requestID,
            method: ServerDiscover.name,
            parameters: parameters
        )
    }

    func sendModernValue(
        id: ID = .random,
        method: String,
        parameters: Value,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Value {
        guard let connection, let delivery = transportDelivery else {
            throw MCPError.connectionClosed
        }
        let request = Request<AnyMethod>(id: id, method: method, params: parameters)
        let data = try MessageCodec(era: .modern).encode(request)
        var headers = additionalHeaders
        headers[HTTPHeaderName.protocolVersion] = Version.modern
        headers[HTTPHeaderName.method] = method

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                addPendingRequest(id: id, continuation: continuation, type: Value.self)
                let deliveryTask = Task {
                    do {
                        try await sendModernPayload(
                            data,
                            headers: headers,
                            connection: connection,
                            delivery: delivery
                        )
                        modernDeliveryTasks.removeValue(forKey: id)
                    } catch {
                        modernDeliveryTasks.removeValue(forKey: id)
                        if let pending = removePendingRequest(id: id) {
                            if negotiationProbeID == id { negotiationProbeID = nil }
                            pending.resume(throwing: error)
                        }
                    }
                }
                modernDeliveryTasks[id] = deliveryTask
            }
        } onCancel: {
            Task { await self.cancelModernRequest(id) }
        }
    }

    private func sendModernPayload(
        _ data: Data,
        headers: [String: String],
        connection: any Transport,
        delivery: TransportDelivery
    ) async throws {
        switch delivery {
        case .byteStream:
            try await connection.send(data)
        case .http:
            guard let httpTransport = connection as? any HTTPRequestSendingTransport else {
                throw MCPError.negotiationFailed(
                    "HTTP delivery requires an HTTP request-capable transport"
                )
            }
            try await httpTransport.send(data, headers: headers)
        }
    }

    private func performModernCall(
        method: String,
        initialParameters: Value,
        metadata: RequestMetadata
    ) async throws -> CompletedModernValue {
        var parameters = initialParameters
        var toolResolver: ToolHeaderResolver?
        var headerRetryUsed = false
        var requestsSent = 0
        let usesToolHeaders = method == CallTool.name && transportDelivery == .http

        if usesToolHeaders {
            toolResolver = try await resolveToolHeaders(parameters: parameters, metadata: metadata)
        }

        while requestsSent < configuration.maxRounds {
            let headers = try modernHeaders(
                method: method,
                parameters: parameters,
                toolResolver: toolResolver
            )
            let value: Value
            do {
                requestsSent += 1
                value = try await sendModernValue(
                    method: method,
                    parameters: parameters,
                    additionalHeaders: headers
                )
            } catch let error as MCPError
                where usesToolHeaders && error.code == -32020 && !headerRetryUsed
            {
                guard requestsSent < configuration.maxRounds else {
                    throw MCPError.localLimitExceeded(
                        resource: "modernRequestRounds",
                        limit: configuration.maxRounds
                    )
                }
                headerRetryUsed = true
                toolResolver = try await resolveToolHeaders(
                    parameters: parameters,
                    metadata: metadata
                )
                requestsSent += 1
                value = try await sendModernValue(
                    method: method,
                    parameters: parameters,
                    additionalHeaders: try modernHeaders(
                        method: method,
                        parameters: parameters,
                        toolResolver: toolResolver
                    )
                )
            }

            let envelope = try decodeModernEnvelope(value)
            if envelope.resultType == .complete {
                return CompletedModernValue(value: value, envelope: envelope)
            }
            guard envelope.resultType == .inputRequired,
                method == CallTool.name || method == GetPrompt.name || method == ReadResource.name
            else {
                throw ProtocolCoreError.invalidResultType
            }
            guard requestsSent < configuration.maxRounds else {
                throw MCPError.localLimitExceeded(
                    resource: "modernRequestRounds",
                    limit: configuration.maxRounds
                )
            }
            let input = try decode(InputRequiredResult.self, from: value)
            parameters = try await nextRoundParameters(
                initialParameters: initialParameters,
                input: input,
                metadata: metadata
            )
        }

        throw MCPError.localLimitExceeded(
            resource: "modernRequestRounds",
            limit: configuration.maxRounds
        )
    }

    private func modernHeaders(
        method: String,
        parameters: Value,
        toolResolver: ToolHeaderResolver?
    ) throws -> [String: String] {
        guard transportDelivery == .http else { return [:] }
        guard case .object(let fields) = parameters else {
            throw MCPError.invalidParams("Modern request parameters must be an object")
        }
        var headers: [String: String] = [:]
        if method == CallTool.name || method == GetPrompt.name,
            let name = fields["name"]?.stringValue
        {
            headers[HTTPHeaderName.name] = try ToolHeaderResolver.encodeHeaderValue(.string(name))
        } else if method == ReadResource.name, let uri = fields["uri"]?.stringValue {
            headers[HTTPHeaderName.name] = try ToolHeaderResolver.encodeHeaderValue(.string(uri))
        }
        if method == CallTool.name {
            guard let toolResolver else {
                throw MCPError.internalError("Tool header resolver is missing")
            }
            headers.merge(
                try toolResolver.resolve(arguments: fields["arguments"] ?? .object([:]))
            ) { _, new in new }
        }
        return headers
    }

    private func resolveToolHeaders(
        parameters: Value,
        metadata: RequestMetadata
    ) async throws -> ToolHeaderResolver {
        guard case .object(let fields) = parameters,
            let name = fields["name"]?.stringValue
        else {
            throw MCPError.invalidParams("tools/call requires a name")
        }
        var cursor: String?
        var seenCursors: Set<String> = []

        for pageIndex in 0..<configuration.maxToolListPages {
            let listParameters =
                cursor.map(ListTools.Parameters.init(cursor:))
                ?? ListTools.Parameters()
            let rawParameters = try modernParameters(from: listParameters, metadata: metadata)
            let value = try await sendModernValue(
                method: ListTools.name,
                parameters: rawParameters
            )
            let envelope = try decodeModernEnvelope(value)
            guard envelope.resultType == .complete else {
                throw ProtocolCoreError.invalidResultType
            }
            let page = try decode(ListTools.Result.self, from: value)
            for tool in page.tools where tool.name == name {
                return try ToolHeaderResolver(schema: tool.inputSchema)
            }
            guard let nextCursor = page.nextCursor else {
                throw MCPError.methodNotFound("Unknown tool: \(name)")
            }
            guard pageIndex + 1 < configuration.maxToolListPages else {
                throw MCPError.localLimitExceeded(
                    resource: "toolListPages",
                    limit: configuration.maxToolListPages
                )
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw MCPError.invalidParams("tools/list cursor cycle")
            }
            cursor = nextCursor
        }

        throw MCPError.localLimitExceeded(
            resource: "toolListPages",
            limit: configuration.maxToolListPages
        )
    }

    private func nextRoundParameters(
        initialParameters: Value,
        input: InputRequiredResult,
        metadata: RequestMetadata
    ) async throws -> Value {
        guard case .object(var fields) = initialParameters else {
            throw MCPError.invalidParams("Modern request parameters must be an object")
        }
        let responses = try await fulfill(input.inputRequests)
        fields["_meta"] = try Value(metadata)
        fields["requestState"] = input.requestState.map(Value.string)
        if let responses {
            fields["inputResponses"] = try Value(responses)
        } else {
            fields["inputResponses"] = nil
        }
        return .object(fields)
    }

    private func fulfill(_ requests: InputRequests?) async throws -> InputResponses? {
        guard let requests else { return nil }
        var responses: InputResponses = [:]
        responses.reserveCapacity(requests.count)
        for key in requests.keys.sorted() {
            guard let input = requests[key] else { continue }
            try validateInputCapability(input.method)
            guard let handler = methodHandlers[input.method.rawValue] else {
                throw MCPError.methodNotFound(
                    "No client handler registered for \(input.method.rawValue)"
                )
            }
            let request = Request<AnyMethod>(
                id: .string(key),
                method: input.method.rawValue,
                params: input.params ?? .object([:])
            )
            let response = try await handler(request)
            switch response.result {
            case .success(let value):
                responses[key] = try InputResponse(method: input.method, value: value)
            case .failure(let error):
                throw error
            }
        }
        return responses
    }

    private func validateInputCapability(_ method: InputRequestMethod) throws {
        let available: Bool
        let name: String
        switch method {
        case .samplingCreateMessage:
            available = capabilities.sampling != nil
            name = "sampling"
        case .rootsList:
            available = capabilities.roots != nil
            name = "roots"
        case .elicitationCreate:
            available = capabilities.elicitation != nil
            name = "elicitation"
        }
        guard available else {
            throw MCPError.missingRequiredClientCapability(
                required: [name: .object([:])]
            )
        }
    }

    private func startSubscription(
        notifications: SubscriptionFilter,
        metadata: RequestMetadata
    ) async throws -> Subscription {
        guard let connection, let delivery = transportDelivery else {
            throw MCPError.connectionClosed
        }
        let id = ID.random
        let pair = AsyncThrowingStream<SubscriptionEvent, Swift.Error>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.stopSubscription(id, reason: nil, notifyServer: true) }
        }
        let parameters = SubscriptionsListenRequest.Parameters(
            notifications: notifications,
            metadata: metadata
        )
        let request = SubscriptionsListenRequest.request(id: id, parameters)
        let data = try MessageCodec(era: .modern).encode(request)
        let headers = [
            HTTPHeaderName.protocolVersion: Version.modern,
            HTTPHeaderName.method: SubscriptionsListenRequest.name,
        ]

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { acknowledgement in
                modernSubscriptions[id] = ClientSubscriptionState(
                    acknowledgement: acknowledgement,
                    stream: pair.stream,
                    continuation: pair.continuation,
                    deliveryTask: nil,
                    notifications: nil
                )
                let deliveryTask = Task {
                    do {
                        try await sendModernPayload(
                            data,
                            headers: headers,
                            connection: connection,
                            delivery: delivery
                        )
                    } catch {
                        failSubscription(id, with: error)
                    }
                }
                modernSubscriptions[id]?.deliveryTask = deliveryTask
            }
        } onCancel: {
            Task { await self.stopSubscription(id, reason: nil, notifyServer: true) }
        }
    }

    func handleSubscriptionMessage(_ message: Message<AnyNotification>) async -> Bool {
        if message.method == SubscriptionsAcknowledgedNotification.name {
            do {
                let data = try encoder.encode(message)
                let acknowledgement = try decoder.decode(
                    Message<SubscriptionsAcknowledgedNotification>.self,
                    from: data
                )
                let id = acknowledgement.params.subscriptionID
                guard var state = modernSubscriptions[id], !state.acknowledged else {
                    return true
                }
                state.acknowledged = true
                state.notifications = acknowledgement.params.notifications
                let continuation = state.acknowledgement
                state.acknowledgement = nil
                modernSubscriptions[id] = state
                continuation?.resume(
                    returning: Subscription(
                        id: id,
                        notifications: acknowledgement.params.notifications,
                        events: state.stream
                    )
                )
            } catch {
                let waiting = modernSubscriptions.filter { !$0.value.acknowledged }
                for id in waiting.keys {
                    failSubscription(id, with: error)
                }
                await logger?.warning(
                    "Invalid subscription acknowledgement",
                    metadata: ["error": "\(error)"]
                )
            }
            return true
        }

        guard case .object(let fields) = message.params,
            case .object(let metadataFields) = fields["_meta"],
            let rawID = metadataFields[NotificationMetadata.subscriptionIDKey]
        else {
            return false
        }
        do {
            let id = try decode(ID.self, from: rawID)
            guard let state = modernSubscriptions[id] else { return true }
            guard state.acknowledged else {
                failSubscription(
                    id,
                    with: MCPError.invalidRequest(
                        "Subscription notification preceded acknowledgement"
                    )
                )
                return true
            }
            guard let notifications = state.notifications,
                subscription(notifications, accepts: message.method, parameters: fields)
            else {
                return true
            }
            state.continuation.yield(
                SubscriptionEvent(method: message.method, parameters: message.params)
            )
        } catch {
            await logger?.warning(
                "Invalid subscription notification metadata",
                metadata: ["error": "\(error)"]
            )
        }
        return true
    }

    private func subscription(
        _ filter: SubscriptionFilter,
        accepts method: String,
        parameters: [String: Value]
    ) -> Bool {
        switch method {
        case ToolListChangedNotification.name:
            return filter.toolsListChanged == true
        case PromptListChangedNotification.name:
            return filter.promptsListChanged == true
        case ResourceListChangedNotification.name:
            return filter.resourcesListChanged == true
        case ResourceUpdatedNotification.name:
            guard let uri = parameters["uri"]?.stringValue else { return false }
            return filter.resourceSubscriptions?.contains(uri) == true
        default:
            return false
        }
    }

    func handleSubscriptionResponse(_ response: AnyResponse) -> Bool {
        guard let state = modernSubscriptions.removeValue(forKey: response.id) else {
            return false
        }
        state.deliveryTask?.cancel()
        switch response.result {
        case .success(let value):
            do {
                let result = try decode(SubscriptionsListenResult.self, from: value)
                guard result.subscriptionID == response.id else {
                    throw MCPError.invalidRequest("Subscription terminal ID mismatch")
                }
                if !state.acknowledged {
                    throw MCPError.invalidRequest("Subscription ended before acknowledgement")
                }
                state.continuation.finish()
            } catch {
                state.acknowledgement?.resume(throwing: error)
                state.continuation.finish(throwing: error)
            }
        case .failure(let error):
            state.acknowledgement?.resume(throwing: error)
            state.continuation.finish(throwing: error)
        }
        return true
    }

    func stopSubscription(_ id: ID, reason: String?, notifyServer: Bool) async {
        guard let state = modernSubscriptions.removeValue(forKey: id) else { return }
        state.deliveryTask?.cancel()
        state.acknowledgement?.resume(throwing: CancellationError())
        state.continuation.finish()
        guard notifyServer else { return }
        await sendModernCancellation(id, reason: reason)
    }

    private func failSubscription(_ id: ID, with error: Swift.Error) {
        guard let state = modernSubscriptions.removeValue(forKey: id) else { return }
        state.deliveryTask?.cancel()
        state.acknowledgement?.resume(throwing: error)
        state.continuation.finish(throwing: error)
    }

    private func cancelModernRequest(_ id: ID) async {
        guard let pending = removePendingRequest(id: id) else { return }
        modernDeliveryTasks.removeValue(forKey: id)?.cancel()
        pending.resume(throwing: CancellationError())
        await sendModernCancellation(id, reason: nil)
    }

    private func sendModernCancellation(_ id: ID, reason: String?) async {
        guard let connection, let delivery = transportDelivery else { return }
        do {
            let message = CancelledNotification.message(
                .init(requestId: id, reason: reason)
            )
            let data = try MessageCodec(era: .modern).encode(message)
            try await sendModernPayload(
                data,
                headers: [
                    HTTPHeaderName.protocolVersion: Version.modern,
                    HTTPHeaderName.method: CancelledNotification.name,
                ],
                connection: connection,
                delivery: delivery
            )
        } catch {
            await logger?.debug(
                "Modern cancellation could not be sent",
                metadata: ["id": "\(id)", "error": "\(error)"]
            )
        }
    }

    func runMessageLoop(on transport: any Transport) async {
        while !Task.isCancelled {
            do {
                let stream = await transport.receive()
                for try await data in stream {
                    if Task.isCancelled { break }
                    let decoded = await processIncomingData(data)
                    if !decoded && (connectionInfo?.era == .modern || negotiationProbeID != nil) {
                        failAllPending(
                            with: ProtocolCoreError.malformedMessage(
                                "message is not a valid request, response, or notification"
                            )
                        )
                        return
                    }
                }
                if !Task.isCancelled {
                    failAllPending(with: MCPError.connectionClosed)
                }
                break
            } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    break
                }
            } catch {
                failAllPending(with: error)
                break
            }
        }
        await logger?.debug("Client message handling loop task is terminating.")
    }

    private func processIncomingData(_ data: Data) async -> Bool {
        if let batch = try? decoder.decode([AnyResponse].self, from: data) {
            await handleBatchResponse(batch)
            return true
        }
        if let response = try? decoder.decode(AnyResponse.self, from: data) {
            await handleResponse(response)
            return true
        }
        if let request = try? decoder.decode(AnyRequest.self, from: data) {
            await handleIncomingRequest(request)
            return true
        }
        if let message = try? decoder.decode(AnyMessage.self, from: data) {
            await handleMessage(message)
            return true
        }
        return false
    }

    private func expireDiscoveryProbe(_ id: ID) async {
        guard negotiationProbeID == id, let pending = removePendingRequest(id: id) else { return }
        negotiationProbeID = nil
        modernDeliveryTasks.removeValue(forKey: id)?.cancel()
        pending.resume(throwing: DiscoveryProbeTimeout())
        await sendModernCancellation(id, reason: "Discovery timed out")
    }

    private func handleRemoteCancellation(_ id: ID) async {
        if let pending = removePendingRequest(id: id) {
            modernDeliveryTasks.removeValue(forKey: id)?.cancel()
            pending.resume(throwing: CancellationError())
        }
        await stopSubscription(id, reason: nil, notifyServer: false)
    }

    private func failAllPending(with error: Swift.Error) {
        let pending = pendingRequests
        let subscriptions = modernSubscriptions
        let deliveryTasks = modernDeliveryTasks
        pendingRequests.removeAll(keepingCapacity: true)
        modernSubscriptions.removeAll(keepingCapacity: true)
        modernDeliveryTasks.removeAll(keepingCapacity: true)
        negotiationProbeID = nil
        connectionInfo = nil
        for request in pending.values {
            request.resume(throwing: error)
        }
        for task in deliveryTasks.values {
            task.cancel()
        }
        for subscription in subscriptions.values {
            subscription.deliveryTask?.cancel()
            subscription.acknowledgement?.resume(throwing: error)
            subscription.continuation.finish(throwing: error)
        }
    }

    func makeRequestMetadata() throws -> RequestMetadata {
        try RequestMetadata(
            clientCapabilities: try capabilitySet(from: capabilities),
            clientInfo: ImplementationInfo(
                name: clientInfo.name,
                version: clientInfo.version,
                title: clientInfo.title,
                description: clientInfo.description,
                websiteUrl: clientInfo.websiteUrl,
                icons: clientInfo.icons
            )
        )
    }

    func modernParameters<T: Codable>(
        from parameters: T,
        metadata: RequestMetadata
    ) throws -> Value {
        guard case .object(var fields) = try Value(parameters) else {
            throw MCPError.invalidParams("Modern request parameters must be an object")
        }
        fields["_meta"] = try Value(metadata)
        return .object(fields)
    }

    func decodeModernEnvelope(_ value: Value) throws -> ResultEnvelope {
        try decode(ResultEnvelope.self, from: value)
    }

    func decode<T: Decodable>(_ type: T.Type, from value: Value) throws -> T {
        try decoder.decode(type, from: encoder.encode(value))
    }

    func capabilitySet<T: Codable>(from capabilities: T) throws -> CapabilitySet {
        guard case .object(let fields) = try Value(capabilities) else {
            throw MCPError.internalError("Capabilities must encode as an object")
        }
        return CapabilitySet(fields)
    }

    func implementationInfo(from info: Server.Info) -> ImplementationInfo {
        ImplementationInfo(
            name: info.name,
            version: info.version,
            title: info.title,
            description: info.description,
            websiteUrl: info.websiteUrl,
            icons: info.icons
        )
    }

    private static func isRecognizedModernError(_ error: MCPError) -> Bool {
        error.code == -32020 || error.code == -32021 || error.code == -32022
    }
}

private struct DiscoveryProbeTimeout: Swift.Error, Sendable {}
