import Foundation
import MCP

/// Opaque, position-independent pagination over URI-sorted items.
///
/// A cursor names the last URI of the previous page, so a page is always the
/// items strictly after it, regardless of the page size used to issue it.
enum SkillCursor {
    private static let prefix = "after:"

    static func encode(after key: String) -> String {
        Data((prefix + key).utf8).base64EncodedString()
    }

    static func decode(_ cursor: String) throws(MCPError) -> String {
        guard let data = Data(base64Encoded: cursor),
            let text = String(data: data, encoding: .utf8),
            text.hasPrefix(prefix)
        else {
            throw .invalidParams("Invalid cursor")
        }
        return String(text.dropFirst(prefix.count))
    }

    /// One page of `items`, which must be sorted by `key`.
    static func page<Element: Sendable>(
        of items: [Element],
        key: (Element) -> String,
        after cursor: String?,
        pageSize: Int
    ) throws(MCPError) -> SkillSourcePage<Element> {
        var start = items.startIndex
        if let cursor {
            let last = try decode(cursor)
            start = items.partitioningIndex { key($0) > last }
        }
        let end = items.index(start, offsetBy: pageSize, limitedBy: items.endIndex) ?? items.endIndex
        let page = Array(items[start..<end])
        let nextCursor = end < items.endIndex ? page.last.map { encode(after: key($0)) } : nil
        return SkillSourcePage(items: page, nextCursor: nextCursor)
    }
}

extension Array {
    /// The first index whose element satisfies `predicate`, assuming the
    /// array is partitioned with all non-satisfying elements first.
    fileprivate func partitioningIndex(where predicate: (Element) -> Bool) -> Index {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(self[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}
