import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

@Suite("MCP 2026 Client", .timeLimit(.minutes(1)))
struct MCP26ClientTests {
    @Test("Modern discovery establishes a modern connection")
    func modernDiscovery() async throws {
        let transport = ScriptedClientTransport { data in
            let request = try JSONDecoder().decode(Request<ServerDiscover>.self, from: data)
            let result = DiscoverResult(
                supportedVersions: [Version.modern],
                capabilities: CapabilitySet(["tools": .object([:])]),
                instructions: "modern",
                cacheHint: try CacheHint(scope: .private, ttlMs: 1),
                metadata: ResultMetadata(
                    serverInfo: ImplementationInfo(name: "server", version: "1")
                )
            )
            return try JSONEncoder().encode(ServerDiscover.response(id: request.id, result: result))
        }
        let client = Client(name: "client", version: "1")

        let info = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .byteStream
        )

        #expect(info.era == .modern)
        #expect(info.protocolVersion == Version.modern)
        #expect(info.serverInfo?.name == "server")
        #expect(await transport.sentMethods == [ServerDiscover.name])
        await client.disconnect()
    }

    @Test("Unsupported modern discovery retries once with a fresh request ID")
    func supportedVersionRetry() async throws {
        let responder = DiscoveryRetryResponder()
        let transport = ScriptedClientTransport { data in
            try await responder.respond(to: data)
        }
        let client = Client(name: "client", version: "1")

        let info = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .byteStream
        )

        let ids = await transport.sentRequestIDs(for: ServerDiscover.name)
        #expect(info.era == .modern)
        #expect(ids.count == 2)
        #expect(ids[0] != ids[1])
        await client.disconnect()
    }

    @Test("Recognized modern error never falls back")
    func recognizedModernError() async {
        let transport = ScriptedClientTransport { data in
            let request = try JSONDecoder().decode(Request<ServerDiscover>.self, from: data)
            return try JSONEncoder().encode(
                ServerDiscover.response(id: request.id, error: .headerMismatch("bad header"))
            )
        }
        let client = Client(name: "client", version: "1")

        do {
            _ = try await client.connect(
                transport: transport,
                preference: .modernThenLegacy,
                delivery: .byteStream
            )
            Issue.record("Expected a modern error")
        } catch let error as MCPError {
            #expect(error.code == -32020)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await transport.sentMethods == [ServerDiscover.name])
    }

    @Test("Unknown JSON-RPC error falls back on the same connection")
    func legacyFallback() async throws {
        let transport = ScriptedClientTransport { data in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                let method = fields["method"]?.stringValue,
                let idValue = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(idValue))
            if method == ServerDiscover.name {
                return try JSONEncoder().encode(
                    AnyMethod.response(id: id, error: .methodNotFound("legacy"))
                )
            }
            if method == Initialize.name {
                return try JSONEncoder().encode(
                    Initialize.response(
                        id: id,
                        result: .init(
                            protocolVersion: Version.latest,
                            capabilities: .init(),
                            serverInfo: .init(name: "legacy", version: "1")
                        )
                    )
                )
            }
            return nil
        }
        let client = Client(name: "client", version: "1")

        let info = try await client.connect(
            transport: transport,
            preference: .modernThenLegacy,
            delivery: .byteStream
        )

        #expect(info.era == .legacy)
        #expect(info.serverInfo?.name == "legacy")
        #expect(await transport.sentMethods.prefix(2) == [ServerDiscover.name, Initialize.name])
        #expect(await transport.connectCount == 1)
        await client.disconnect()
    }

    @Test("Discovery timeout falls back without reconnecting")
    func timeoutFallback() async throws {
        let transport = ScriptedClientTransport { data in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                fields["method"]?.stringValue == Initialize.name,
                let idValue = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(idValue))
            return try JSONEncoder().encode(
                Initialize.response(
                    id: id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "legacy", version: "1")
                    )
                )
            )
        }
        let client = Client(
            name: "client",
            version: "1",
            configuration: .init(discoveryProbeTimeout: 0.02)
        )

        let info = try await client.connect(
            transport: transport,
            preference: .modernThenLegacy,
            delivery: .byteStream
        )

        #expect(info.era == .legacy)
        #expect(await transport.connectCount == 1)
        await client.disconnect()
    }

    @Test("Modern-only timeout fails without initialize")
    func modernOnlyTimeout() async {
        let transport = ScriptedClientTransport { _ in nil }
        let client = Client(
            name: "client",
            version: "1",
            configuration: .init(discoveryProbeTimeout: 0.02)
        )

        do {
            _ = try await client.connect(
                transport: transport,
                preference: .modernOnly,
                delivery: .byteStream
            )
            Issue.record("Expected discovery timeout")
        } catch let error as MCPError {
            #expect(error.code == -32023)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let methods = await transport.sentMethods
        #expect(!methods.contains(Initialize.name))
    }

    @Test("Closed discovery stream does not fall back")
    func closedDiscoveryStream() async {
        let transport = ScriptedClientTransport { _ in nil }
        let client = Client(name: "client", version: "1")
        let connection = Task {
            try await client.connect(
                transport: transport,
                preference: .modernThenLegacy,
                delivery: .byteStream
            )
        }
        while await transport.sentMethods.isEmpty {
            await Task.yield()
        }
        await transport.finishReceiving()

        do {
            _ = try await connection.value
            Issue.record("Expected a closed connection")
        } catch let error as MCPError {
            #expect(error.code == -32000)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let methods = await transport.sentMethods
        #expect(!methods.contains(Initialize.name))
    }

    @Test("Malformed discovery does not fall back")
    func malformedDiscovery() async {
        let transport = ScriptedClientTransport { _ in Data("not-json".utf8) }
        let client = Client(name: "client", version: "1")

        do {
            _ = try await client.connect(
                transport: transport,
                preference: .modernThenLegacy,
                delivery: .byteStream
            )
            Issue.record("Expected malformed discovery to fail")
        } catch is ProtocolCoreError {
            #expect(await transport.sentMethods == [ServerDiscover.name])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("HTTP delivery rejects a raw transport before connect")
    func rawTransportCannotClaimHTTPDelivery() async {
        let transport = ScriptedClientTransport { _ in nil }
        let client = Client(name: "client", version: "1")

        do {
            _ = try await client.connect(
                transport: transport,
                preference: .modernOnly,
                delivery: .http
            )
            Issue.record("Expected delivery validation to fail")
        } catch let error as MCPError {
            #expect(error.code == -32023)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await transport.connectCount == 0)
        #expect(await transport.sentMethods.isEmpty)
    }

    @Test("A second connect cannot replace the active connection")
    func activeConnectionIsNotReplaced() async throws {
        let first = ScriptedClientTransport { data in
            let request = try JSONDecoder().decode(Request<ServerDiscover>.self, from: data)
            return try Self.discoveryResponse(id: request.id)
        }
        let second = ScriptedClientTransport { _ in nil }
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: first,
            preference: .modernOnly,
            delivery: .byteStream
        )

        do {
            _ = try await client.connect(
                transport: second,
                preference: .modernOnly,
                delivery: .byteStream
            )
            Issue.record("Expected the second connect to fail")
        } catch let error as MCPError {
            #expect(error.code == -32603)
        }
        #expect(await first.connectCount == 1)
        #expect(await second.connectCount == 0)
        await client.disconnect()
    }

    @Test("Local cancellation stops the outbound delivery task")
    func localCancellationStopsDelivery() async throws {
        let transport = InspectableHTTPClientTransport(behavior: .hanging)
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .http
        )
        let call = Task {
            try await client.sendModern(ModernEcho.request(.init(value: "cancel")))
        }
        while !(await transport.started(ModernEcho.name)) { await Task.yield() }

        call.cancel()

        do {
            _ = try await call.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        while !(await transport.cancelled(ModernEcho.name)) { await Task.yield() }
        #expect(await client.modernDeliveryTasks.isEmpty)
        await client.disconnect()
    }

    @Test("Remote cancellation stops the outbound delivery task")
    func remoteCancellationStopsDelivery() async throws {
        let transport = InspectableHTTPClientTransport(behavior: .remoteCancellation)
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .http
        )

        do {
            _ = try await client.sendModern(ModernEcho.request(.init(value: "cancel")))
            Issue.record("Expected remote cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        while !(await transport.cancelled(ModernEcho.name)) { await Task.yield() }
        #expect(await client.modernDeliveryTasks.isEmpty)
        await client.disconnect()
    }

    @Test("Malformed input stops the outbound delivery task")
    func malformedInputStopsDelivery() async throws {
        let transport = InspectableHTTPClientTransport(behavior: .malformed)
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .http
        )

        do {
            _ = try await client.sendModern(ModernEcho.request(.init(value: "malformed")))
            Issue.record("Expected malformed input failure")
        } catch is ProtocolCoreError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        while !(await transport.cancelled(ModernEcho.name)) { await Task.yield() }
        #expect(await client.modernDeliveryTasks.isEmpty)
        await client.disconnect()
    }

    @Test("Send failure releases pending and delivery ownership")
    func sendFailureReleasesDelivery() async throws {
        let transport = InspectableHTTPClientTransport(behavior: .sendFailure)
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .http
        )

        do {
            _ = try await client.sendModern(ModernEcho.request(.init(value: "failure")))
            Issue.record("Expected send failure")
        } catch is TestDeliveryError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await client.pendingRequests.isEmpty)
        #expect(await client.modernDeliveryTasks.isEmpty)
        await client.disconnect()
    }

    @Test("Subscription cancellation stops its outbound delivery task")
    func subscriptionCancellationStopsDelivery() async throws {
        let transport = InspectableHTTPClientTransport(behavior: .hanging)
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .http
        )
        let subscription = try await client.listen(
            notifications: SubscriptionFilter(toolsListChanged: true)
        )

        await client.cancelSubscription(subscription.id)

        while !(await transport.cancelled(SubscriptionsListenRequest.name)) {
            await Task.yield()
        }
        #expect(await client.modernSubscriptions.isEmpty)
        await client.disconnect()
    }

    @Test("Modern result exposes metadata and cache hint without storage")
    func modernResultMetadata() async throws {
        let transport = ScriptedClientTransport { data in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                let method = fields["method"]?.stringValue,
                let idValue = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(idValue))
            if method == ServerDiscover.name {
                let result = DiscoverResult(
                    supportedVersions: [Version.modern],
                    cacheHint: try CacheHint(scope: .private, ttlMs: 0)
                )
                return try JSONEncoder().encode(
                    ServerDiscover.response(id: id, result: result)
                )
            }
            let result: Value = .object([
                "resultType": .string(ResultType.complete.rawValue),
                "value": .string("ok"),
                "cacheScope": .string(CacheScope.private.rawValue),
                "ttlMs": .int(25),
                "_meta": try Value(
                    ResultMetadata(
                        serverInfo: ImplementationInfo(name: "server", version: "2")
                    )
                ),
            ])
            return try JSONEncoder().encode(Response<AnyMethod>(id: id, result: result))
        }
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .byteStream
        )

        let result = try await client.sendModern(ModernEcho.request(.init(value: "input")))

        #expect(result.value.value == "ok")
        #expect(result.metadata?.serverInfo?.version == "2")
        #expect(result.cacheHint?.ttlMs == 25)
        await client.disconnect()
    }

    @Test("Configuration decodes old JSON with bounded defaults")
    func oldConfigurationDefaults() throws {
        let configuration = try JSONDecoder().decode(
            Client.Configuration.self,
            from: Data(#"{"strict":true}"#.utf8)
        )

        #expect(configuration.strict)
        #expect(configuration.discoveryProbeTimeout == 10)
        #expect(configuration.maxToolListPages == 64)
        #expect(configuration.maxRounds == 10)
    }

    @Test("Tool headers refresh once with fresh request IDs")
    func toolHeaderRefresh() async throws {
        let transport = ScriptedHTTPClientTransport()
        let client = Client(name: "client", version: "1")
        await transport.setResponder { data, headers, invocation in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                let method = fields["method"]?.stringValue,
                let idValue = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(idValue))
            switch method {
            case ServerDiscover.name:
                return try Self.discoveryResponse(id: id)
            case ListTools.name:
                let schema: Value = .object([
                    "type": .string("object"),
                    "properties": .object([
                        "tenant": .object([
                            "type": .string("string"),
                            "x-mcp-header": .string("Tenant"),
                        ])
                    ]),
                ])
                let result = Self.completeValue(
                    fields: try Value(
                        ListTools.Result(
                            tools: [Tool(name: "lookup", description: nil, inputSchema: schema)]
                        )
                    )
                )
                return try JSONEncoder().encode(Response<AnyMethod>(id: id, result: result))
            case CallTool.name:
                #expect(headers[HTTPHeaderName.name] == "lookup")
                #expect(headers["Mcp-Param-Tenant"] == "acme")
                if invocation == 3 {
                    return try JSONEncoder().encode(
                        AnyMethod.response(id: id, error: .headerMismatch("refresh"))
                    )
                }
                let result = Self.completeValue(
                    fields: try Value(CallTool.Result(content: []))
                )
                return try JSONEncoder().encode(Response<AnyMethod>(id: id, result: result))
            default:
                return nil
            }
        }

        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .http
        )
        _ = try await client.sendModern(
            CallTool.request(.init(name: "lookup", arguments: ["tenant": "acme"]))
        )

        let requests = await transport.requests
        #expect(
            requests.map(\.method) == [
                ServerDiscover.name,
                ListTools.name,
                CallTool.name,
                ListTools.name,
                CallTool.name,
            ])
        let callIDs = requests.filter { $0.method == CallTool.name }.map(\.id)
        #expect(callIDs.count == 2)
        #expect(callIDs[0] != callIDs[1])
        await client.disconnect()
    }

    @Test("Byte-stream tool calls do not perform HTTP header discovery")
    func byteStreamToolCallSkipsHeaderDiscovery() async throws {
        let transport = ScriptedClientTransport { data in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                let method = fields["method"]?.stringValue,
                let rawID = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(rawID))
            if method == ServerDiscover.name { return try Self.discoveryResponse(id: id) }
            guard method == CallTool.name else { return nil }
            let result = Self.completeValue(fields: try Value(CallTool.Result(content: [])))
            return try JSONEncoder().encode(Response<AnyMethod>(id: id, result: result))
        }
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .byteStream
        )

        _ = try await client.sendModern(CallTool.request(.init(name: "lookup")))

        #expect(await transport.sentMethods == [ServerDiscover.name, CallTool.name])
        await client.disconnect()
    }

    @Test("Tool pagination cursor cycle fails before tools/call")
    func toolCursorCycle() async throws {
        let transport = ScriptedHTTPClientTransport()
        await transport.setResponder { data, _, _ in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                let method = fields["method"]?.stringValue,
                let idValue = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(idValue))
            if method == ServerDiscover.name { return try Self.discoveryResponse(id: id) }
            if method == ListTools.name {
                let result = Self.completeValue(
                    fields: try Value(ListTools.Result(tools: [], nextCursor: "same"))
                )
                return try JSONEncoder().encode(Response<AnyMethod>(id: id, result: result))
            }
            return nil
        }
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .http
        )

        do {
            _ = try await client.sendModern(CallTool.request(.init(name: "missing")))
            Issue.record("Expected a cursor-cycle failure")
        } catch let error as MCPError {
            #expect(error.code == -32602)
        }
        let methods = await transport.requests.map(\.method)
        #expect(!methods.contains(CallTool.name))
        await client.disconnect()
    }

    @Test("Tool discovery enforces its page bound")
    func toolPageBound() async throws {
        let transport = ScriptedHTTPClientTransport()
        await transport.setResponder { data, _, _ in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                let method = fields["method"]?.stringValue,
                let rawID = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(rawID))
            if method == ServerDiscover.name { return try Self.discoveryResponse(id: id) }
            let result = Self.completeValue(
                fields: try Value(ListTools.Result(tools: [], nextCursor: "more"))
            )
            return try JSONEncoder().encode(Response<AnyMethod>(id: id, result: result))
        }
        let client = Client(
            name: "client",
            version: "1",
            configuration: .init(maxToolListPages: 1)
        )
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .http
        )

        do {
            _ = try await client.sendModern(CallTool.request(.init(name: "missing")))
            Issue.record("Expected the tool page bound to fail")
        } catch let error as MCPError {
            #expect(error.code == -32024)
        }
        let methods = await transport.requests.map(\.method)
        #expect(!methods.contains(CallTool.name))
        await client.disconnect()
    }

    @Test("MRTR echoes opaque state and resolves multiple inputs")
    func multiRoundInput() async throws {
        let inspection = MRTRInspection()
        let transport = ScriptedClientTransport { data in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                let method = fields["method"]?.stringValue,
                let idValue = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(idValue))
            if method == ServerDiscover.name { return try Self.discoveryResponse(id: id) }
            if method == ReadResource.name,
                case .object(let parameters) = fields["params"]
            {
                if parameters["requestState"] == nil {
                    let input = InputRequiredResult(
                        inputRequests: [
                            "second": InputRequest(method: .rootsList),
                            "first": InputRequest(method: .rootsList),
                        ],
                        requestState: "opaque-state"
                    )
                    return try JSONEncoder().encode(
                        Response<AnyMethod>(id: id, result: try Value(input))
                    )
                }
                await inspection.record(parameters)
                let complete = Self.completeValue(
                    fields: try Value(ReadResource.Result(contents: []))
                )
                return try JSONEncoder().encode(Response<AnyMethod>(id: id, result: complete))
            }
            return nil
        }
        let client = Client(
            name: "client",
            version: "1",
            capabilities: .init(roots: .init())
        )
        await client.withRootsHandler { [Root(uri: "file:///workspace", name: "workspace")] }
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .byteStream
        )

        _ = try await client.sendModern(ReadResource.request(.init(uri: "file:///item")))

        let parameters = await inspection.parameters
        #expect(parameters?["requestState"]?.stringValue == "opaque-state")
        #expect(parameters?["inputResponses"]?.objectValue?.keys.sorted() == ["first", "second"])
        let ids = await transport.sentRequestIDs(for: ReadResource.name)
        #expect(ids.count == 2)
        #expect(ids[0] != ids[1])
        await client.disconnect()
    }

    @Test("MRTR stops at the configured request bound")
    func roundBound() async throws {
        let transport = ScriptedClientTransport { data in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                let method = fields["method"]?.stringValue,
                let idValue = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(idValue))
            if method == ServerDiscover.name { return try Self.discoveryResponse(id: id) }
            if method == ReadResource.name {
                return try JSONEncoder().encode(
                    Response<AnyMethod>(
                        id: id,
                        result: try Value(InputRequiredResult(requestState: "again"))
                    )
                )
            }
            return nil
        }
        let client = Client(
            name: "client",
            version: "1",
            configuration: .init(maxRounds: 1)
        )
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .byteStream
        )

        do {
            _ = try await client.sendModern(ReadResource.request(.init(uri: "file:///item")))
            Issue.record("Expected a round bound failure")
        } catch let error as MCPError {
            #expect(error.code == -32024)
        }
        await client.disconnect()
    }

    @Test("MRTR rejects input without the declared client capability")
    func missingInputCapability() async throws {
        let transport = ScriptedClientTransport { data in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                let method = fields["method"]?.stringValue,
                let rawID = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(rawID))
            if method == ServerDiscover.name { return try Self.discoveryResponse(id: id) }
            let input = InputRequiredResult(
                inputRequests: ["roots": InputRequest(method: .rootsList)]
            )
            return try JSONEncoder().encode(
                Response<AnyMethod>(id: id, result: try Value(input))
            )
        }
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .byteStream
        )

        do {
            _ = try await client.sendModern(ReadResource.request(.init(uri: "file:///item")))
            Issue.record("Expected the missing capability to fail")
        } catch let error as MCPError {
            #expect(error.code == -32021)
        }
        await client.disconnect()
    }

    @Test("Subscription acknowledges before events and sends cancellation")
    func subscriptionLifecycle() async throws {
        let transport = ScriptedClientTransport { data in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                let method = fields["method"]?.stringValue,
                let idValue = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(idValue))
            if method == ServerDiscover.name { return try Self.discoveryResponse(id: id) }
            if method == SubscriptionsListenRequest.name {
                let acknowledgement = SubscriptionsAcknowledgedNotification.message(
                    .init(
                        subscriptionID: id,
                        notifications: SubscriptionFilter(toolsListChanged: true)
                    )
                )
                return try JSONEncoder().encode(acknowledgement)
            }
            return nil
        }
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .byteStream
        )

        let subscription = try await client.listen(
            notifications: SubscriptionFilter(toolsListChanged: true)
        )
        let rejectedNotification = Message<AnyNotification>(
            method: PromptListChangedNotification.name,
            params: .object([
                "_meta": try Value(NotificationMetadata(subscriptionID: subscription.id))
            ])
        )
        let notification = Message<AnyNotification>(
            method: ToolListChangedNotification.name,
            params: .object([
                "_meta": try Value(NotificationMetadata(subscriptionID: subscription.id))
            ])
        )
        try await transport.queue(data: JSONEncoder().encode(rejectedNotification))
        try await transport.queue(data: JSONEncoder().encode(notification))

        var iterator = subscription.events.makeAsyncIterator()
        let event = try await iterator.next()
        #expect(event?.method == ToolListChangedNotification.name)
        await client.cancelSubscription(subscription.id, reason: "done")
        #expect(await transport.sentMethods.last == CancelledNotification.name)
        await client.disconnect()
    }

    @Test("Disconnect terminates active subscriptions")
    func subscriptionDisconnectCleanup() async throws {
        let transport = ScriptedClientTransport { data in
            let raw = try JSONDecoder().decode(Value.self, from: data)
            guard case .object(let fields) = raw,
                let method = fields["method"]?.stringValue,
                let rawID = fields["id"]
            else { return nil }
            let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(rawID))
            if method == ServerDiscover.name { return try Self.discoveryResponse(id: id) }
            guard method == SubscriptionsListenRequest.name else { return nil }
            return try JSONEncoder().encode(
                SubscriptionsAcknowledgedNotification.message(
                    .init(
                        subscriptionID: id,
                        notifications: SubscriptionFilter(toolsListChanged: true)
                    )
                )
            )
        }
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: transport,
            preference: .modernOnly,
            delivery: .byteStream
        )
        let subscription = try await client.listen(
            notifications: SubscriptionFilter(toolsListChanged: true)
        )
        let nextEvent = Task {
            var iterator = subscription.events.makeAsyncIterator()
            return try await iterator.next()
        }

        await client.disconnect()
        do {
            _ = try await nextEvent.value
            Issue.record("Expected disconnect to fail the subscription stream")
        } catch let error as MCPError {
            #expect(error.code == -32000)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Client and Server exchange modern requests in memory")
    func inMemoryClientServer() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "server", version: "1")
        await server.withMethodHandler(ModernEcho.self) { parameters in
            ModernEcho.Result(value: parameters.value)
        }
        try await server.start(transport: pair.server)
        let client = Client(name: "client", version: "1")

        let info = try await client.connect(
            transport: pair.client,
            preference: .modernOnly,
            delivery: .byteStream
        )
        let result = try await client.sendModern(ModernEcho.request(.init(value: "direct")))

        #expect(info.era == .modern)
        #expect(result.value.value == "direct")
        await client.disconnect()
        await server.stop()
    }

    @Test("Client and Server compose MRTR, progress, logging, and subscriptions")
    func inMemoryModernOrchestration() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let events = ClientEventInspection()
        let server = Server(
            name: "server",
            version: "1",
            capabilities: .init(
                logging: .init(),
                resources: .init(),
                tools: .init(listChanged: true)
            )
        )
        await server.withMethodHandler(ModernEcho.self) { parameters in
            try await server.notify(
                ProgressNotification.message(
                    .init(progressToken: .string("progress"), progress: 1)
                )
            )
            try await server.log(level: .error, data: .string("visible"))
            return ModernEcho.Result(value: parameters.value)
        }
        await server.withMethodHandler(ReadResource.self) {
            _ async throws -> Server.ModernHandlerResult<ReadResource.Result> in
            if Server.currentHandlerContext?.requestState == nil {
                return .inputRequired(
                    InputRequiredResult(
                        inputRequests: ["roots": InputRequest(method: .rootsList)],
                        requestState: "opaque"
                    )
                )
            }
            return .complete(.init(contents: []))
        }
        try await server.start(transport: pair.server)
        let client = Client(
            name: "client",
            version: "1",
            capabilities: .init(roots: .init())
        )
        await client.withRootsHandler { [Root(uri: "file:///workspace")] }
        await client.onNotification(ProgressNotification.self) { _ in
            await events.recordProgress()
        }
        await client.onNotification(LogMessageNotification.self) { message in
            await events.recordLog(message.params.level)
        }
        _ = try await client.connect(
            transport: pair.client,
            preference: .modernOnly,
            delivery: .byteStream
        )
        let metadata = try RequestMetadata(
            logLevel: LogLevel.warning.rawValue,
            progressToken: .string("progress")
        )

        _ = try await client.sendModern(
            ModernEcho.request(.init(value: "events")),
            metadata: metadata
        )
        let resource = try await client.sendModern(
            ReadResource.request(.init(uri: "file:///item"))
        )
        let subscription = try await client.listen(
            notifications: SubscriptionFilter(toolsListChanged: true)
        )
        try await server.notify(ToolListChangedNotification.message())
        var iterator = subscription.events.makeAsyncIterator()
        let event = try await iterator.next()

        #expect(await events.progressCount == 1)
        #expect(await events.logLevels == [.error])
        #expect(resource.value.contents.isEmpty)
        #expect(event?.method == ToolListChangedNotification.name)
        await client.cancelSubscription(subscription.id)
        await client.disconnect()
        await server.stop()
    }

    @Test("Concurrent calls replace colliding caller IDs with isolated attempt IDs")
    func concurrentCallerIDIsolation() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "server", version: "1")
        await server.withMethodHandler(ModernEcho.self) { parameters in
            if parameters.value == "slow" {
                try await Task.sleep(for: .milliseconds(20))
            }
            return ModernEcho.Result(value: parameters.value)
        }
        try await server.start(transport: pair.server)
        let client = Client(name: "client", version: "1")
        _ = try await client.connect(
            transport: pair.client,
            preference: .modernOnly,
            delivery: .byteStream
        )

        async let slow = client.sendModern(
            ModernEcho.request(id: 7, .init(value: "slow"))
        )
        async let fast = client.sendModern(
            ModernEcho.request(id: 7, .init(value: "fast"))
        )
        let values = try await [slow.value.value, fast.value.value]

        #expect(values == ["slow", "fast"])
        await client.disconnect()
        await server.stop()
    }

    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        @Test("Client and Server exchange modern requests over stdio")
        func stdioClientServer() async throws {
            let (clientInput, serverOutput) = try FileDescriptor.pipe()
            let (serverInput, clientOutput) = try FileDescriptor.pipe()
            let clientTransport = StdioTransport(input: clientInput, output: clientOutput)
            let serverTransport = StdioTransport(input: serverInput, output: serverOutput)
            let server = Server(name: "server", version: "1")
            await server.withMethodHandler(ModernEcho.self) { parameters in
                ModernEcho.Result(value: parameters.value)
            }
            try await server.start(transport: serverTransport)
            let client = Client(name: "client", version: "1")

            let info = try await client.connect(
                transport: clientTransport,
                preference: .modernOnly,
                delivery: .byteStream
            )
            let result = try await client.sendModern(
                ModernEcho.request(.init(value: "stdio"))
            )

            #expect(info.era == .modern)
            #expect(result.value.value == "stdio")
            await client.disconnect()
            await server.stop()
            try clientInput.close()
            try clientOutput.close()
            try serverInput.close()
            try serverOutput.close()
        }
    #endif

    @Test("HTTP Client uses the stateless Server transport")
    func statelessHTTPClientServer() async throws {
        let schemaProbe = HeaderSchemaProbe()
        let events = ClientEventInspection()
        let serverTransport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "server",
            version: "1",
            capabilities: .init(logging: .init(), tools: .init())
        )
        await server.withMethodHandler(ModernEcho.self) { parameters in
            ModernEcho.Result(value: parameters.value)
        }
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [await schemaProbe.nextTool()])
        }
        await server.withMethodHandler(CallTool.self) {
            _ async throws -> Server.ModernHandlerResult<CallTool.Result> in
            try await server.notify(
                ProgressNotification.message(
                    .init(progressToken: .string("http-progress"), progress: 1)
                )
            )
            try await server.log(level: .error, data: .string("http-log"))
            return .complete(.init(content: []))
        }
        try await server.start(transport: serverTransport)
        await MCP26URLProtocol.storage.setTransport(serverTransport)
        defer {
            Task { await MCP26URLProtocol.storage.setTransport(nil) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCP26URLProtocol.self]
        let clientTransport = HTTPClientTransport(
            endpoint: URL(string: "https://mcp26.local/mcp")!,
            configuration: configuration,
            streaming: false
        )
        let client = Client(name: "client", version: "1")
        await client.onNotification(ProgressNotification.self) { _ in
            await events.recordProgress()
        }
        await client.onNotification(LogMessageNotification.self) { message in
            await events.recordLog(message.params.level)
        }

        let info = try await client.connect(
            transport: clientTransport,
            preference: .modernOnly,
            delivery: .http
        )
        let result = try await client.sendModern(
            ModernEcho.request(.init(value: "http"))
        )

        #expect(info.era == .modern)
        #expect(result.value.value == "http")
        let toolResult = try await client.sendModern(
            CallTool.request(
                .init(
                    name: "header-tool",
                    arguments: ["old": "value", "new": "value"]
                )
            ),
            metadata: try RequestMetadata(
                logLevel: LogLevel.warning.rawValue,
                progressToken: .string("http-progress")
            )
        )
        #expect(toolResult.value.content.isEmpty)
        #expect(await schemaProbe.callCount == 4)
        #expect(await events.progressCount == 1)
        #expect(await events.logLevels == [.error])
        do {
            _ = try await client.sendModern(UnregisteredModernMethod.request())
            Issue.record("Expected an HTTP JSON-RPC method-not-found error")
        } catch let error as MCPError {
            #expect(error.code == -32601)
        }
        await client.disconnect()
        await server.stop()
        await MCP26URLProtocol.storage.setTransport(nil)
    }

    private static func discoveryResponse(id: ID) throws -> Data {
        let result = DiscoverResult(
            supportedVersions: [Version.modern],
            cacheHint: try CacheHint(scope: .private, ttlMs: 0)
        )
        return try JSONEncoder().encode(ServerDiscover.response(id: id, result: result))
    }

    private static func completeValue(fields: Value) -> Value {
        guard case .object(var object) = fields else { return fields }
        object["resultType"] = .string(ResultType.complete.rawValue)
        return .object(object)
    }
}

