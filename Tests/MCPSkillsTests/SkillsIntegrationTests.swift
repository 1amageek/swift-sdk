import Foundation
import MCP
import Testing

@testable import MCPSkills

/// End-to-end Skills behavior over an in-memory connection, in both eras.
@Suite("Skills server and client", .timeLimit(.minutes(1)))
struct SkillsIntegrationTests {
    enum Era: String, CaseIterable, Sendable {
        case legacy, modern
    }

    struct Connection {
        let server: Server
        let client: Client

        func close() async {
            await client.disconnect()
            await server.stop()
        }
    }

    private func connect(
        era: Era,
        source: (some SkillSource)? = SkillCatalog?.none,
        configure: (Server) async throws -> Void = { _ in }
    ) async throws -> Connection {
        let server = Server(name: "server", version: "1", capabilities: .init(resources: .init()))
        if let source {
            try await server.withSkills(source)
        }
        try await configure(server)
        let pair = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: pair.server)
        let client = Client(name: "client", version: "1")
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
        return Connection(server: server, client: client)
    }

    // MARK: - Installation

    @Test("Installation declares the extension, directoryRead, and requires resources")
    func installation() async throws {
        let server = Server(name: "server", version: "1", capabilities: .init(resources: .init()))
        try await server.withSkills(try SkillFixtures.catalog())
        #expect(
            await server.capabilities.extensions?[SkillsExtension.identifier]
                == .object(["directoryRead": .bool(true)])
        )
        await #expect(throws: SkillsServerError.alreadyInstalled) {
            try await server.withSkills(try SkillFixtures.catalog())
        }

        let plain = Server(name: "server", version: "1", capabilities: .init(resources: .init()))
        try await plain.withSkills(ListOnlySource(skills: try SkillFixtures.catalog().skills))
        #expect(await plain.capabilities.extensions?[SkillsExtension.identifier] == .object([:]))

        let withoutResources = Server(name: "server", version: "1")
        await #expect(throws: SkillsServerError.resourcesCapabilityRequired) {
            try await withoutResources.withSkills(try SkillFixtures.catalog())
        }
    }

    // MARK: - Listing and lookup

    @Test("Listing follows cursors and carries cache fields only on 2026-07-28", arguments: Era.allCases)
    func listing(era: Era) async throws {
        let catalog = try SkillFixtures.catalog(options: .init(pageSize: 1))
        let connection = try await connect(era: era, source: catalog)
        let skills = connection.client.skills

        #expect(await skills.capability() == SkillsCapability(directoryRead: true))
        let first = try await skills.list()
        #expect(first.skills.count == 1)
        #expect(first.nextCursor != nil)
        switch era {
        case .legacy: #expect(first.cacheHint == nil)
        case .modern: #expect(first.cacheHint == (try CacheHint(scope: .private, ttlMs: 0)))
        }
        let all = try await skills.listAll()
        #expect(all.skills == catalog.skills)
        #expect(all.rejected.isEmpty)
        await connection.close()
    }

    @Test("skills/get returns listed and unlisted skills and rejects unknown URIs", arguments: Era.allCases)
    func lookup(era: Era) async throws {
        let catalog = try SkillFixtures.catalog()
        let hidden = catalog.skills[0]
        let source = ListOnlySource(skills: Array(catalog.skills.dropFirst()), unlisted: [hidden])
        let connection = try await connect(era: era, source: source)
        let skills = connection.client.skills

        let found = try await skills.skill(at: hidden.uri)
        #expect(found.skill == hidden)
        #expect((found.cacheHint != nil) == (era == .modern))

        for uri in ["skill://missing/SKILL.md", "skill://pdf-processing/references/FORMS.md"] {
            do {
                _ = try await skills.skill(at: uri)
                Issue.record("Expected -32602 for \(uri)")
            } catch let error as MCPError {
                #expect(error.code == -32602)
            }
        }
        await connection.close()
    }

    @Test("Invalid entries from a custom source are internal errors", arguments: Era.allCases)
    func invalidSourceEntry(era: Era) async throws {
        let valid = try SkillFixtures.catalog().skills[0]
        let invalid = Skill(uri: "skill://other/SKILL.md", frontmatter: valid.frontmatter, resources: .dynamic)
        let connection = try await connect(era: era, source: ListOnlySource(skills: [invalid]))
        do {
            _ = try await connection.client.skills.list()
            Issue.record("Expected -32603")
        } catch let error as MCPError {
            #expect(error.code == -32603)
        }
        await connection.close()
    }

    @Test("The client refuses invalid and duplicate entries without failing the page", arguments: Era.allCases)
    func clientPartitionsEntries(era: Era) async throws {
        let valid = try SkillFixtures.catalog().skills
        let entries: [Value] = [
            try Value(valid[0]),
            try Value(valid[1]),
            try Value(valid[1]),
            .object(["uri": .string("skill://broken/SKILL.md"), "resources": .string("static")]),
            try Value(Skill(uri: "skill://x/SKILL.md", frontmatter: valid[2].frontmatter, resources: .dynamic)),
        ]
        let connection = try await connect(era: era) { server in
            try await declareSkills(on: server)
            await server.withMethodHandler(RawSkillsList.self) { _ in
                RawSkillsList.Result(
                    skills: entries,
                    ttlMs: Server.currentHandlerContext?.era == .modern ? 0 : nil,
                    cacheScope: Server.currentHandlerContext?.era == .modern ? "private" : nil
                )
            }
        }

        let page = try await connection.client.skills.list()
        #expect(page.skills == [valid[0]])
        #expect(page.rejected.count == 4)
        #expect(page.rejected.filter { $0.reason == .duplicateURI }.count == 2)
        #expect(page.rejected.contains { $0.uri == "skill://broken/SKILL.md" })
        #expect(page.rejected.contains {
            $0.reason == .invalid(.nameMismatch(name: valid[2].name, uri: "skill://x/SKILL.md"))
        })
        await connection.close()
    }

    @Test("A 2026-07-28 result without cache fields is refused")
    func missingCacheHint() async throws {
        let connection = try await connect(era: .modern) { server in
            try await declareSkills(on: server)
            await server.withMethodHandler(RawSkillsList.self) { _ in
                RawSkillsList.Result(skills: [], ttlMs: nil, cacheScope: nil)
            }
        }
        await #expect(throws: SkillsClientError.missingCacheHint(method: ListSkills.name)) {
            try await connection.client.skills.list()
        }
        await connection.close()
    }

    @Test("Listing fails on a repeated cursor and on page exhaustion", arguments: Era.allCases)
    func listingBounds(era: Era) async throws {
        let connection = try await connect(era: era) { server in
            try await declareSkills(on: server)
            await server.withMethodHandler(RawSkillsList.self) { parameters in
                let modern = Server.currentHandlerContext?.era == .modern
                let next = parameters.cursor == "b" ? "a" : (parameters.cursor == nil ? "a" : "b")
                return RawSkillsList.Result(
                    skills: [],
                    nextCursor: next,
                    ttlMs: modern ? 0 : nil,
                    cacheScope: modern ? "private" : nil
                )
            }
        }
        await #expect(throws: SkillsClientError.cursorCycle("a")) {
            try await connection.client.skills.listAll()
        }
        await #expect(throws: SkillsClientError.pageLimitExceeded(1)) {
            try await connection.client.skills.listAll(maxPages: 1)
        }
        await connection.close()
    }

    // MARK: - Gates

    @Test("Without the extension the client sends nothing and the server knows no methods", arguments: Era.allCases)
    func notDeclared(era: Era) async throws {
        let connection = try await connect(era: era)
        await #expect(throws: SkillsClientError.extensionNotSupported) {
            try await connection.client.skills.list()
        }
        do {
            _ = try await send(ListSkills.request(.init()), client: connection.client, era: era)
            Issue.record("Expected -32601")
        } catch let error as MCPError {
            #expect(error.code == -32601)
        }
        await connection.close()
    }

    @Test("Removing the declaration removes the methods", arguments: Era.allCases)
    func declarationRemoved(era: Era) async throws {
        let connection = try await connect(era: era, source: try SkillFixtures.catalog())
        await connection.server.removeSkillsDeclaration()
        do {
            _ = try await send(ListSkills.request(.init()), client: connection.client, era: era)
            Issue.record("Expected -32601")
        } catch let error as MCPError {
            #expect(error.code == -32601)
        }
        await connection.close()
    }

    @Test("Directory reads need directoryRead on both sides", arguments: Era.allCases)
    func directoryGate(era: Era) async throws {
        let catalog = try SkillFixtures.catalog()
        let connection = try await connect(era: era, source: ListOnlySource(skills: catalog.skills))
        await #expect(throws: SkillsClientError.directoryReadNotSupported) {
            try await connection.client.skills.directory(at: "skill://pdf-processing")
        }
        do {
            _ = try await send(
                ReadResourceDirectory.request(.init(uri: "skill://pdf-processing")),
                client: connection.client,
                era: era
            )
            Issue.record("Expected -32601")
        } catch let error as MCPError {
            #expect(error.code == -32601)
        }
        await connection.close()
    }

    @Test("Directory reads list children and reject non-directories", arguments: Era.allCases)
    func directoryRead(era: Era) async throws {
        let connection = try await connect(era: era, source: try SkillFixtures.catalog())
        let result = try await connection.client.skills.directory(at: "skill://pdf-processing/references")
        #expect(result.resources.map(\.name) == ["FORMS.md", "Purchase Order.md"])
        #expect((result.cacheHint != nil) == (era == .modern))
        do {
            _ = try await connection.client.skills.directory(at: "skill://pdf-processing/SKILL.md")
            Issue.record("Expected -32602")
        } catch let error as MCPError {
            #expect(error.code == -32602)
        }
        await connection.close()
    }

    // MARK: - Reading

    @Test("Reads verify size, digest, and frontmatter", arguments: Era.allCases)
    func verifiedReads(era: Era) async throws {
        let catalog = try SkillFixtures.catalog()
        let connection = try await connect(era: era, source: catalog)
        let skills = connection.client.skills
        let pdf = try #require(catalog.skills.first { $0.name == "pdf-processing" })

        let manifest = try await skills.read(of: pdf)
        #expect(manifest.integrity == .verified)
        #expect(manifest.markdown?.frontmatter == pdf.frontmatter)

        let forms = try await skills.read("references/FORMS.md", of: pdf)
        #expect(forms.text == "# Forms\n")
        #expect(forms.markdown == nil)

        let encoded = try await skills.read("references/Purchase Order.md", of: pdf)
        #expect(encoded.uri == "skill://pdf-processing/references/Purchase%20Order.md")

        let logo = try await skills.read("assets/logo.png", of: pdf)
        #expect(logo.data == Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]))

        let refunds = try #require(catalog.skills.first { $0.name == "refunds" })
        let bomManifest = try await skills.read(of: refunds)
        #expect(bomManifest.markdown?.frontmatter.name == "refunds")
        await connection.close()
    }

    @Test("Application resources outside the skills namespace keep working", arguments: Era.allCases)
    func applicationResources(era: Era) async throws {
        let connection = try await connect(era: era, source: try SkillFixtures.catalog()) { server in
            await server.withMethodHandler(ReadResource.self) { parameters in
                ReadResource.Result(contents: [.text("app", uri: parameters.uri)])
            }
        }
        let request = ReadResource.request(.init(uri: "app://notes"))
        let result: ReadResource.Result
        switch era {
        case .legacy: result = try await connection.client.send(request).value
        case .modern: result = try await connection.client.sendModern(request).value
        }
        #expect(result.contents.first?.text == "app")
        await connection.close()
    }

    @Test(
        "Tampered content is refused",
        arguments: Era.allCases, [Tamper.digest, .size, .frontmatter]
    )
    func tamperedContent(era: Era, tamper: Tamper) async throws {
        let catalog = try SkillFixtures.catalog()
        let pdf = try #require(catalog.skills.first { $0.name == "pdf-processing" })
        let source = TamperingSource(catalog: catalog, tamper: tamper, entry: pdf)
        let connection = try await connect(era: era, source: source)
        let entry = source.advertisedEntry

        do {
            _ = try await connection.client.skills.read(of: entry)
            Issue.record("Expected \(tamper) verification to fail")
        } catch let error as SkillsClientError {
            switch (tamper, error) {
            case (.digest, .digestMismatch), (.size, .sizeMismatch), (.frontmatter, .frontmatterMismatch):
                break
            default:
                Issue.record("Unexpected error \(error) for \(tamper)")
            }
        }
        await connection.close()
    }

    @Test("Unlisted and escaping references are refused before any request", arguments: Era.allCases)
    func refusedBeforeSending(era: Era) async throws {
        let catalog = try SkillFixtures.catalog()
        let source = CountingSource(catalog: catalog)
        let connection = try await connect(era: era, source: source)
        let pdf = try #require(catalog.skills.first { $0.name == "pdf-processing" })

        await #expect(throws: SkillsClientError.unlistedResource("skill://pdf-processing/secret.md")) {
            try await connection.client.skills.read("secret.md", of: pdf)
        }
        await #expect(throws: SkillsClientError.unresolvableReference("../acme/SKILL.md")) {
            try await connection.client.skills.read("../acme/SKILL.md", of: pdf)
        }
        #expect(await source.reads.value == 0)
        await connection.close()
    }

    @Test("Dynamic skills are read unverified but still compare frontmatter", arguments: Era.allCases)
    func dynamicSkill(era: Era) async throws {
        let frontmatter = try SkillFrontmatter(fields: [
            "name": .string("live"), "description": .string("Generated."),
        ])
        let skill = Skill(uri: "skill://live/SKILL.md", frontmatter: frontmatter, resources: .dynamic)
        let source = DynamicSource(skill: skill, manifest: "---\nname: live\ndescription: Generated.\n---\n")
        let connection = try await connect(era: era, source: source)

        let manifest = try await connection.client.skills.read(of: skill)
        #expect(manifest.integrity == .unverifiable)
        let page = try await connection.client.skills.read("data/today.txt", of: skill)
        #expect(page.text == "generated")
        await #expect(throws: SkillsClientError.resourceOutsideSkill("skill://other/x")) {
            try await connection.client.skills.read("skill://other/x", of: skill)
        }

        let mismatched = DynamicSource(skill: skill, manifest: "---\nname: live\ndescription: Changed.\n---\n")
        let second = try await connect(era: era, source: mismatched)
        await #expect(throws: SkillsClientError.frontmatterMismatch(uri: skill.uri, fields: ["description"])) {
            try await second.client.skills.read(of: skill)
        }
        await connection.close()
        await second.close()
    }

    // MARK: - Helpers

    private func send<M: MCP.Method>(_ request: Request<M>, client: Client, era: Era) async throws -> M.Result {
        switch era {
        case .legacy: return try await client.send(request).value
        case .modern: return try await client.sendModern(request).value
        }
    }
}

