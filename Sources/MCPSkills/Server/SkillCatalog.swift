import Foundation
import MCP

/// An immutable catalog of skills built from a directory tree.
///
/// Every directory that contains a regular file named `SKILL.md` is a skill.
/// The catalog validates each skill, computes its manifest, and keeps the
/// bytes of every served file in memory, so a read always returns exactly
/// the bytes that were digested.
///
/// ```swift
/// let catalog = try SkillCatalog(directory: skillsDirectory)
/// try await server.withSkills(catalog)
/// ```
public struct SkillCatalog: SkillDirectorySource {
    /// How the catalog treats invalid skills.
    public enum Policy: Hashable, Sendable {
        /// Any issue fails construction with ``SkillCatalogError/invalidSkills(_:)``.
        case strict
        /// Invalid skills are excluded and reported in ``SkillCatalog/issues``.
        case skippingInvalidSkills
    }

    /// Construction options.
    public struct Options: Hashable, Sendable {
        /// The URI prefix of every skill, for example `skill://` or
        /// `skill://acme`.
        public var baseURI: String
        /// The number of entries per `skills/list` or directory page.
        public var pageSize: Int
        /// The per-skill limits.
        public var limits: SkillLimits
        /// How invalid skills are treated.
        public var policy: Policy

        /// - Precondition: `pageSize` is positive.
        public init(
            baseURI: String = "skill://",
            pageSize: Int = 100,
            limits: SkillLimits = .specification,
            policy: Policy = .strict
        ) {
            precondition(pageSize > 0, "pageSize must be positive")
            self.baseURI = baseURI
            self.pageSize = pageSize
            self.limits = limits
            self.policy = policy
        }
    }

    struct StoredFile: Sendable {
        let uri: String
        let data: Data
        let mimeType: String?
    }

    /// The served skills, sorted by URI.
    public let skills: [Skill]
    /// Skills excluded under ``Policy/skippingInvalidSkills``, with reasons.
    public let issues: [SkillCatalogIssue]

    private let skillsByKey: [String: Skill]
    private let files: [String: StoredFile]
    private let directories: [String: [Resource]]
    private let pageSize: Int

    /// Builds a catalog from a directory on disk.
    ///
    /// Hidden entries are skipped; symbolic links and special files are
    /// never followed and make their skill invalid.
    public init(directory: URL, options: Options = Options()) throws(SkillCatalogError) {
        try self.init(entries: try FileSystemSkillReader.entries(in: directory), options: options)
    }

    /// Builds a catalog from in-memory files keyed by `/`-separated paths
    /// relative to the catalog root, for example `pdf-processing/SKILL.md`.
    ///
    /// Paths with a hidden component are skipped.
    public init(files: [String: Data], options: Options = Options()) throws(SkillCatalogError) {
        let entries = files.compactMap { path, data -> SkillCatalogEntry? in
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty,
                !components.contains(where: SkillCatalogEntry.isHidden)
            else {
                return nil
            }
            return SkillCatalogEntry(path: components, content: .file(data))
        }
        try self.init(entries: entries, options: options)
    }

    init(entries: [SkillCatalogEntry], options: Options) throws(SkillCatalogError) {
        let snapshot = try SkillCatalogBuilder(options: options).build(entries)
        self.skills = snapshot.skills
        self.issues = snapshot.issues
        self.skillsByKey = Dictionary(
            uniqueKeysWithValues: snapshot.skills.map { (SkillURI.normalized($0.uri), $0) }
        )
        self.files = snapshot.files
        self.directories = snapshot.directories
        self.pageSize = options.pageSize
    }

    /// One resource per skill's `SKILL.md`, with the frontmatter name and
    /// description and the `text/markdown` MIME type, for an application's
    /// `resources/list` result.
    public var manifestResources: [Resource] {
        skills.map { skill in
            Resource(
                name: skill.frontmatter.name,
                uri: skill.uri,
                description: skill.frontmatter.description,
                mimeType: SkillsExtension.manifestMimeType,
                size: files[SkillURI.normalized(skill.uri)]?.data.count
            )
        }
    }

    // MARK: - SkillSource

    public func skills(after cursor: String?) async throws -> SkillSourcePage<Skill> {
        try SkillCursor.page(of: skills, key: \.uri, after: cursor, pageSize: pageSize)
    }

    public func skill(at uri: String) async throws -> Skill? {
        skillsByKey[SkillURI.normalized(uri)]
    }

    public func contents(of uri: String) async throws -> [Resource.Content]? {
        guard let file = files[SkillURI.normalized(uri)] else { return nil }
        if let text = LosslessUTF8.decode(file.data) {
            return [.text(text, uri: file.uri, mimeType: file.mimeType)]
        }
        return [.binary(file.data, uri: file.uri, mimeType: file.mimeType)]
    }

    public func directory(at uri: String, after cursor: String?) async throws -> SkillSourcePage<Resource>? {
        guard let children = directories[SkillURI.normalized(uri)] else { return nil }
        return try SkillCursor.page(of: children, key: \.uri, after: cursor, pageSize: pageSize)
    }
}