private enum ModernEcho: MCP.Method {
    static let name = "test/echo"

    struct Parameters: Hashable, Codable, Sendable {
        let value: String
    }

    struct Result: Hashable, Codable, Sendable {
        let value: String
    }
}

private enum UnregisteredModernMethod: MCP.Method {
    static let name = "test/unregistered"
}

private actor ScriptedClientTransport: Transport {
    nonisolated let logger = Logger(label: "mcp.tests.modern-client")
    private let responder: @Sendable (Data) async throws -> Data?
    private var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
    private var queued: [Data] = []
    private(set) var sentMethods: [String] = []
    private var requestIDsByMethod: [String: [ID]] = [:]
    private(set) var connectCount = 0

    init(responder: @escaping @Sendable (Data) async throws -> Data?) {
        self.responder = responder
    }

    func connect() async throws {
        connectCount += 1
    }

    func disconnect() async {
        continuation?.finish()
        continuation = nil
    }

    func send(_ data: Data) async throws {
        if let raw = try? JSONDecoder().decode(Value.self, from: data),
            case .object(let fields) = raw,
            let method = fields["method"]?.stringValue
        {
            sentMethods.append(method)
            if let rawID = fields["id"],
                let encoded = try? JSONEncoder().encode(rawID),
                let id = try? JSONDecoder().decode(ID.self, from: encoded)
            {
                requestIDsByMethod[method, default: []].append(id)
            }
        }
        guard let response = try await responder(data) else { return }
        if let continuation {
            continuation.yield(response)
        } else {
            queued.append(response)
        }
    }

    func sentRequestIDs(for method: String) -> [ID] {
        requestIDsByMethod[method] ?? []
    }

    func finishReceiving() {
        continuation?.finish()
        continuation = nil
    }

    func queue(data: Data) throws {
        if let continuation {
            continuation.yield(data)
        } else {
            queued.append(data)
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            for data in queued {
                continuation.yield(data)
            }
            queued.removeAll(keepingCapacity: true)
        }
    }
}

