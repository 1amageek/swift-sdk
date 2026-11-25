import MCP

extension Server {
    /// Serves skills from `source` through the Skills extension.
    ///
    /// The call declares `capabilities.extensions["io.modelcontextprotocol/skills"]`
    /// (with `directoryRead: true` exactly when `source` is a
    /// ``SkillDirectorySource``), registers `skills/list`, `skills/get`, and,
    /// for directory sources, `resources/directory/read`, and mounts `source`
    /// so `resources/read` serves skill files before the application's own
    /// `resources/read` handler.
    ///
    /// - Parameters:
    ///   - source: The skills to serve.
    ///   - cacheHint: The cache hint attached to Skills results on
    ///     2026-07-28. Defaults to `private` with `ttlMs: 0`.
    /// - Throws: ``SkillsServerError/resourcesCapabilityRequired`` when the
    ///   server does not declare `resources`, and
    ///   ``SkillsServerError/alreadyInstalled`` when the extension is
    ///   already declared.
    @discardableResult
    public func withSkills(
        _ source: some SkillSource,
        cacheHint: CacheHint? = nil
    ) throws(SkillsServerError) -> Self {
        guard capabilities.resources != nil else {
            throw .resourcesCapabilityRequired
        }
        guard capabilities.extensions?[SkillsExtension.identifier] == nil else {
            throw .alreadyInstalled
        }
        let directorySource = source as? any SkillDirectorySource
        var extensions = capabilities.extensions ?? [:]
        extensions[SkillsExtension.identifier] =
            SkillsCapability(directoryRead: directorySource != nil).settings
        capabilities.extensions = extensions

        let handler = SkillsRequestHandler(server: self, source: source, cacheHint: cacheHint)
        withMethodHandler(ListSkills.self) { parameters in
            try await handler.list(parameters)
        }
        withMethodHandler(GetSkill.self) { parameters in
            try await handler.get(parameters)
        }
        if let directorySource {
            withMethodHandler(ReadResourceDirectory.self) { parameters in
                try await handler.readDirectory(parameters, from: directorySource)
            }
        }
        mount(ResourceNamespace { parameters in
            try await source.contents(of: parameters.uri).map {
                ReadResource.Result(contents: $0)
            }
        })
        return self
    }
}

/// The request logic behind ``MCP/Server/withSkills(_:cacheHint:)``.
///
/// The server is held weakly because the handlers are stored by the server.
struct SkillsRequestHandler<Source: SkillSource>: Sendable {
    private weak var server: Server?
    private let source: Source
    private let cacheHint: CacheHint?

    init(server: Server, source: Source, cacheHint: CacheHint?) {
        self.server = server
        self.source = source
        self.cacheHint = cacheHint
    }

    func list(_ parameters: ListSkills.Parameters) async throws -> ListSkills.Result {
        try await requireDeclared(directoryRead: false)
        let page = try await source.skills(after: parameters.cursor)
        for skill in page.items {
            try requireValid(skill)
        }
        return ListSkills.Result(
            skills: page.items,
            nextCursor: page.nextCursor,
            cacheHint: try resultCacheHint()
        )
    }

    func get(_ parameters: GetSkill.Parameters) async throws -> GetSkill.Result {
        try await requireDeclared(directoryRead: false)
        guard let (_, segments) = SkillURI.split(parameters.uri),
            segments.count >= 2,
            segments.last == Substring(SkillsExtension.manifestFileName)
        else {
            throw MCPError.invalidParams("Not a SKILL.md URI: \(parameters.uri)")
        }
        guard let skill = try await source.skill(at: parameters.uri) else {
            throw MCPError.invalidParams("Unknown skill: \(parameters.uri)")
        }
        guard SkillURI.normalized(skill.uri) == SkillURI.normalized(parameters.uri) else {
            throw MCPError.internalError(
                "Skill source returned \(skill.uri) for \(parameters.uri)"
            )
        }
        try requireValid(skill)
        return GetSkill.Result(skill: skill, cacheHint: try resultCacheHint())
    }

    func readDirectory(
        _ parameters: ReadResourceDirectory.Parameters,
        from directorySource: any SkillDirectorySource
    ) async throws -> ReadResourceDirectory.Result {
        try await requireDeclared(directoryRead: true)
        guard let page = try await directorySource.directory(
            at: parameters.uri,
            after: parameters.cursor
        ) else {
            throw MCPError.invalidParams("Not a directory resource: \(parameters.uri)")
        }
        return ReadResourceDirectory.Result(
            resources: page.items,
            nextCursor: page.nextCursor,
            cacheHint: try resultCacheHint()
        )
    }

    /// Re-checks the declaration so a removed declaration also removes the
    /// methods.
    private func requireDeclared(directoryRead: Bool) async throws {
        guard let server else {
            throw MCPError.internalError("Server was deallocated")
        }
        let capabilities = await server.capabilities
        let declared = capabilities.extensions?[SkillsExtension.identifier]
        guard case .object(let settings)? = declared else {
            throw MCPError.methodNotFound("The Skills extension is not declared")
        }
        if directoryRead, settings["directoryRead"] != .bool(true) {
            throw MCPError.methodNotFound("directoryRead is not declared")
        }
    }

    private func requireValid(_ skill: Skill) throws {
        do {
            try skill.validate()
        } catch {
            throw MCPError.internalError("Skill source returned an invalid entry: \(error)")
        }
    }

    /// The cache hint for the current request: present on 2026-07-28, absent
    /// on legacy revisions.
    private func resultCacheHint() throws -> CacheHint? {
        guard Server.currentHandlerContext?.era == .modern else { return nil }
        return try cacheHint ?? CacheHint(scope: .private, ttlMs: 0)
    }
}
