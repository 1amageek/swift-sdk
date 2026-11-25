import Foundation
import MCP

@testable import MCPSkills

/// In-memory skill trees shared by the MCPSkills tests.
enum SkillFixtures {
    static func manifest(name: String, description: String = "Does things.", extra: String = "") -> Data {
        Data("---\nname: \(name)\ndescription: \(description)\n\(extra)---\n# \(name)\n".utf8)
    }

    /// Two top-level skills, a nested skill, a binary file, a CRLF/BOM
    /// manifest, a file name that needs encoding, and hidden entries.
    static var files: [String: Data] {
        [
            "pdf-processing/SKILL.md": manifest(name: "pdf-processing", extra: "license: MIT\n"),
            "pdf-processing/references/FORMS.md": Data("# Forms\n".utf8),
            "pdf-processing/references/Purchase Order.md": Data("PO\n".utf8),
            "pdf-processing/assets/logo.png": Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]),
            "pdf-processing/.private-notes.md": Data("hidden".utf8),
            "acme/billing/refunds/SKILL.md": Data(
                "\u{FEFF}---\r\nname: refunds\r\ndescription: Refund flows.\r\n---\r\nBody\r\n".utf8
            ),
            "acme/billing/refunds/escalation/SKILL.md": manifest(name: "escalation"),
            "acme/billing/refunds/escalation/steps.txt": Data("1. escalate\n".utf8),
            ".DS_Store": Data([0]),
        ]
    }

    static func catalog(
        files: [String: Data] = SkillFixtures.files,
        options: SkillCatalog.Options = .init()
    ) throws -> SkillCatalog {
        try SkillCatalog(files: files, options: options)
    }
}