private actor DiscoveryRetryResponder {
    private var attempt = 0

    func respond(to data: Data) throws -> Data {
        attempt += 1
        let request = try JSONDecoder().decode(Request<ServerDiscover>.self, from: data)
        if attempt == 1 {
            return try JSONEncoder().encode(
                ServerDiscover.response(
                    id: request.id,
                    error: .unsupportedProtocolVersion(
                        requested: Version.modern,
                        supported: [Version.modern]
                    )
                )
            )
        }
        let result = DiscoverResult(
            supportedVersions: [Version.modern],
            cacheHint: try CacheHint(scope: .private, ttlMs: 0)
        )
        return try JSONEncoder().encode(ServerDiscover.response(id: request.id, result: result))
    }
}

private actor MRTRInspection {
    private(set) var parameters: [String: Value]?

    func record(_ parameters: [String: Value]) {
        self.parameters = parameters
    }
}

private actor ClientEventInspection {
    private(set) var progressCount = 0
    private(set) var logLevels: [LogLevel] = []

    func recordProgress() {
        progressCount += 1
    }

    func recordLog(_ level: LogLevel) {
        logLevels.append(level)
    }
}

private actor HeaderSchemaProbe {
    private(set) var callCount = 0

    func nextTool() -> Tool {
        callCount += 1
        let header = callCount == 1 ? "Old" : "New"
        let property = callCount == 1 ? "old" : "new"
        return Tool(
            name: "header-tool",
            description: nil,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    property: .object([
                        "type": .string("string"),
                        "x-mcp-header": .string(header),
                    ])
                ]),
            ])
        )
    }
}

