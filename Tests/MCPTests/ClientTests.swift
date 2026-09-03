import Foundation
import Testing

@testable import MCP

@Suite("Client Tests", .timeLimit(.minutes(1)))
struct ClientTests {
    @discardableResult
    private func connectWithMockServer(
        _ client: Client,
        transport: MockTransport
    ) async throws -> Initialize.Result {
        let responseTask = Task {
            try await transport.queueInitializeResponse()
        }

        do {
            let result = try await client.connect(transport: transport)
            try await responseTask.value
            return result
        } catch {
            responseTask.cancel()
            throw error
        }
    }

    @Test("Client connect and disconnect")
    func testClientConnectAndDisconnect() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        #expect(await transport.isConnected == false)

        let result = try await connectWithMockServer(client, transport: transport)
        #expect(await transport.isConnected == true)
        #expect(result.protocolVersion == Version.latest)
        await client.disconnect()
        #expect(await transport.isConnected == false)
    }

    @Test(
        "Ping request",
        .timeLimit(.minutes(1))
    )
    func testClientPing() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        let result = try await connectWithMockServer(client, transport: transport)
        #expect(result.protocolVersion == Version.latest)
        #expect(result.serverInfo.name == "TestServer")
        #expect(result.serverInfo.version == "1.0")

        let pingTask = Task {
            try await client.ping()
        }

        let pingData = try await transport.waitForSentData(at: 2)
        let pingRequest = try JSONDecoder().decode(Request<Ping>.self, from: pingData)
        #expect(pingRequest.method == Ping.name)
        pingTask.cancel()

        await client.disconnect()
        _ = await pingTask.result
    }

    @Test("Connection failure handling")
    func testClientConnectionFailure() async {
        let transport = MockTransport()
        await transport.setFailConnect(true)
        let client = Client(name: "TestClient", version: "1.0")

        do {
            try await client.connect(transport: transport)
            #expect(Bool(false), "Expected connection to fail")
        } catch let error as MCPError {
            if case MCPError.transportError = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected transport error")
            }
        } catch {
            #expect(Bool(false), "Expected MCP.Error")
        }
    }

    @Test("Send failure handling")
    func testClientSendFailure() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await connectWithMockServer(client, transport: transport)

        // Now set the transport to fail sends
        await transport.setFailSend(true)

        do {
            try await client.ping()
            #expect(Bool(false), "Expected ping to fail")
        } catch let error as MCPError {
            if case MCPError.transportError = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected transport error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCP.Error")
        }

        await client.disconnect()
    }

    @Test("Strict configuration - capabilities check")
    func testStrictConfiguration() async throws {
        let transport = MockTransport()
        let config = Client.Configuration.strict
        let client = Client(name: "TestClient", version: "1.0", configuration: config)

        try await connectWithMockServer(client, transport: transport)

        do {
            _ = try await client.listPrompts()
            #expect(Bool(false), "Expected listPrompts to fail in strict mode")
        } catch let error as MCPError {
            if case MCPError.methodNotFound = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected methodNotFound error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCP.Error")
        }

        await client.disconnect()
    }

    @Test("Non-strict configuration - capabilities check")
    func testNonStrictConfiguration() async throws {
        let transport = MockTransport()
        let config = Client.Configuration.default
        let client = Client(name: "TestClient", version: "1.0", configuration: config)

        try await connectWithMockServer(client, transport: transport)

        let promptsTask = Task {
            try await client.listPrompts()
        }

        let requestData = try await transport.waitForSentData(at: 2)
        let request = try JSONDecoder().decode(Request<ListPrompts>.self, from: requestData)
        let errorResponse = Response<ListPrompts>(
            id: request.id,
            error: MCPError.methodNotFound("Test: Prompts capability not available")
        )
        try await transport.queue(response: errorResponse)

        do {
            _ = try await promptsTask.value
            #expect(Bool(false), "Expected listPrompts to fail in non-strict mode")
        } catch let error as MCPError {
            if case MCPError.methodNotFound = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected methodNotFound error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCP.Error")
        }

        await client.disconnect()
    }

    @Test("Batch request - success")
    func testBatchRequestSuccess() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await connectWithMockServer(client, transport: transport)

        let request1 = Ping.request()
        let request2 = Ping.request()
        nonisolated(unsafe) var resultTask1: Task<Ping.Result, Swift.Error>?
        nonisolated(unsafe) var resultTask2: Task<Ping.Result, Swift.Error>?

        try await client.withBatch { batch in
            resultTask1 = try await batch.addRequest(request1)
            resultTask2 = try await batch.addRequest(request2)
        }

        // Check if batch message was sent (after initialize and initialized notification)
        let sentMessages = await transport.sentMessages
        #expect(sentMessages.count == 3)  // Initialize request + Initialized notification + Batch

        guard let batchData = sentMessages.last?.data(using: .utf8) else {
            #expect(Bool(false), "Failed to get batch data")
            return
        }

        // Verify the sent batch contains the two requests
        let decoder = JSONDecoder()
        let sentRequests = try decoder.decode([AnyRequest].self, from: batchData)
        #expect(sentRequests.count == 2)
        #expect(sentRequests.first?.id == request1.id)
        #expect(sentRequests.first?.method == Ping.name)
        #expect(sentRequests.last?.id == request2.id)
        #expect(sentRequests.last?.method == Ping.name)

        // Prepare batch response
        let response1 = Response<Ping>(id: request1.id, result: .init())
        let response2 = Response<Ping>(id: request2.id, result: .init())
        let anyResponse1 = try AnyResponse(response1)
        let anyResponse2 = try AnyResponse(response2)

        // Queue the batch response
        try await transport.queue(batch: [anyResponse1, anyResponse2])

        // Wait for results and verify
        guard let task1 = resultTask1, let task2 = resultTask2 else {
            #expect(Bool(false), "Result tasks not created")
            return
        }

        _ = try await task1.value  // Should succeed
        _ = try await task2.value  // Should succeed

        #expect(Bool(true))  // Reaching here means success

        await client.disconnect()
    }

    @Test("Batch request - mixed success/error")
    func testBatchRequestMixed() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await connectWithMockServer(client, transport: transport)

        let request1 = Ping.request()  // Success
        let request2 = Ping.request()  // Error

        nonisolated(unsafe) var resultTasks: [Task<Ping.Result, Swift.Error>] = []

        try await client.withBatch { batch in
            resultTasks.append(try await batch.addRequest(request1))
            resultTasks.append(try await batch.addRequest(request2))
        }

        // Check if batch message was sent (after initialize and initialized notification)
        #expect(await transport.sentMessages.count == 3)  // Initialize request + Initialized notification + Batch

        // Prepare batch response (success for 1, error for 2)
        let response1 = Response<Ping>(id: request1.id, result: .init())
        let error = MCPError.internalError("Simulated batch error")
        let response2 = Response<Ping>(id: request2.id, error: error)
        let anyResponse1 = try AnyResponse(response1)
        let anyResponse2 = try AnyResponse(response2)

        // Queue the batch response
        try await transport.queue(batch: [anyResponse1, anyResponse2])

        // Wait for results and verify
        #expect(resultTasks.count == 2)
        guard resultTasks.count == 2 else {
            #expect(Bool(false), "Expected 2 result tasks")
            return
        }

        let task1 = resultTasks[0]
        let task2 = resultTasks[1]

        _ = try await task1.value  // Task 1 should succeed

        do {
            _ = try await task2.value  // Task 2 should fail
            #expect(Bool(false), "Task 2 should have thrown an error")
        } catch let mcpError as MCPError {
            if case .internalError(let message) = mcpError {
                #expect(message == "Simulated batch error")
            } else {
                #expect(Bool(false), "Expected internalError, got \(mcpError)")
            }
        } catch {
            #expect(Bool(false), "Expected MCPError, got \(error)")
        }

        await client.disconnect()
    }

    @Test("Batch request - empty")
    func testBatchRequestEmpty() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await connectWithMockServer(client, transport: transport)

        // Call withBatch but don't add any requests
        try await client.withBatch { _ in
            // No requests added
        }

        // Check that only initialize message and initialized notification were sent
        #expect(await transport.sentMessages.count == 2)  // Initialize request + Initialized notification

        await client.disconnect()
    }

    @Test("Notify method sends notifications")
    func testClientNotify() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await connectWithMockServer(client, transport: transport)

        // Create a test notification
        let notification = InitializedNotification.message()
        try await client.notify(notification)

        // Verify notification was sent (in addition to initialize and initialized notification)
        #expect(await transport.sentMessages.count == 3)  // Initialize request + Initialized notification + Custom notification

        if let sentMessage = await transport.sentMessages.last,
            let data = sentMessage.data(using: .utf8)
        {

            // Decode as Message<InitializedNotification>
            let decoder = JSONDecoder()
            do {
                let decodedNotification = try decoder.decode(
                    Message<InitializedNotification>.self, from: data)
                #expect(decodedNotification.method == InitializedNotification.name)
            } catch {
                #expect(Bool(false), "Failed to decode notification: \(error)")
            }
        } else {
            #expect(Bool(false), "No message was sent")
        }

        await client.disconnect()
    }

    @Test("Initialize sends initialized notification")
    func testClientInitializeNotification() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await connectWithMockServer(client, transport: transport)

        let sentMessages = await transport.sentMessages
        #expect(sentMessages.count == 2)
        let notificationData = try #require(sentMessages.last?.data(using: .utf8))
        let decodedNotification = try JSONDecoder().decode(
            Message<InitializedNotification>.self,
            from: notificationData
        )
        #expect(decodedNotification.method == InitializedNotification.name)

        await client.disconnect()
    }

    @Test("Race condition between send error and response")
    func testSendErrorResponseRace() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await connectWithMockServer(client, transport: transport)

        // Set up the transport to fail sends from the start
        await transport.setFailSend(true)

        // Create a ping request to get the ID
        let request = Ping.request()

        // Create a response for the request and queue it immediately
        let response = Response<Ping>(id: request.id, result: .init())
        let anyResponse = try AnyResponse(response)
        try await transport.queue(response: anyResponse)

        // Now attempt to send the request - this should fail due to send error
        // but the response handler might also try to process the queued response
        do {
            _ = try await client.ping()
            #expect(Bool(false), "Expected send to fail")
        } catch let error as MCPError {
            if case .transportError = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected transport error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCPError, got \(error)")
        }

        // Verify no continuation misuse occurred
        // (If it did, the test would have crashed)

        await client.disconnect()
    }

    @Test("Race condition between response and send error")
    func testResponseSendErrorRace() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await connectWithMockServer(client, transport: transport)

        // Create a ping request to get the ID
        let request = Ping.request()

        // Create a response for the request and queue it immediately
        let response = Response<Ping>(id: request.id, result: .init())
        let anyResponse = try AnyResponse(response)
        try await transport.queue(response: anyResponse)

        // Set up the transport to fail sends
        await transport.setFailSend(true)

        // Now attempt to send the request
        // The response might be processed before the send error occurs
        do {
            _ = try await client.ping()
            // In this case, the response handler won the race and the request succeeded
            #expect(Bool(true), "Response handler won the race - request succeeded")
        } catch let error as MCPError {
            if case .transportError = error {
                // In this case, the send error handler won the race
                #expect(Bool(true), "Send error handler won the race - request failed")
            } else {
                #expect(Bool(false), "Expected transport error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCPError, got \(error)")
        }

        // Verify no continuation misuse occurred
        // (If it did, the test would have crashed)

        await client.disconnect()
    }
}
