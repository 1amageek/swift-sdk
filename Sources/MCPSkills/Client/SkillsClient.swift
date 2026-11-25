import Foundation
import MCP

extension Client {
    /// The Skills extension API for this client.
    public nonisolated var skills: SkillsClient {
        SkillsClient(client: self)
    }
}

/// Lists, looks up, and reads skills from a server that declares the Skills
/// extension, in either protocol era.
///
/// Every call checks the server's declaration before sending, and every
/// read is verified against the skill's manifest before its bytes are
/// returned.
public struct SkillsClient: Sendable {
    /// One page of a listing.
    public struct Page: Hashable, Sendable {
        /// The valid entries on this page.
        public let skills: [Skill]
        /// Entries refused on this page.
        public let rejected: [RejectedSkill]
        /// The cursor of the next page, when one exists.
        public let nextCursor: String?
        /// The page's cache hint; always present on 2026-07-28.
        public let cacheHint: CacheHint?
    }

    /// A complete listing.
    public struct Listing: Hashable, Sendable {
        /// The valid entries, in server order.
        public let skills: [Skill]
        /// Entries refused across all pages.
        public let rejected: [RejectedSkill]
    }

    /// The client that carries the requests.
    public let client: Client

    public init(client: Client) {
        self.client = client
    }

    // MARK: - Capability

    /// The server's Skills declaration, or `nil` when the server does not
    /// declare the extension or the client is not connected.
    public func capability() async -> SkillsCapability? {
        guard let info = await client.connectionInfo else { return nil }
        return SkillsCapability(declaredIn: info.serverCapabilities)
    }

    // MARK: - Listing

    /// Fetches one page of `skills/list`.
    ///
    /// Each entry is decoded and validated on its own; refused entries are
    /// reported in ``Page/rejected`` and never appear in ``Page/skills``.
    public func list(cursor: String? = nil) async throws -> Page {
        let era = try await requireExtension(directoryRead: false)
        let response = try await send(
            RawListSkills.request(.init(cursor: cursor)),
            era: era
        )
        let (skills, rejected) = Self.partition(response.result.skills)
        return Page(
            skills: skills,
            rejected: rejected,
            nextCursor: response.result.nextCursor,
            cacheHint: response.cacheHint
        )
    }

    /// Follows `skills/list` cursors until the listing ends.
    ///
    /// A URI that appears more than once anywhere in the listing is refused
    /// in every copy.
    ///
    /// - Parameter maxPages: The maximum number of pages to fetch; positive.
    /// - Throws: ``SkillsClientError/cursorCycle(_:)`` when a cursor repeats
    ///   and ``SkillsClientError/pageLimitExceeded(_:)`` when the listing
    ///   does not end within `maxPages`.
    public func listAll(maxPages: Int = 64) async throws -> Listing {
        precondition(maxPages > 0, "maxPages must be positive")
        var entries: [Value] = []
        var seenCursors = Set<String>()
        var cursor: String?
        for _ in 0..<maxPages {
            let era = try await requireExtension(directoryRead: false)
            let response = try await send(
                RawListSkills.request(.init(cursor: cursor)),
                era: era
            )
            entries.append(contentsOf: response.result.skills)
            guard let next = response.result.nextCursor else {
                let (skills, rejected) = Self.partition(entries)
                return Listing(skills: skills, rejected: rejected)
            }
            guard seenCursors.insert(next).inserted else {
                throw SkillsClientError.cursorCycle(next)
            }
            cursor = next
        }
        throw SkillsClientError.pageLimitExceeded(maxPages)
    }

    // MARK: - Lookup

    /// Fetches one skill entry with `skills/get` and validates it.
    public func skill(at uri: String) async throws -> GetSkill.Result {
        let era = try await requireExtension(directoryRead: false)
        let response = try await send(GetSkill.request(.init(uri: uri)), era: era)
        let skill = response.result.skill
        do {
            try skill.validate()
        } catch {
            throw SkillsClientError.invalidEntry(error)
        }
        guard SkillURI.normalized(skill.uri) == SkillURI.normalized(uri) else {
            throw SkillsClientError.uriMismatch(requested: uri, returned: skill.uri)
        }
        return GetSkill.Result(skill: skill, cacheHint: response.cacheHint)
    }

