import Foundation
import Testing

@testable import MCP

/// Generic extension support owned by the MCP module: lossless extension
/// capabilities in both eras, `connectionInfo` for legacy connections, and
/// mounted resource namespaces.
@Suite("Extension support", .timeLimit(.minutes(1)))
struct ExtensionSupportTests {
    enum Era: String, CaseIterable, Sendable {
        case legacy, modern
    }

    private static let extensionSettings: [String: Value] = [
        "io.example/feature": .object(["depth": .object(["enabled": .bool(true)])])
    ]

    private func connect(_ client: Client, to server: Server, era: Era) async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: pair.server)
        switch era {
        case .legacy:
            _ = try await client.connect(transport: pair.client)
        case .modern:
            _ = try await client.connect(
                transport: pair.client,
                preference: .modernOnly,
                delivery: .byteStream
            )
        }
    }

    @Test("Server extension and experimental capabilities reach the client", arguments: Era.allCases)
    func serverCapabilitiesRoundTrip(era: Era) async throws {
        let server = Server(
            name: "server",
            version: "1",
            capabilities: .init(
                resources: .init(),
                experimental: ["io.example/beta": .object(["mode": .string("on")])],
                extensions: Self.extensionSettings
            )
        )
        let client = Client(name: "client", version: "1")
        try await connect(client, to: server, era: era)

        let info = try #require(await client.connectionInfo)
        #expect(info.era == (era == .legacy ? .legacy : .modern))
        #expect(info.serverCapabilities.extensions == Self.extensionSettings)
        #expect(
            info.serverCapabilities.experimental
                == ["io.example/beta": .object(["mode": .string("on")])]
        )
        await client.disconnect()
        await server.stop()
    }

    @Test("Legacy initialize carries client extension capabilities")
    func legacyClientExtensions() async throws {
        let received = Received()
        let pair = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "server", version: "1")
        try await server.start(transport: pair.server) { _, capabilities in
            await received.set(capabilities.extensions)
        }
        let client = Client(
            name: "client",
            version: "1",
            capabilities: .init(extensions: Self.extensionSettings)
        )
        _ = try await client.connect(transport: pair.client)

        #expect(await received.value == Self.extensionSettings)
        await client.disconnect()
        await server.stop()
    }

    @Test("Modern request metadata carries client extension capabilities")
    func modernClientExtensions() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "server", version: "1")
        await server.withMethodHandler(CapabilityProbe.self) { _ in
            let extensions = Server.currentHandlerContext?.requestMetadata?
                .clientCapabilities.extensions
            return CapabilityProbe.Result(extensions: extensions)
        }
        try await server.start(transport: pair.server)
        let client = Client(
            name: "client",
            version: "1",
            capabilities: .init(extensions: Self.extensionSettings)
        )
        _ = try await client.connect(
            transport: pair.client,
            preference: .modernOnly,
            delivery: .byteStream
        )

        let result = try await client.sendModern(CapabilityProbe.request(.init()))
        #expect(result.value.extensions == Self.extensionSettings)
        await client.disconnect()
        await server.stop()
    }

    @Test("A legacy server answering an unsupported revision leaves connectionInfo unset")
    func legacyUnsupportedRevision() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "server", version: "1")
        try await server.start(transport: pair.server)
        await server.withMethodHandler(Initialize.self) { _ in
            Initialize.Result(
                protocolVersion: "2099-01-01",
                capabilities: .init(),
                serverInfo: .init(name: "server", version: "1"),
                instructions: nil
            )
        }
        let client = Client(name: "client", version: "1")

        let result = try await client.connect(transport: pair.client)

        #expect(result.protocolVersion == "2099-01-01")
        #expect(await client.connectionInfo == nil)
        await client.disconnect()
        await server.stop()
    }

    @Test("Mounted namespaces serve owned URIs before the application handler", arguments: Era.allCases)
    func mountedNamespaceRouting(era: Era) async throws {
        let server = Server(name: "server", version: "1", capabilities: .init(resources: .init()))
        await server.withMethodHandler(ReadResource.self) { parameters in
            ReadResource.Result(contents: [.text("application", uri: parameters.uri)])
        }
        await server.mount(ResourceNamespace { parameters in
            guard parameters.uri.hasPrefix("ns://") else { return nil }
            return ReadResource.Result(contents: [.text("namespace", uri: parameters.uri)])
        })
        let client = Client(name: "client", version: "1")
        try await connect(client, to: server, era: era)

        let owned = try await read("ns://file", client: client, era: era)
        let other = try await read("app://file", client: client, era: era)

        #expect(owned.contents.first?.text == "namespace")
        #expect(other.contents.first?.text == "application")
        await client.disconnect()
        await server.stop()
    }

    @Test("Without an application handler, unowned URIs are ResourceNotFound", arguments: Era.allCases)
    func mountedNamespaceWithoutApplicationHandler(era: Era) async throws {
        let server = Server(name: "server", version: "1", capabilities: .init(resources: .init()))
        await server.mount(ResourceNamespace { _ in nil })
        let client = Client(name: "client", version: "1")
        try await connect(client, to: server, era: era)

        do {
            _ = try await read("app://missing", client: client, era: era)
            Issue.record("Expected ResourceNotFound")
        } catch let error as MCPError {
            #expect(error.code == -32602)
        }
        await client.disconnect()
        await server.stop()
    }

    @Test("A namespace error is the response error", arguments: Era.allCases)
    func mountedNamespaceError(era: Era) async throws {
        let server = Server(name: "server", version: "1", capabilities: .init(resources: .init()))
        await server.mount(ResourceNamespace { _ in
            throw MCPError.internalError("namespace failure")
        })
        let client = Client(name: "client", version: "1")
        try await connect(client, to: server, era: era)

        do {
            _ = try await read("ns://file", client: client, era: era)
            Issue.record("Expected the namespace error")
        } catch let error as MCPError {
            #expect(error.code == -32603)
        }
        await client.disconnect()
        await server.stop()
    }

    private func read(_ uri: String, client: Client, era: Era) async throws -> ReadResource.Result {
        let request = ReadResource.request(.init(uri: uri))
        switch era {
        case .legacy:
            return try await client.send(request).value
        case .modern:
            return try await client.sendModern(request).value
        }
    }
}

private actor Received {
    private(set) var value: [String: Value]?

    func set(_ value: [String: Value]?) {
        self.value = value
    }
}

private enum CapabilityProbe: MCP.Method {
    static let name = "test/capabilityProbe"

    struct Parameters: Hashable, Codable, Sendable {}

    struct Result: Hashable, Codable, Sendable {
        let extensions: [String: Value]?
    }
}
