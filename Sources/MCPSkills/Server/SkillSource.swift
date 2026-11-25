import MCP

/// A provider of skills for ``MCP/Server/withSkills(_:cacheHint:)``.
///
/// Conforming types own the skill entries and the bytes of every skill file.
/// The server validates every entry a source returns and reports an invalid
/// one as an internal error.
public protocol SkillSource: Sendable {
    /// One page of skills following `cursor`, or the first page when `cursor`
    /// is `nil`.
    ///
    /// Throw `MCPError.invalidParams` for a cursor the source cannot interpret.
    func skills(after cursor: String?) async throws -> SkillSourcePage<Skill>

    /// The entry whose `SKILL.md` URI is `uri`, listed or not.
    ///
    /// - Returns: `nil` when the source does not serve that skill.
    func skill(at uri: String) async throws -> Skill?

    /// The contents of a skill file.
    ///
    /// - Returns: `nil` for a URI this source does not own, so the server can
    ///   route the read to the application's `resources/read` handler.
    func contents(of uri: String) async throws -> [Resource.Content]?
}

/// A ``SkillSource`` that also serves `resources/directory/read`.
///
/// Installing a directory source declares `directoryRead: true`.
public protocol SkillDirectorySource: SkillSource {
    /// One page of the direct children of the directory `uri`.
    ///
    /// - Returns: `nil` when `uri` is not a directory this source serves.
    func directory(at uri: String, after cursor: String?) async throws -> SkillSourcePage<Resource>?
}

/// One page returned by a ``SkillSource``.
public struct SkillSourcePage<Element: Sendable>: Sendable {
    /// The items on this page.
    public let items: [Element]
    /// The cursor of the next page, when one exists.
    public let nextCursor: String?

    public init(items: [Element], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

extension SkillSourcePage: Equatable where Element: Equatable {}
extension SkillSourcePage: Hashable where Element: Hashable {}