    // MARK: - Reading

    /// Reads and verifies one file of `skill`.
    ///
    /// `reference` is resolved against the skill directory; an absolute URI
    /// is used as is. For a listed skill, a file that is not in the manifest
    /// is refused before any request, and the bytes must match the entry's
    /// size and digest. For the skill's own `SKILL.md`, the frontmatter must
    /// also equal the entry's. A dynamic skill's reads must stay inside the
    /// skill directory and within the per-skill byte limit.
    ///
    /// - Parameters:
    ///   - reference: A path relative to the skill directory, or an absolute URI.
    ///   - skill: The entry the read is bound to.
    /// - Returns: Bytes that passed every applicable check.
    public func read(
        _ reference: String = SkillsExtension.manifestFileName,
        of skill: Skill
    ) async throws -> SkillFile {
        do {
            try skill.validate()
        } catch {
            throw SkillsClientError.invalidEntry(error)
        }
        guard let target = SkillURI.resolve(reference, against: skill.rootURI) else {
            throw SkillsClientError.unresolvableReference(reference)
        }
        let isManifest = SkillURI.normalized(target) == SkillURI.normalized(skill.uri)

        let requestURI: String
        let entry: SkillResource?
        switch skill.resources {
        case .listed(let files):
            let key = SkillURI.normalized(target)
            guard let listed = files.first(where: { SkillURI.normalized($0.uri) == key }) else {
                throw SkillsClientError.unlistedResource(target)
            }
            requestURI = listed.uri
            entry = listed
        case .dynamic:
            guard isManifest || SkillURI.isStrictlyInside(target, root: skill.rootURI) else {
                throw SkillsClientError.resourceOutsideSkill(target)
            }
            requestURI = target
            entry = nil
        }

        let era = try await requireExtension(directoryRead: false)
        let result = try await readResource(requestURI, era: era)
        let key = SkillURI.normalized(requestURI)
        guard let content = result.contents.first(where: { SkillURI.normalized($0.uri) == key }) else {
            throw SkillsClientError.missingContents(requestURI)
        }
        let data = try Self.bytes(of: content, uri: requestURI)

        let integrity: SkillFile.Integrity
        if let entry {
            guard data.count == entry.size else {
                throw SkillsClientError.sizeMismatch(
                    uri: requestURI,
                    expected: entry.size,
                    actual: data.count
                )
            }
            let digest = SkillDigest.sha256(of: data)
            guard digest == entry.digest else {
                throw SkillsClientError.digestMismatch(
                    uri: requestURI,
                    expected: entry.digest,
                    actual: digest
                )
            }
            integrity = .verified
        } else {
            guard data.count <= SkillLimits.specification.maxBytes else {
                throw SkillsClientError.limitExceeded(uri: requestURI, bytes: data.count)
            }
            integrity = .unverifiable
        }

        let markdown = isManifest ? try Self.verifiedMarkdown(data, uri: requestURI, of: skill) : nil
        return SkillFile(
            uri: requestURI,
            mimeType: content.mimeType,
            data: data,
            integrity: integrity,
            markdown: markdown
        )
    }

    // MARK: - Directories

    /// Lists one page of a directory's children with `resources/directory/read`.
    public func directory(
        at uri: String,
        cursor: String? = nil
    ) async throws -> ReadResourceDirectory.Result {
        let era = try await requireExtension(directoryRead: true)
        let response = try await send(
            ReadResourceDirectory.request(.init(uri: uri, cursor: cursor)),
            era: era
        )
        return ReadResourceDirectory.Result(
            resources: response.result.resources,
            nextCursor: response.result.nextCursor,
            cacheHint: response.cacheHint
        )
    }

    // MARK: - Transport

    private struct Response<Result> {
        let result: Result
        let cacheHint: CacheHint?
    }

