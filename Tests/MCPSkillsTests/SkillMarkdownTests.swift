import Foundation
import MCP
import Testing

@testable import MCPSkills

@Suite("SKILL.md frontmatter", .timeLimit(.minutes(1)))
struct SkillMarkdownTests {
    private func parse(_ yaml: String) throws -> [String: Value] {
        try SkillMarkdown(parsing: "---\nname: a\ndescription: d\n\(yaml)\n---\nBody\n").frontmatter.fields
    }

    @Test("Plain scalars resolve with the YAML 1.2 core schema")
    func coreSchemaTyping() throws {
        let fields = try parse(
            """
            yes_value: yes
            true_value: true
            upper_false: FALSE
            null_value: ~
            empty_value:
            decimal: -12
            octal: 0o17
            hex: 0x1F
            leading_zero: 010
            float: 1.5
            exponent: 1e3
            version: 1.2.3
            date: 2026-11-25
            """
        )
        #expect(fields["yes_value"] == .string("yes"))
        #expect(fields["true_value"] == .bool(true))
        #expect(fields["upper_false"] == .bool(false))
        #expect(fields["null_value"] == .null)
        #expect(fields["empty_value"] == .null)
        #expect(fields["decimal"] == .int(-12))
        #expect(fields["octal"] == .int(15))
        #expect(fields["hex"] == .int(31))
        #expect(fields["leading_zero"] == .int(10))
        #expect(fields["float"] == .double(1.5))
        #expect(fields["exponent"] == .double(1000))
        #expect(fields["version"] == .string("1.2.3"))
        #expect(fields["date"] == .string("2026-11-25"))
    }

    @Test("Quoted, block, and str-tagged scalars stay strings")
    func stringScalars() throws {
        let fields = try parse(
            """
            quoted: "true"
            single: '12'
            tagged: !!str 12
            explicit_int: !!int 7
            quoted_number: "7"
            nonspecific: ! 12
            block: |
              line one
              line two
            nested:
              list: [a, 1, "b"]
              map: {k: v}
            """
        )
        #expect(fields["quoted"] == .string("true"))
        #expect(fields["single"] == .string("12"))
        #expect(fields["tagged"] == .string("12"))
        #expect(fields["explicit_int"] == .int(7))
        #expect(fields["quoted_number"] == .string("7"))
        #expect(fields["nonspecific"] == .string("12"))
        #expect(fields["block"] == .string("line one\nline two\n"))
        #expect(
            fields["nested"]
                == .object([
                    "list": .array([.string("a"), .int(1), .string("b")]),
                    "map": .object(["k": .string("v")]),
                ])
        )
    }

    @Test("A byte order mark and CRLF line endings are accepted")
    func bomAndCRLF() throws {
        let markdown = try SkillMarkdown(
            parsing: "\u{FEFF}---\r\nname: a\r\ndescription: d\r\n---\r\n# Title\r\n"
        )
        #expect(markdown.frontmatter.name == "a")
        #expect(markdown.body == "# Title\n")
    }

    @Test("Unsupported YAML fails closed")
    func failClosed() {
        let cases: [(String, SkillFrontmatterError)] = [
            ("anchor: &x 1\nalias: *x", .anchorsNotSupported),
            ("anchored: &x {k: v}", .anchorsNotSupported),
            ("quoted_key_ok: 1\n2.5: float key", .nonStringKey),
            ("tagged: !!int abc", .unsupportedTag("tag:yaml.org,2002:int")),
            ("binary: !!binary aGVsbG8=", .unsupportedTag("tag:yaml.org,2002:binary")),
            ("custom: !thing x", .unsupportedTag("!thing")),
            ("1: numeric key", .nonStringKey),
            ("infinite: .inf", .unrepresentableNumber(".inf")),
            ("nan: .NaN", .unrepresentableNumber(".NaN")),
            ("big: 99999999999999999999", .unrepresentableNumber("99999999999999999999")),
        ]
        for (yaml, expected) in cases {
            #expect(throws: expected) { try parse(yaml) }
        }
        #expect(throws: SkillFrontmatterError.self) { try parse("name: again") }
    }

    @Test("Delimiters are required and the document must be a mapping")
    func delimiters() {
        #expect(throws: SkillFrontmatterError.missingOpeningDelimiter) {
            try SkillMarkdown(parsing: "name: a\n---\n")
        }
        #expect(throws: SkillFrontmatterError.missingClosingDelimiter) {
            try SkillMarkdown(parsing: "---\nname: a\ndescription: d\n")
        }
        #expect(throws: SkillFrontmatterError.notAMapping) {
            try SkillMarkdown(parsing: "---\n- a\n---\n")
        }
        #expect(throws: SkillFrontmatterError.missingField("description")) {
            try SkillMarkdown(parsing: "---\nname: a\n---\n")
        }
    }

    @Test("Comparison is structural, order-insensitive for keys, and numeric for numbers")
    func comparison() throws {
        let lhs = try SkillFrontmatter(fields: [
            "name": .string("a"), "description": .string("d"),
            "metadata": .object(["x": .int(1), "y": .string("z")]),
            "tags": .array([.string("one"), .string("two")]),
        ])
        let same = try SkillFrontmatter(fields: [
            "description": .string("d"), "name": .string("a"),
            "metadata": .object(["y": .string("z"), "x": .double(1)]),
            "tags": .array([.string("one"), .string("two")]),
        ])
        let different = try SkillFrontmatter(fields: [
            "name": .string("a"), "description": .string("changed"),
            "tags": .array([.string("two"), .string("one")]),
            "extra": .bool(true),
        ])
        #expect(try lhs.differences(from: same).isEmpty)
        #expect(try lhs.differences(from: different) == ["description", "extra", "metadata", "tags"])
    }

    @Test("Comparison normalizes values the way received entries are decoded")
    func comparisonNormalizesDataURLs() throws {
        let parsed = try SkillFrontmatter(fields: [
            "name": .string("a"), "description": .string("d"), "icon": .string("data:,hello"),
        ])
        let received = try JSONDecoder().decode(SkillFrontmatter.self, from: JSONEncoder().encode(parsed))
        #expect(try parsed.differences(from: received).isEmpty)
    }
}