private actor ScriptedHTTPClientTransport: HTTPRequestSendingTransport {
    struct RecordedRequest: Sendable {
        let id: ID
        let method: String
        let headers: [String: String]
    }

    nonisolated let logger = Logger(label: "mcp.tests.modern-http-client")
    private var responder: (@Sendable (Data, [String: String], Int) async throws -> Data?)?
    private var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
    private var queued: [Data] = []
    private(set) var requests: [RecordedRequest] = []

    func setResponder(
        _ responder: @escaping @Sendable (Data, [String: String], Int) async throws -> Data?
    ) {
        self.responder = responder
    }

    func connect() async throws {}

    func disconnect() async {
        continuation?.finish()
        continuation = nil
    }

    func send(_ data: Data) async throws {
        try await send(data, headers: [:])
    }

    package func send(_ data: Data, headers: [String: String]) async throws {
        let raw = try JSONDecoder().decode(Value.self, from: data)
        guard case .object(let fields) = raw,
            let method = fields["method"]?.stringValue,
            let rawID = fields["id"]
        else { return }
        let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(rawID))
        requests.append(RecordedRequest(id: id, method: method, headers: headers))
        guard let response = try await responder?(data, headers, requests.count) else { return }
        if let continuation {
            continuation.yield(response)
        } else {
            queued.append(response)
        }
    }

    package func updateNegotiatedProtocolVersion(_ version: String) {}

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            for data in queued {
                continuation.yield(data)
            }
            queued.removeAll(keepingCapacity: true)
        }
    }
}