    /// Returns the negotiated era after checking the server's declaration.
    private func requireExtension(directoryRead: Bool) async throws -> ProtocolEra {
        guard let info = await client.connectionInfo else {
            throw SkillsClientError.notConnected
        }
        guard let capability = SkillsCapability(declaredIn: info.serverCapabilities) else {
            throw SkillsClientError.extensionNotSupported
        }
        if directoryRead, !capability.directoryRead {
            throw SkillsClientError.directoryReadNotSupported
        }
        return info.era
    }

    /// Sends a Skills method. On 2026-07-28 the result must carry its cache
    /// fields; on legacy revisions they are absent.
    private func send<M: MCP.Method>(
        _ request: Request<M>,
        era: ProtocolEra
    ) async throws -> Response<M.Result> {
        switch era {
        case .modern:
            let result = try await client.sendModern(request)
            guard let cacheHint = result.cacheHint else {
                throw SkillsClientError.missingCacheHint(method: M.name)
            }
            return Response(result: result.value, cacheHint: cacheHint)
        case .legacy:
            let context = try await client.send(request)
            return Response(result: try await context.value, cacheHint: nil)
        }
    }

    private func readResource(_ uri: String, era: ProtocolEra) async throws -> ReadResource.Result {
        let request = ReadResource.request(.init(uri: uri))
        switch era {
        case .modern:
            return try await client.sendModern(request).value
        case .legacy:
            return try await client.send(request).value
        }
    }

    // MARK: - Verification helpers

    private static func bytes(of content: Resource.Content, uri: String) throws -> Data {
        if let text = content.text {
            return Data(text.utf8)
        }
        if let blob = content.blob {
            guard let data = Data(base64Encoded: blob) else {
                throw SkillsClientError.invalidBlob(uri)
            }
            return data
        }
        throw SkillsClientError.missingContents(uri)
    }

    private static func verifiedMarkdown(
        _ data: Data,
        uri: String,
        of skill: Skill
    ) throws -> SkillMarkdown {
        guard let text = LosslessUTF8.decode(data) else {
            throw SkillsClientError.invalidFrontmatter(uri: uri, .missingOpeningDelimiter)
        }
        let markdown: SkillMarkdown
        let differences: [String]
        do {
            markdown = try SkillMarkdown(parsing: text)
            differences = try markdown.frontmatter.differences(from: skill.frontmatter)
        } catch {
            throw SkillsClientError.invalidFrontmatter(uri: uri, error)
        }
        guard differences.isEmpty else {
            throw SkillsClientError.frontmatterMismatch(uri: uri, fields: differences)
        }
        return markdown
    }

    /// Decodes entries one by one and refuses invalid ones and every copy of
    /// a duplicated URI.
    private static func partition(_ entries: [Value]) -> ([Skill], [RejectedSkill]) {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var decoded: [Skill] = []
        var rejected: [RejectedSkill] = []
        for entry in entries {
            let skill: Skill
            do {
                skill = try decoder.decode(Skill.self, from: encoder.encode(entry))
            } catch {
                rejected.append(
                    RejectedSkill(
                        uri: entry.objectValue?["uri"]?.stringValue,
                        reason: .malformed(String(describing: error))
                    )
                )
                continue
            }
            do {
                try skill.validate()
                decoded.append(skill)
            } catch {
                rejected.append(RejectedSkill(uri: skill.uri, reason: .invalid(error)))
            }
        }
        var counts: [String: Int] = [:]
        for skill in decoded {
            counts[SkillURI.normalized(skill.uri), default: 0] += 1
        }
        var accepted: [Skill] = []
        for skill in decoded {
            if counts[SkillURI.normalized(skill.uri)] == 1 {
                accepted.append(skill)
            } else {
                rejected.append(RejectedSkill(uri: skill.uri, reason: .duplicateURI))
            }
        }
        return (accepted, rejected)
    }
}

/// `skills/list` with entries kept as raw values, so one malformed entry does
/// not fail the whole page.
private enum RawListSkills: MCP.Method {
    static let name = ListSkills.name
    typealias Parameters = ListSkills.Parameters

    struct Result: Hashable, Codable, Sendable {
        let skills: [Value]
        let nextCursor: String?
    }
}
