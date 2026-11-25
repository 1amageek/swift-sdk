import Foundation

/// URI rules shared by skill validation, catalogs, and verified reads.
///
/// Skill URIs are hierarchical: `<scheme>://<segment>/…/<segment>`. The first
/// segment is the authority and has no special meaning for skills.
enum SkillURI {
    /// The characters RFC 3986 calls unreserved.
    private static let unreserved: Set<UInt8> = {
        var bytes = Set<UInt8>()
        bytes.formUnion(UInt8(ascii: "A")...UInt8(ascii: "Z"))
        bytes.formUnion(UInt8(ascii: "a")...UInt8(ascii: "z"))
        bytes.formUnion(UInt8(ascii: "0")...UInt8(ascii: "9"))
        bytes.formUnion([UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~")])
        return bytes
    }()

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// Splits a hierarchical URI into its lowercased scheme and path segments.
    ///
    /// - Returns: `nil` for an opaque URI, an empty segment list, or a URI
    ///   with a query or fragment.
    static func split(_ uri: String) -> (scheme: String, segments: [Substring])? {
        guard let separator = uri.range(of: "://") else { return nil }
        let scheme = uri[..<separator.lowerBound]
        guard let first = scheme.first, first.isASCII, first.isLetter,
            scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else {
            return nil
        }
        let rest = uri[separator.upperBound...]
        guard !rest.isEmpty, !rest.contains("?"), !rest.contains("#") else { return nil }
        return (scheme.lowercased(), rest.split(separator: "/", omittingEmptySubsequences: false))
    }

    /// The comparison key of a URI: lowercased scheme, unreserved escapes
    /// decoded, and remaining escapes in uppercase hex.
    ///
    /// Reserved escapes such as `%2F` stay encoded, so an escaped separator
    /// never becomes a path separator.
    static func normalized(_ uri: String) -> String {
        guard let separator = uri.range(of: "://") else { return uri }
        let scheme = uri[..<separator.lowerBound].lowercased()
        let rest = Array(uri[separator.upperBound...].utf8)
        var output: [UInt8] = []
        output.reserveCapacity(rest.count)
        var index = 0
        while index < rest.count {
            let byte = rest[index]
            if byte == UInt8(ascii: "%"), index + 2 < rest.count,
                let high = hexValue(rest[index + 1]), let low = hexValue(rest[index + 2])
            {
                let decoded = high << 4 | low
                if unreserved.contains(decoded) {
                    output.append(decoded)
                } else {
                    output.append(UInt8(ascii: "%"))
                    output.append(hexDigits[Int(high)])
                    output.append(hexDigits[Int(low)])
                }
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        return scheme + "://" + String(decoding: output, as: UTF8.self)
    }

    /// Whether `uri` names a file strictly inside the directory `root`.
    ///
    /// The relative part must be non-empty and contain no empty, `.`, or
    /// `..` segment after normalization, and the URI must have no query or
    /// fragment.
    static func isStrictlyInside(_ uri: String, root: String) -> Bool {
        guard split(uri) != nil else { return false }
        let prefix = normalized(root) + "/"
        let candidate = normalized(uri)
        guard candidate.hasPrefix(prefix) else { return false }
        let relative = candidate.dropFirst(prefix.count)
        return !relative.isEmpty
            && relative.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Characters a URI path segment may contain unencoded (RFC 3986
    /// `pchar` plus `%` for existing escapes).
    private static let pathCharacters: Set<UInt8> = unreserved.union(
        "!$&'()*+,;=:@%".utf8
    )

    /// Resolves a reference against a skill root.
    ///
    /// An absolute reference (with `://`) is returned unchanged. A relative
    /// reference is joined to the root after removing dot segments; bytes
    /// that a path segment cannot contain, such as spaces, are
    /// percent-encoded the way a browser encodes a typed path.
    ///
    /// - Returns: `nil` when a relative reference has a query or fragment,
    ///   or when its dot segments leave the root.
    static func resolve(_ reference: String, against root: String) -> String? {
        if reference.contains("://") { return reference }
        guard !reference.isEmpty, !reference.contains("?"), !reference.contains("#"),
            !reference.hasPrefix("/")
        else {
            return nil
        }
        var segments: [Substring] = []
        for segment in reference.split(separator: "/", omittingEmptySubsequences: false) {
            switch segment {
            case "", ".":
                continue
            case "..":
                guard !segments.isEmpty else { return nil }
                segments.removeLast()
            default:
                segments.append(Substring(encode(segment, keeping: pathCharacters)))
            }
        }
        guard !segments.isEmpty else { return nil }
        return root + "/" + segments.joined(separator: "/")
    }

    /// Percent-encodes every byte outside the RFC 3986 unreserved set.
    static func encodeSegment(_ segment: String) -> String {
        encode(Substring(segment), keeping: unreserved)
    }

    private static func encode(_ segment: Substring, keeping allowed: Set<UInt8>) -> String {
        var output: [UInt8] = []
        for byte in segment.utf8 {
            if allowed.contains(byte) {
                output.append(byte)
            } else {
                output.append(UInt8(ascii: "%"))
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Fully percent-decodes one path segment.
    static func decodeSegment(_ segment: Substring) -> String? {
        String(segment).removingPercentEncoding
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
