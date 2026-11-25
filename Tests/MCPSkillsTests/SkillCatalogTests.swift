import Foundation
import MCP
import Testing

@testable import MCPSkills

@Suite("Skill catalog", .timeLimit(.minutes(1)))
struct SkillCatalogTests {
    @Test("Discovers top-level and nested skills with complete manifests")
    func discovery() throws {
        let catalog = try SkillFixtures.catalog()

        #expect(catalog.skills.map(\.uri) == [
            "skill://acme/billing/refunds/SKILL.md",
            "skill://acme/billing/refunds/escalation/SKILL.md",
            "skill://pdf-processing/SKILL.md",
        ])
        #expect(catalog.issues.isEmpty)
        for skill in catalog.skills {
            try skill.validate()
        }

        let refunds = try #require(catalog.skills.first { $0.name == "refunds" })
        guard case .listed(let refundFiles) = refunds.resources else {
            Issue.record("Expected a listed manifest")
            return
        }
        // A nested skill's files also belong to the enclosing skill.
        #expect(refundFiles.map(\.uri) == [
            "skill://acme/billing/refunds/SKILL.md",
            "skill://acme/billing/refunds/escalation/SKILL.md",
            "skill://acme/billing/refunds/escalation/steps.txt",
        ])

        let pdf = try #require(catalog.skills.first { $0.name == "pdf-processing" })
        #expect(pdf.frontmatter.fields["license"] == .string("MIT"))
        guard case .listed(let pdfFiles) = pdf.resources else {
            Issue.record("Expected a listed manifest")
            return
        }
        #expect(pdfFiles.contains { $0.uri == "skill://pdf-processing/references/Purchase%20Order.md" })
        #expect(!pdfFiles.contains { $0.uri.contains("private-notes") })
    }

    @Test("Manifest digests and sizes describe the served bytes")
    func digestsMatchContents() async throws {
        let catalog = try SkillFixtures.catalog()
        for skill in catalog.skills {
            guard case .listed(let files) = skill.resources else { continue }
            for file in files {
                let contents = try #require(try await catalog.contents(of: file.uri))
                let content = try #require(contents.first)
                let data: Data
                if let text = content.text {
                    data = Data(text.utf8)
                } else {
                    let blob = try #require(content.blob)
                    data = try #require(Data(base64Encoded: blob))
                }
                #expect(data.count == file.size)
                #expect(SkillDigest.sha256(of: data) == file.digest)
            }
        }
    }

    @Test("Lossless UTF-8 is text, including BOM and CRLF; other bytes are blobs")
    func textAndBlob() async throws {
        let catalog = try SkillFixtures.catalog()
        let manifest = try #require(try await catalog.contents(of: "skill://acme/billing/refunds/SKILL.md")?.first)
        #expect(manifest.text?.hasPrefix("\u{FEFF}---\r\n") == true)
        #expect(manifest.mimeType == "text/markdown")

        let logo = try #require(try await catalog.contents(of: "skill://pdf-processing/assets/logo.png")?.first)
        #expect(logo.text == nil)
        #expect(logo.blob != nil)
        #expect(logo.mimeType == "image/png")
    }

    @Test("Lookups accept equivalent URI spellings and ignore unknown URIs")
    func lookups() async throws {
        let catalog = try SkillFixtures.catalog()
        #expect(try await catalog.skill(at: "SKILL://pdf-processing/SKILL.md")?.name == "pdf-processing")
        #expect(try await catalog.skill(at: "skill://pdf-processing/%53KILL.md")?.name == "pdf-processing")
        #expect(try await catalog.skill(at: "skill://missing/SKILL.md") == nil)
        #expect(try await catalog.contents(of: "skill://pdf-processing/missing.md") == nil)
        #expect(try await catalog.contents(of: "skill://pdf-processing/.private-notes.md") == nil)
    }

    @Test("Pagination is position-independent and rejects foreign cursors")
    func pagination() async throws {
        let catalog = try SkillFixtures.catalog(options: .init(pageSize: 2))
        let first = try await catalog.skills(after: nil)
        #expect(first.items.count == 2)
        let cursor = try #require(first.nextCursor)
        let second = try await catalog.skills(after: cursor)
        #expect(second.items.map(\.name) == ["pdf-processing"])
        #expect(second.nextCursor == nil)

        await #expect(throws: MCPError.self) {
            try await catalog.skills(after: "not-a-cursor")
        }
    }

    @Test("Directories list direct children, with subdirectories marked")
    func directories() async throws {
        let catalog = try SkillFixtures.catalog()
        let root = try #require(try await catalog.directory(at: "skill://pdf-processing", after: nil))
        #expect(root.items.map(\.uri) == [
            "skill://pdf-processing/SKILL.md",
            "skill://pdf-processing/assets",
            "skill://pdf-processing/references",
        ])
        #expect(root.items.first { $0.name == "references" }?.mimeType == SkillsExtension.directoryMimeType)
        #expect(root.items.first { $0.name == "SKILL.md" }?.size != nil)

        let references = try #require(
            try await catalog.directory(at: "skill://pdf-processing/references", after: nil)
        )
        #expect(references.items.map(\.name) == ["FORMS.md", "Purchase Order.md"])
        #expect(try await catalog.directory(at: "skill://pdf-processing/SKILL.md", after: nil) == nil)
        #expect(try await catalog.directory(at: "skill://acme", after: nil) == nil)
    }

    @Test("Strict policy reports every invalid skill")
    func strictPolicy() throws {
        var files = SkillFixtures.files
        files["Bad-Name/SKILL.md"] = SkillFixtures.manifest(name: "Bad-Name")
        files["mismatch/SKILL.md"] = SkillFixtures.manifest(name: "other")
        files["broken/SKILL.md"] = Data("no frontmatter".utf8)
        files["SKILL.md"] = SkillFixtures.manifest(name: "root")

        do {
            _ = try SkillFixtures.catalog(files: files)
            Issue.record("Expected strict construction to fail")
        } catch SkillCatalogError.invalidSkills(let issues) {
            #expect(Set(issues.map(\.path)) == ["Bad-Name", "mismatch", "broken", "SKILL.md"])
        }
    }

    @Test("Skipping policy excludes invalid skills and keeps the rest")
    func skippingPolicy() throws {
        var files = SkillFixtures.files
        files["mismatch/SKILL.md"] = SkillFixtures.manifest(name: "other")
        let catalog = try SkillFixtures.catalog(
            files: files,
            options: .init(policy: .skippingInvalidSkills)
        )
        #expect(catalog.skills.count == 3)
        #expect(catalog.issues.map(\.path) == ["mismatch"])
    }

    @Test("Skills beyond the limits are issues")
    func limits() throws {
        let options = SkillCatalog.Options(
            limits: SkillLimits(maxFiles: 2, maxBytes: 1024),
            policy: .skippingInvalidSkills
        )
        let catalog = try SkillFixtures.catalog(options: options)
        #expect(catalog.skills.map(\.name) == ["escalation"])
        let pdfBytes = totalBytes("pdf-processing/")
        #expect(catalog.issues.contains {
            $0.path == "pdf-processing" && $0.kind == .limitExceeded(files: 4, bytes: pdfBytes)
        })
    }

    @Test("A base URI with an authority prefixes every skill")
    func baseURI() throws {
        let catalog = try SkillCatalog(
            files: ["pdf/SKILL.md": SkillFixtures.manifest(name: "pdf")],
            options: .init(baseURI: "skill://acme")
        )
        #expect(catalog.skills.map(\.uri) == ["skill://acme/pdf/SKILL.md"])
        #expect(throws: SkillCatalogError.invalidBaseURI("acme")) {
            try SkillCatalog(files: [:], options: .init(baseURI: "acme"))
        }
    }

    @Test("Loading from disk skips hidden entries and refuses symbolic links")
    func fileSystem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-catalog-\(UUID().uuidString)")
        defer { removeTemporaryDirectory(root) }
        for (path, data) in SkillFixtures.files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        let fromDisk = try SkillCatalog(directory: root)
        let inMemory = try SkillFixtures.catalog()
        #expect(fromDisk.skills == inMemory.skills)

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("pdf-processing/link.md"),
            withDestinationURL: root.appendingPathComponent("pdf-processing/references/FORMS.md")
        )
        do {
            _ = try SkillCatalog(directory: root)
            Issue.record("Expected a symbolic link to fail strict loading")
        } catch SkillCatalogError.invalidSkills(let issues) {
            #expect(issues.contains { $0.path == "pdf-processing/link.md" && $0.kind == .unsupportedFile })
        }
        let skipping = try SkillCatalog(directory: root, options: .init(policy: .skippingInvalidSkills))
        #expect(!skipping.skills.contains { $0.name == "pdf-processing" })
    }

    private func totalBytes(_ prefix: String) -> Int {
        SkillFixtures.files.filter { $0.key.hasPrefix(prefix) && !$0.key.contains("/.") }
            .reduce(0) { $0 + $1.value.count }
    }

    private func removeTemporaryDirectory(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Could not remove \(url.path): \(error)")
        }
    }
}