private enum InspectableDeliveryBehavior: Sendable {
    case hanging
    case remoteCancellation
    case malformed
    case sendFailure
}

private struct TestDeliveryError: Swift.Error {}

private actor InspectableHTTPClientTransport: HTTPRequestSendingTransport {
    nonisolated let logger = Logger(label: "mcp.tests.inspectable-http-client")
    private let behavior: InspectableDeliveryBehavior
    private var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
    private var queued: [Data] = []
    private var startedMethods: Set<String> = []
    private var cancelledMethods: Set<String> = []

    init(behavior: InspectableDeliveryBehavior) {
        self.behavior = behavior
    }

    func connect() async throws {}

    func disconnect() async {
        continuation?.finish()
        continuation = nil
    }

    func send(_ data: Data) async throws {
        try await send(data, headers: [:])
    }

    package func send(_ data: Data, headers: [String: String]) async throws {
        let raw = try JSONDecoder().decode(Value.self, from: data)
        guard case .object(let fields) = raw,
            let method = fields["method"]?.stringValue,
            let rawID = fields["id"]
        else { return }
        let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(rawID))
        if method == ServerDiscover.name {
            let result = DiscoverResult(
                supportedVersions: [Version.modern],
                cacheHint: try CacheHint(scope: .private, ttlMs: 0)
            )
            yield(try JSONEncoder().encode(ServerDiscover.response(id: id, result: result)))
            return
        }
        if method == CancelledNotification.name { return }

        startedMethods.insert(method)
        if method == SubscriptionsListenRequest.name {
            let acknowledgement = SubscriptionsAcknowledgedNotification.message(
                .init(
                    subscriptionID: id,
                    notifications: SubscriptionFilter(toolsListChanged: true)
                )
            )
            yield(try JSONEncoder().encode(acknowledgement))
        } else {
            switch behavior {
            case .remoteCancellation:
                yield(
                    try JSONEncoder().encode(
                        CancelledNotification.message(.init(requestId: id, reason: "remote"))
                    )
                )
            case .malformed:
                yield(Data("not-json".utf8))
            case .sendFailure:
                throw TestDeliveryError()
            case .hanging:
                break
            }
        }

        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            cancelledMethods.insert(method)
            throw CancellationError()
        }
    }

    package func updateNegotiatedProtocolVersion(_ version: String) {}

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            for data in queued {
                continuation.yield(data)
            }
            queued.removeAll(keepingCapacity: true)
        }
    }

    func started(_ method: String) -> Bool {
        startedMethods.contains(method)
    }

    func cancelled(_ method: String) -> Bool {
        cancelledMethods.contains(method)
    }

    private func yield(_ data: Data) {
        if let continuation {
            continuation.yield(data)
        } else {
            queued.append(data)
        }
    }
}

