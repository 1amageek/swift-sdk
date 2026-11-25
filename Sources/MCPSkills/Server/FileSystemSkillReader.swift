import Foundation
import SystemPackage

/// Reads a catalog directory into ``SkillCatalogEntry`` values.
///
/// Hidden entries are skipped. Symbolic links and special files are reported
/// as unsupported and never followed; regular files are opened with
/// `O_NOFOLLOW`, so a file replaced by a link after listing is refused.
enum FileSystemSkillReader {
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
    ]

    static func entries(in root: URL) throws(SkillCatalogError) -> [SkillCatalogEntry] {
        var entries: [SkillCatalogEntry] = []
        try collect(directory: root, path: [], into: &entries)
        return entries
    }

    private static func collect(
        directory: URL,
        path: [String],
        into entries: inout [SkillCatalogEntry]
    ) throws(SkillCatalogError) {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        } catch {
            throw .unreadable(path: directory.path, reason: error.localizedDescription)
        }
        for child in children {
            let name = child.lastPathComponent
            guard !SkillCatalogEntry.isHidden(name) else { continue }
            let childPath = path + [name]
            let values: URLResourceValues
            do {
                values = try child.resourceValues(forKeys: keys)
            } catch {
                throw .unreadable(path: child.path, reason: error.localizedDescription)
            }
            if values.isSymbolicLink == true {
                entries.append(SkillCatalogEntry(path: childPath, content: .unsupported))
            } else if values.isDirectory == true {
                try collect(directory: child, path: childPath, into: &entries)
            } else if values.isRegularFile == true {
                entries.append(SkillCatalogEntry(path: childPath, content: .file(try read(child))))
            } else {
                entries.append(SkillCatalogEntry(path: childPath, content: .unsupported))
            }
        }
    }

    private static func read(_ url: URL) throws(SkillCatalogError) -> Data {
        do {
            let descriptor = try FileDescriptor.open(
                FilePath(url.path),
                .readOnly,
                options: [.noFollow]
            )
            return try descriptor.closeAfter {
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = try buffer.withUnsafeMutableBytes { try descriptor.read(into: $0) }
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer[..<count])
                }
                return data
            }
        } catch {
            throw .unreadable(path: url.path, reason: String(describing: error))
        }
    }
}