enum Tamper: String, CaseIterable, Sendable {
    case digest, size, frontmatter
}

private func declareSkills(on server: Server) async throws {
    await server.declareSkillsForTesting()
}

extension Server {
    fileprivate func declareSkillsForTesting() {
        var extensions = capabilities.extensions ?? [:]
        extensions[SkillsExtension.identifier] = .object([:])
        capabilities.extensions = extensions
    }

    fileprivate func removeSkillsDeclaration() {
        capabilities.extensions?[SkillsExtension.identifier] = nil
    }
}

/// `skills/list` with raw entries, for serving deliberately invalid listings.
private enum RawSkillsList: MCP.Method {
    static let name = ListSkills.name
    typealias Parameters = ListSkills.Parameters

    struct Result: Hashable, Codable, Sendable {
        var skills: [Value]
        var nextCursor: String? = nil
        var ttlMs: Int?
        var cacheScope: String?
    }
}

/// A source without directory support, with optional unlisted skills.
private struct ListOnlySource: SkillSource {
    let skills: [Skill]
    var unlisted: [Skill] = []

    func skills(after cursor: String?) async throws -> SkillSourcePage<Skill> {
        SkillSourcePage(items: skills)
    }

    func skill(at uri: String) async throws -> Skill? {
        (skills + unlisted).first { $0.uri == uri }
    }

