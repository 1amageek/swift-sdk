import Foundation

/// One entry of a catalog's input tree, addressed by path components
/// relative to the catalog root.
struct SkillCatalogEntry: Sendable {
    enum Content: Sendable {
        /// A regular file and its bytes.
        case file(Data)
        /// A symbolic link or special file, which is never served.
        case unsupported
    }

    let path: [String]
    let content: Content

    var displayPath: String { path.joined(separator: "/") }

    /// Whether any path component is hidden (starts with `.`).
    static func isHidden(_ component: String) -> Bool {
        component.hasPrefix(".")
    }
}