private actor MCP26HTTPBridge {
    private var transport: StatelessHTTPServerTransport?

    func setTransport(_ transport: StatelessHTTPServerTransport?) {
        self.transport = transport
    }

    func respond(to request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        guard let transport, let url = request.url else {
            throw MCPError.connectionClosed
        }
        let response = await transport.handleRequest(
            HTTPRequest(
                method: request.httpMethod ?? "POST",
                headers: request.allHTTPHeaderFields ?? [:],
                body: request.mcp26Body,
                path: url.path
            )
        )
        guard
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )
        else {
            throw MCPError.transportError(URLError(.badServerResponse))
        }
        let body: Data
        if case .stream(let stream, _) = response {
            var streamed = Data()
            for try await chunk in stream {
                streamed.append(chunk)
            }
            body = streamed
        } else {
            body = response.bodyData ?? Data()
        }
        return (httpResponse, body)
    }
}

extension URLRequest {
    fileprivate var mcp26Body: Data? {
        if let httpBody { return httpBody }
        guard let httpBodyStream else { return nil }
        httpBodyStream.open()
        defer { httpBodyStream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while httpBodyStream.hasBytesAvailable {
            let count = httpBodyStream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private final class MCP26URLProtocol: URLProtocol, @unchecked Sendable {
    static let storage = MCP26HTTPBridge()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mcp26.local"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Task {
            do {
                let (response, data) = try await Self.storage.respond(to: request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