    func contents(of uri: String) async throws -> [Resource.Content]? {
        nil
    }
}

/// Serves an internally consistent entry but tampers with the SKILL.md bytes.
private struct TamperingSource: SkillSource {
    let catalog: SkillCatalog
    let tamper: Tamper
    let entry: Skill
    let servedManifest: String
    let advertisedEntry: Skill

    init(catalog: SkillCatalog, tamper: Tamper, entry: Skill) {
        self.catalog = catalog
        self.tamper = tamper
        self.entry = entry
        let original = String(decoding: SkillFixtures.manifest(name: "pdf-processing", extra: "license: MIT\n"), as: UTF8.self)
        switch tamper {
        case .digest:
            servedManifest = original.replacingOccurrences(of: "# pdf", with: "# PDF")
            advertisedEntry = entry
        case .size:
            servedManifest = original + "extra\n"
            advertisedEntry = entry
        case .frontmatter:
            // Digest and size describe the served bytes; only frontmatter differs.
            let served = original.replacingOccurrences(of: "license: MIT", with: "license: GPL")
            servedManifest = served
            guard case .listed(let files) = entry.resources else {
                advertisedEntry = entry
                return
            }
            let data = Data(served.utf8)
            let updated = files.map {
                $0.uri == entry.uri
                    ? SkillResource(uri: $0.uri, digest: SkillDigest.sha256(of: data), size: data.count)
                    : $0
            }
            advertisedEntry = Skill(uri: entry.uri, frontmatter: entry.frontmatter, resources: .listed(updated))
        }
    }

