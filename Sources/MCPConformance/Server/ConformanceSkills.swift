import Foundation
import MCPSkills

/// The SEP-2640 fixture catalog.
///
/// Two skills, each with a subdirectory in its root, served one entry per
/// page so the conformance referee exercises pagination and directory reads.
func makeConformanceSkillCatalog() throws(SkillCatalogError) -> SkillCatalog {
    let files: [String: String] = [
        "data-analysis/SKILL.md": """
            ---
            name: data-analysis
            description: Summarize tabular data with reproducible steps.
            license: Apache-2.0
            metadata:
              version: "1.0"
            ---
            # Data analysis

            Read [the guide](references/GUIDE.md) before starting.

            """,
        "data-analysis/references/GUIDE.md": "# Guide\n\nLoad the CSV, then describe each column.\n",
        "pdf-processing/SKILL.md": """
            ---
            name: pdf-processing
            description: Extract text and fill forms in PDF documents.
            ---
            # PDF processing

            Use [the forms reference](references/FORMS.md) for form fields.

            """,
        "pdf-processing/references/FORMS.md": "# Forms\n\nList every field before filling it.\n",
        "pdf-processing/scripts/extract.py": "print('extract')\n",
    ]
    return try SkillCatalog(
        files: files.mapValues { Data($0.utf8) },
        options: .init(pageSize: 1)
    )
}
