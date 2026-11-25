import Foundation
import MCP

/// A skill entry as returned by `skills/list` and `skills/get`.
public struct Skill: Hashable, Sendable {
    /// The files a skill consists of.
    public enum Resources: Hashable, Sendable {
        /// A complete manifest: every file of the skill exactly once,
        /// including its own `SKILL.md`.
        case listed([SkillResource])
        /// The server generates the skill's content, so no manifest exists.
        case dynamic
    }

    /// The URI of the skill's `SKILL.md`.
    public let uri: String
    /// The `SKILL.md` frontmatter, verbatim.
    public let frontmatter: SkillFrontmatter
    /// The skill's files.
    public let resources: Resources
    /// Extension metadata (`_meta`). Extension-defined keys use the
    /// ``SkillsExtension/metadataPrefix``.
    public let metadata: [String: Value]?

    public init(
        uri: String,
        frontmatter: SkillFrontmatter,
        resources: Resources,
        metadata: [String: Value]? = nil
    ) {
        self.uri = uri
        self.frontmatter = frontmatter
        self.resources = resources
        self.metadata = metadata
    }

    /// The skill name from the frontmatter.
    public var name: String { frontmatter.name }

    /// The skill directory URI: ``uri`` without its trailing `/SKILL.md`.
    public var rootURI: String {
        String(uri.dropLast(SkillsExtension.manifestFileName.count + 1))
    }

    /// Checks the entry against the Skills extension rules.
    public func validate() throws(SkillValidationError) {
        guard let (_, segments) = SkillURI.split(uri),
            segments.count >= 2,
            segments.last == Substring(SkillsExtension.manifestFileName),
            segments.dropLast().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw .invalidSkillURI(uri)
        }
        let finalSegment = segments[segments.count - 2]
        guard let decodedName = SkillURI.decodeSegment(finalSegment),
            decodedName == frontmatter.name
        else {
            throw .nameMismatch(name: frontmatter.name, uri: uri)
        }
        guard Self.isValidName(frontmatter.name) else {
            throw .invalidName(frontmatter.name)
        }
        guard (1...1024).contains(frontmatter.description.count) else {
            throw .invalidDescription
        }
        guard case .listed(let files) = resources else { return }

        let root = rootURI
        var seen = Set<String>()
        for file in files {
            guard file.size >= 0 else {
                throw .invalidSize(uri: file.uri, size: file.size)
            }
            guard SkillURI.isStrictlyInside(file.uri, root: root) else {
                throw .resourceOutsideSkill(uri: file.uri)
            }
            guard seen.insert(SkillURI.normalized(file.uri)).inserted else {
                throw .duplicateResource(uri: file.uri)
            }
        }
        guard seen.contains(SkillURI.normalized(uri)) else {
            throw .missingManifestFile(uri: uri)
        }
    }

    /// Whether `name` satisfies the Agent Skills naming rules: 1–64
    /// characters of lowercase letters, ASCII digits, and single interior
    /// hyphens.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), name.first != "-", name.last != "-",
            !name.contains("--")
        else {
            return false
        }
        return name.allSatisfy { character in
            character == "-"
                || ("0"..."9").contains(character)
                || (character.isLetter && character.isLowercase)
        }
    }
}

extension Skill: Codable {
    private enum CodingKeys: String, CodingKey {
        case uri, frontmatter, resources
        case metadata = "_meta"
    }

    private static let dynamicSpelling = "dynamic"

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let uri = try container.decode(String.self, forKey: .uri)
        let frontmatter = try container.decode(SkillFrontmatter.self, forKey: .frontmatter)
        let resources: Resources
        switch try container.decode(Value.self, forKey: .resources) {
        case .string(Self.dynamicSpelling):
            resources = .dynamic
        case .array:
            resources = .listed(try container.decode([SkillResource].self, forKey: .resources))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .resources,
                in: container,
                debugDescription: "resources must be an array or \"dynamic\""
            )
        }
        self.init(
            uri: uri,
            frontmatter: frontmatter,
            resources: resources,
            metadata: try container.decodeIfPresent([String: Value].self, forKey: .metadata)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uri, forKey: .uri)
        try container.encode(frontmatter, forKey: .frontmatter)
        switch resources {
        case .listed(let files):
            try container.encode(files, forKey: .resources)
        case .dynamic:
            try container.encode(Self.dynamicSpelling, forKey: .resources)
        }
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}