    func skills(after cursor: String?) async throws -> SkillSourcePage<Skill> {
        SkillSourcePage(items: [advertisedEntry])
    }

    func skill(at uri: String) async throws -> Skill? {
        uri == advertisedEntry.uri ? advertisedEntry : nil
    }

    func contents(of uri: String) async throws -> [Resource.Content]? {
        guard uri == entry.uri else { return try await catalog.contents(of: uri) }
        return [.text(servedManifest, uri: uri, mimeType: SkillsExtension.manifestMimeType)]
    }
}

/// Counts file reads that reach the source.
private struct CountingSource: SkillSource {
    let catalog: SkillCatalog
    let reads = ReadCounter()

    func skills(after cursor: String?) async throws -> SkillSourcePage<Skill> {
        try await catalog.skills(after: cursor)
    }

    func skill(at uri: String) async throws -> Skill? {
        try await catalog.skill(at: uri)
    }

    func contents(of uri: String) async throws -> [Resource.Content]? {
        await reads.increment()
        return try await catalog.contents(of: uri)
    }
}

private actor ReadCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

/// A dynamic skill whose files are generated on read.
private struct DynamicSource: SkillSource {
    let skill: Skill
    let manifest: String

    func skills(after cursor: String?) async throws -> SkillSourcePage<Skill> {
        SkillSourcePage(items: [skill])
    }

    func skill(at uri: String) async throws -> Skill? {
        uri == skill.uri ? skill : nil
    }

    func contents(of uri: String) async throws -> [Resource.Content]? {
        if uri == skill.uri {
            return [.text(manifest, uri: uri, mimeType: SkillsExtension.manifestMimeType)]
        }
        guard uri.hasPrefix(skill.rootURI + "/") else { return nil }
        return [.text("generated", uri: uri)]
    }
}
