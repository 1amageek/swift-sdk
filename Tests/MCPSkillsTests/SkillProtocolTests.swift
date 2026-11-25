import Foundation
import MCP
import Testing

@testable import MCPSkills

@Suite("Skills protocol model", .timeLimit(.minutes(1)))
struct SkillProtocolTests {
    static let emptyDigest = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    static func entry(
        uri: String = "skill://pdf-processing/SKILL.md",
        name: String = "pdf-processing",
        description: String = "Extract text from PDFs.",
        resources: Skill.Resources? = nil
    ) throws -> Skill {
        let frontmatter = try SkillFrontmatter(fields: [
            "name": .string(name),
            "description": .string(description),
        ])
        let root = String(uri.dropLast("/SKILL.md".count))
        let digest = try SkillDigest(emptyDigest)
        return Skill(
            uri: uri,
            frontmatter: frontmatter,
            resources: resources ?? .listed([
                SkillResource(uri: uri, digest: digest, size: 0),
                SkillResource(uri: root + "/references/FORMS.md", digest: digest, size: 0),
            ])
        )
    }

    // MARK: - Digest

    @Test("SHA-256 digests match the published empty-input vector")
    func digestOfEmptyInput() {
        #expect(SkillDigest.sha256(of: Data()).rawValue == Self.emptyDigest)
    }

