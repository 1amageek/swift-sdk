import Foundation
import MCP

/// Builds the immutable contents of a ``SkillCatalog`` from its input tree.
struct SkillCatalogBuilder {
    struct Snapshot {
        let skills: [Skill]
        let issues: [SkillCatalogIssue]
        let files: [String: SkillCatalog.StoredFile]
        let directories: [String: [Resource]]
    }

    private let options: SkillCatalog.Options
    private let manifestName = SkillsExtension.manifestFileName

    init(options: SkillCatalog.Options) {
        self.options = options
    }

    func build(_ entries: [SkillCatalogEntry]) throws(SkillCatalogError) -> Snapshot {
        let prefix = try uriPrefix()
        var fileData: [[String]: Data] = [:]
        var unsupported: [[String]] = []
        for entry in entries {
            switch entry.content {
            case .file(let data): fileData[entry.path] = data
            case .unsupported: unsupported.append(entry.path)
            }
        }

        var issues: [SkillCatalogIssue] = []
        var roots: [[String]] = []
        for path in fileData.keys where path.last == manifestName {
            let root = Array(path.dropLast())
            if root.isEmpty {
                issues.append(SkillCatalogIssue(path: manifestName, kind: .manifestAtRoot))
            } else {
                roots.append(root)
            }
        }
        roots.sort { $0.lexicographicallyPrecedes($1) }

        for path in unsupported where !roots.contains(where: { Self.isMember(path, of: $0) }) {
            issues.append(SkillCatalogIssue(path: path.joined(separator: "/"), kind: .unsupportedFile))
        }

        var digests: [[String]: SkillDigest] = [:]
        var validSkills: [(root: [String], skill: Skill, members: [[String]])] = []
        for root in roots {
            let members = fileData.keys.filter { Self.isMember($0, of: root) }
            let rootIssues = unsupported.filter { Self.isMember($0, of: root) }.map {
                SkillCatalogIssue(path: $0.joined(separator: "/"), kind: .unsupportedFile)
            }
            let result = makeSkill(
                root: root,
                members: members,
                fileData: fileData,
                prefix: prefix,
                digests: &digests
            )
            switch result {
            case .skill(let skill) where rootIssues.isEmpty:
                validSkills.append((root, skill, members))
            case .skill:
                issues.append(contentsOf: rootIssues)
            case .issue(let issue):
                issues.append(contentsOf: rootIssues)
                issues.append(issue)
            }
        }

        if options.policy == .strict, !issues.isEmpty {
            throw .invalidSkills(issues)
        }

        var files: [String: SkillCatalog.StoredFile] = [:]
        var children: [[String]: Set<[String]>] = [:]
        var directoryPaths = Set<[String]>()
        for (root, _, members) in validSkills {
            directoryPaths.insert(root)
            for member in members {
                let uri = self.uri(for: member, prefix: prefix)
                files[SkillURI.normalized(uri)] = SkillCatalog.StoredFile(
                    uri: uri,
                    data: fileData[member]!,
                    mimeType: SkillMediaType.forFileName(member.last!)
                )
                var child = member
                while child.count > root.count {
                    let parent = Array(child.dropLast())
                    children[parent, default: []].insert(child)
                    directoryPaths.insert(parent)
                    child = parent
                }
            }
        }

        var directories: [String: [Resource]] = [:]
        for directory in directoryPaths {
            let resources = (children[directory] ?? []).map { child -> Resource in
                let uri = self.uri(for: child, prefix: prefix)
                if let data = fileData[child] {
                    return Resource(
                        name: child.last!,
                        uri: uri,
                        mimeType: SkillMediaType.forFileName(child.last!),
                        size: data.count
                    )
                }
                return Resource(
                    name: child.last!,
                    uri: uri,
                    mimeType: SkillsExtension.directoryMimeType
                )
            }.sorted { $0.uri < $1.uri }
            directories[SkillURI.normalized(self.uri(for: directory, prefix: prefix))] = resources
        }

        return Snapshot(
            skills: validSkills.map(\.skill).sorted { $0.uri < $1.uri },
            issues: issues,
            files: files,
            directories: directories
        )
    }

    private enum Outcome {
        case skill(Skill)
        case issue(SkillCatalogIssue)
    }

    private func makeSkill(
        root: [String],
        members: [[String]],
        fileData: [[String]: Data],
        prefix: String,
        digests: inout [[String]: SkillDigest]
    ) -> Outcome {
        let rootPath = root.joined(separator: "/")
        let totalBytes = members.reduce(0) { $0 + fileData[$1]!.count }
        guard members.count <= options.limits.maxFiles, totalBytes <= options.limits.maxBytes else {
            return .issue(
                SkillCatalogIssue(
                    path: rootPath,
                    kind: .limitExceeded(files: members.count, bytes: totalBytes)
                )
            )
        }
        guard let manifestText = LosslessUTF8.decode(fileData[root + [manifestName]]!) else {
            return .issue(SkillCatalogIssue(path: rootPath, kind: .manifestNotUTF8))
        }
        let markdown: SkillMarkdown
        do {
            markdown = try SkillMarkdown(parsing: manifestText)
        } catch {
            return .issue(SkillCatalogIssue(path: rootPath, kind: .invalidFrontmatter(error)))
        }
        let resources = members.map { member -> SkillResource in
            let data = fileData[member]!
            let digest = digests[member] ?? SkillDigest.sha256(of: data)
            digests[member] = digest
            return SkillResource(
                uri: uri(for: member, prefix: prefix),
                digest: digest,
                size: data.count
            )
        }.sorted { $0.uri < $1.uri }
        let skill = Skill(
            uri: uri(for: root + [manifestName], prefix: prefix),
            frontmatter: markdown.frontmatter,
            resources: .listed(resources)
        )
        do {
            try skill.validate()
        } catch {
            return .issue(SkillCatalogIssue(path: rootPath, kind: .invalidEntry(error)))
        }
        return .skill(skill)
    }

    /// The base URI with a trailing separator, so segments can be appended.
    private func uriPrefix() throws(SkillCatalogError) -> String {
        let base = options.baseURI
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard SkillURI.split(prefix + "x") != nil else {
            throw .invalidBaseURI(base)
        }
        return prefix
    }

    private func uri(for path: [String], prefix: String) -> String {
        prefix + path.map(SkillURI.encodeSegment).joined(separator: "/")
    }

    private static func isMember(_ path: [String], of root: [String]) -> Bool {
        path.count > root.count && path.starts(with: root)
    }
}

