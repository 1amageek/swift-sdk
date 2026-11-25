/// MIME types for skill files, by file extension.
///
/// An unknown extension has no MIME type; the field is omitted rather than
/// guessed.
enum SkillMediaType {
    private static let byExtension: [String: String] = [
        "md": "text/markdown",
        "markdown": "text/markdown",
        "txt": "text/plain",
        "json": "application/json",
        "yaml": "application/yaml",
        "yml": "application/yaml",
        "toml": "application/toml",
        "xml": "application/xml",
        "html": "text/html",
        "css": "text/css",
        "csv": "text/csv",
        "js": "text/javascript",
        "mjs": "text/javascript",
        "ts": "text/x-typescript",
        "py": "text/x-python",
        "sh": "text/x-shellscript",
        "rb": "text/x-ruby",
        "swift": "text/x-swift",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "svg": "image/svg+xml",
        "pdf": "application/pdf",
        "zip": "application/zip",
    ]

    static func forFileName(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return byExtension[name[name.index(after: dot)...].lowercased()]
    }
}