    @Test(
        "Digest spellings other than sha256 plus 64 lowercase hex digits are rejected",
        arguments: [
            "sha256:" + String(repeating: "A", count: 64),
            "sha256:" + String(repeating: "a", count: 63),
            "sha512:" + String(repeating: "a", count: 64),
            String(repeating: "a", count: 64),
            "sha256:" + String(repeating: "g", count: 64),
        ]
    )
    func invalidDigest(spelling: String) {
        #expect(throws: SkillValidationError.invalidDigest(spelling)) {
            try SkillDigest(spelling)
        }
    }

    // MARK: - Wire shape

    @Test("A listed entry round-trips with every frontmatter field")
    func listedRoundTrip() throws {
        let json = """
            {"uri":"skill://pdf-processing/SKILL.md",
             "frontmatter":{"name":"pdf-processing","description":"d","license":"MIT",
                            "metadata":{"author":"a"},"allowed-tools":"Read"},
             "resources":[{"uri":"skill://pdf-processing/SKILL.md","digest":"\(Self.emptyDigest)","size":0}],
             "_meta":{"io.modelcontextprotocol.skills/origin":"test"}}
            """
        let skill = try JSONDecoder().decode(Skill.self, from: Data(json.utf8))

        #expect(skill.frontmatter.fields["license"] == .string("MIT"))
        #expect(skill.frontmatter.fields["metadata"] == .object(["author": .string("a")]))
        #expect(skill.metadata?["io.modelcontextprotocol.skills/origin"] == .string("test"))
        let reencoded = try JSONDecoder().decode(Skill.self, from: JSONEncoder().encode(skill))
        #expect(reencoded == skill)
    }

    @Test("resources decodes the dynamic spelling")
    func dynamicResources() throws {
        let json = """
            {"uri":"skill://a/SKILL.md","frontmatter":{"name":"a","description":"d"},"resources":"dynamic"}
            """
        let skill = try JSONDecoder().decode(Skill.self, from: Data(json.utf8))
        #expect(skill.resources == .dynamic)
        let encoded = try JSONEncoder().encode(skill)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"resources\":\"dynamic\""))
    }

    @Test(
        "resources rejects null, other strings, and a missing member",
        arguments: [#","resources":null"#, #","resources":"static""#, ""]
    )
    func invalidResourcesMember(member: String) {
        let json = """
            {"uri":"skill://a/SKILL.md","frontmatter":{"name":"a","description":"d"}\(member)}
            """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Skill.self, from: Data(json.utf8))
        }
    }

    @Test("Frontmatter requires string name and description")
    func frontmatterRequiresStrings() {
        #expect(throws: SkillFrontmatterError.missingField("name")) {
            try SkillFrontmatter(fields: ["description": .string("d")])
        }
        #expect(throws: SkillFrontmatterError.missingField("description")) {
            try SkillFrontmatter(fields: ["name": .string("a"), "description": .int(1)])
        }
    }

    @Test("Results carry cache fields inline only when present")
    func resultCacheFields() throws {
        let skill = try Self.entry()
        let withHint = ListSkills.Result(
            skills: [skill],
            cacheHint: try CacheHint(scope: .public, ttlMs: 5)
        )
        let object = try JSONDecoder().decode(
            [String: Value].self,
            from: JSONEncoder().encode(withHint)
        )
        #expect(object["ttlMs"] == .int(5))
        #expect(object["cacheScope"] == .string("public"))
        #expect(try JSONDecoder().decode(ListSkills.Result.self, from: JSONEncoder().encode(withHint)) == withHint)

        let legacy = GetSkill.Result(skill: skill)
        let legacyObject = try JSONDecoder().decode(
            [String: Value].self,
            from: JSONEncoder().encode(legacy)
        )
        #expect(legacyObject["ttlMs"] == nil)
        #expect(legacyObject["cacheScope"] == nil)
    }

    @Test("The capability declaration enables directory reads only for a literal true")
    func capabilityDeclaration() {
        let identifier = SkillsExtension.identifier
        #expect(SkillsCapability(declaredIn: CapabilitySet([:])) == nil)
        #expect(SkillsCapability(declaredIn: CapabilitySet(["extensions": .object([identifier: .bool(true)])])) == nil)
        #expect(
            SkillsCapability(declaredIn: CapabilitySet(["extensions": .object([identifier: .object([:])])]))
                == SkillsCapability(directoryRead: false)
        )
        #expect(
            SkillsCapability(declaredIn: CapabilitySet([
                "extensions": .object([identifier: .object(["directoryRead": .string("true")])])
            ]))?.directoryRead == false
        )
        #expect(SkillsCapability(directoryRead: true).settings == .object(["directoryRead": .bool(true)]))
        #expect(SkillsCapability().settings == .object([:]))
    }

    // MARK: - Entry rules

    @Test("A complete entry validates")
    func validEntry() throws {
        try Self.entry().validate()
        try Self.entry(
            uri: "skill://acme/billing/refunds/SKILL.md",
            name: "refunds"
        ).validate()
        try Self.entry(resources: .dynamic).validate()
    }

    @Test("Entry rules reject each violation")
    func entryRuleViolations() throws {
        let digest = try SkillDigest(Self.emptyDigest)
        let manifest = SkillResource(uri: "skill://pdf-processing/SKILL.md", digest: digest, size: 0)
        let cases: [(Skill, SkillValidationError)] = [
            (try Self.entry(uri: "skill:pdf/SKILL.md", name: "pdf"), .invalidSkillURI("skill:pdf/SKILL.md")),
            (try Self.entry(uri: "skill://SKILL.md", name: "pdf"), .invalidSkillURI("skill://SKILL.md")),
            (try Self.entry(uri: "skill://pdf/skill.md", name: "pdf"), .invalidSkillURI("skill://pdf/skill.md")),
            (
                try Self.entry(uri: "skill://other/SKILL.md", name: "pdf-processing"),
                .nameMismatch(name: "pdf-processing", uri: "skill://other/SKILL.md")
            ),
            (try Self.entry(uri: "skill://Bad/SKILL.md", name: "Bad"), .invalidName("Bad")),
            (try Self.entry(description: ""), .invalidDescription),
            (try Self.entry(description: String(repeating: "x", count: 1025)), .invalidDescription),
            (
                try Self.entry(resources: .listed([])),
                .missingManifestFile(uri: "skill://pdf-processing/SKILL.md")
            ),
            (try Self.entry(resources: .listed([manifest, manifest])), .duplicateResource(uri: manifest.uri)),
            (
                try Self.entry(resources: .listed([
                    manifest,
                    SkillResource(uri: "skill://pdf-processing/%41.md", digest: digest, size: 0),
                    SkillResource(uri: "skill://pdf-processing/A.md", digest: digest, size: 0),
                ])),
                .duplicateResource(uri: "skill://pdf-processing/A.md")
            ),
            (
                try Self.entry(resources: .listed([
                    manifest,
                    SkillResource(uri: "skill://pdf-processing/../other/x.md", digest: digest, size: 0),
                ])),
                .resourceOutsideSkill(uri: "skill://pdf-processing/../other/x.md")
            ),
            (
                try Self.entry(resources: .listed([
                    manifest,
                    SkillResource(uri: "skill://pdf-processing/%2E%2E/x.md", digest: digest, size: 0),
                ])),
                .resourceOutsideSkill(uri: "skill://pdf-processing/%2E%2E/x.md")
            ),
            (
                try Self.entry(resources: .listed([
                    manifest,
                    SkillResource(uri: "skill://pdf-processing-evil/x.md", digest: digest, size: 0),
                ])),
                .resourceOutsideSkill(uri: "skill://pdf-processing-evil/x.md")
            ),
            (
                try Self.entry(resources: .listed([
                    manifest,
                    SkillResource(uri: "skill://pdf-processing/x.md?v=1", digest: digest, size: 0),
                ])),
                .resourceOutsideSkill(uri: "skill://pdf-processing/x.md?v=1")
            ),
            (
                try Self.entry(resources: .listed([
                    SkillResource(uri: manifest.uri, digest: digest, size: -1)
                ])),
                .invalidSize(uri: manifest.uri, size: -1)
            ),
        ]
        for (skill, expected) in cases {
            #expect(throws: expected) { try skill.validate() }
        }
    }

    @Test(
        "Names follow the Agent Skills rules",
        arguments: [
            ("pdf-processing", true), ("a", true), ("v2", true), ("données", true),
            ("", false), ("-a", false), ("a-", false), ("a--b", false), ("A", false),
            ("a_b", false), ("a b", false), (String(repeating: "a", count: 65), false),
        ]
    )
    func nameRules(name: String, valid: Bool) {
        #expect(Skill.isValidName(name) == valid)
    }

    // MARK: - URI rules

    @Test("URI normalization decodes only unreserved escapes")
    func uriNormalization() {
        #expect(SkillURI.normalized("SKILL://a/%7e%41") == "skill://a/~A")
        #expect(SkillURI.normalized("skill://a/b%2fc") == "skill://a/b%2Fc")
        #expect(SkillURI.normalized("skill://a/%E2%82%AC") == "skill://a/%E2%82%AC")
    }

    @Test("References resolve inside the skill root and never escape it")
    func referenceResolution() {
        let root = "skill://acme/pdf"
        #expect(SkillURI.resolve("SKILL.md", against: root) == "skill://acme/pdf/SKILL.md")
        #expect(SkillURI.resolve("./refs/../FORMS.md", against: root) == "skill://acme/pdf/FORMS.md")
        #expect(SkillURI.resolve("../other/SKILL.md", against: root) == nil)
        #expect(SkillURI.resolve("/etc/passwd", against: root) == nil)
        #expect(SkillURI.resolve("a.md?x", against: root) == nil)
        #expect(SkillURI.resolve("", against: root) == nil)
        #expect(SkillURI.resolve("skill://x/y", against: root) == "skill://x/y")
        #expect(SkillURI.resolve("refs/Purchase Order.md", against: root) == "skill://acme/pdf/refs/Purchase%20Order.md")
        #expect(SkillURI.resolve("refs/Q%26A.md", against: root) == "skill://acme/pdf/refs/Q%26A.md")
        #expect(SkillURI.resolve("café.md", against: root) == "skill://acme/pdf/caf%C3%A9.md")
    }
}
