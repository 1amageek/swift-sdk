import MCP
import Yams

/// A parsed `SKILL.md`: its frontmatter and markdown body.
public struct SkillMarkdown: Hashable, Sendable {
    /// The frontmatter fields as JSON values.
    public let frontmatter: SkillFrontmatter
    /// The markdown after the closing delimiter, with line endings
    /// normalized to LF.
    public let body: String

    /// The maximum nesting depth of a frontmatter value.
    static let maxDepth = 64

    /// Parses a `SKILL.md` document.
    ///
    /// A leading byte order mark is ignored and CRLF line endings are
    /// accepted. The frontmatter is the text between an opening `---` line
    /// and the next `---` line. Plain scalars resolve with the YAML 1.2 core
    /// schema; quoted and block scalars and `!`/`!!str` scalars are strings.
    /// Anchors, aliases, other tags, non-string or duplicate keys, and
    /// non-finite or out-of-range numbers fail.
    public init(parsing document: String) throws(SkillFrontmatterError) {
        var text = document
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, Self.isDelimiter(first) else {
            throw .missingOpeningDelimiter
        }
        guard let closing = lines.indices.dropFirst().first(where: { Self.isDelimiter(lines[$0]) })
        else {
            throw .missingClosingDelimiter
        }
        let yaml = lines[1..<closing].joined(separator: "\n")
        let fields = try Self.parseMapping(yaml)
        self.frontmatter = try SkillFrontmatter(fields: fields)
        self.body = lines[(closing + 1)...].joined(separator: "\n")
    }

    private static func isDelimiter(_ line: Substring) -> Bool {
        guard line.hasPrefix("---") else { return false }
        return line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Resolves implicit plain scalars with the YAML 1.2 core schema.
    ///
    /// Yams resolves a tag in place the first time a node is hashed or
    /// compared, so the resolver itself must apply the core schema for the
    /// resolved tag to be correct at any point.
    private static let coreSchemaResolver: Resolver = {
        do {
            return try Resolver.basic
                .appending(.null, "^(?:~|null|Null|NULL|)$")
                .appending(.bool, "^(?:true|True|TRUE|false|False|FALSE)$")
                .appending(.int, "^(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)$")
                .appending(
                    .float,
                    "^(?:[-+]?(?:\\.[0-9]+|[0-9]+(?:\\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?"
                        + "|[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))$"
                )
        } catch {
            preconditionFailure("The YAML core schema patterns are valid: \(error)")
        }
    }()

    private static func parseMapping(_ yaml: String) throws(SkillFrontmatterError) -> [String: Value] {
        let parser: Parser
        let root: Node?
        do {
            parser = try Parser(yaml: yaml, resolver: coreSchemaResolver)
            root = try parser.singleRoot()
        } catch {
            throw .invalidYAML(String(describing: error))
        }
        // Node anchors are weak references owned by the parser, so the parser
        // stays alive until the tree has been checked for anchors.
        return try withExtendedLifetime(parser) { () throws(SkillFrontmatterError) -> [String: Value] in
            guard let root, case .object(let fields) = try value(of: root, depth: 0) else {
                throw .notAMapping
            }
            return fields
        }
    }

    private static func value(of node: Node, depth: Int) throws(SkillFrontmatterError) -> Value {
        guard depth < maxDepth else { throw .nestingTooDeep }
        guard node.anchor == nil else { throw .anchorsNotSupported }
        switch node {
        case .scalar(let scalar):
            return try value(of: scalar)
        case .sequence(let sequence):
            try requireUntagged(sequence.tag, allowing: .seq)
            var values: [Value] = []
            values.reserveCapacity(sequence.count)
            for element in sequence {
                values.append(try value(of: element, depth: depth + 1))
            }
            return .array(values)
        case .mapping(let mapping):
            try requireUntagged(mapping.tag, allowing: .map)
            var fields: [String: Value] = [:]
            for (keyNode, valueNode) in mapping {
                guard keyNode.anchor == nil else { throw .anchorsNotSupported }
                guard case .scalar(let keyScalar) = keyNode,
                    case .string(let key) = try value(of: keyScalar)
                else {
                    throw .nonStringKey
                }
                guard fields[key] == nil else { throw .duplicateKey(key) }
                fields[key] = try value(of: valueNode, depth: depth + 1)
            }
            return .object(fields)
        case .alias:
            throw .anchorsNotSupported
        }
    }

    private static func requireUntagged(
        _ tag: Tag,
        allowing name: Tag.Name
    ) throws(SkillFrontmatterError) {
        let raw = tag.rawValue
        guard raw.isEmpty || raw == "!" || raw == name.rawValue else {
            throw .unsupportedTag(raw)
        }
    }

    private static func value(of scalar: Node.Scalar) throws(SkillFrontmatterError) -> Value {
        let tag = scalar.tag.rawValue
        guard scalar.style == .plain else {
            // Quoted and block scalars are strings in the core schema; their
            // implicit tag may already be resolved from the text alone.
            guard [
                "", "!", Tag.Name.str.rawValue, Tag.Name.null.rawValue,
                Tag.Name.bool.rawValue, Tag.Name.int.rawValue, Tag.Name.float.rawValue,
            ].contains(tag) else {
                throw .unsupportedTag(tag)
            }
            return .string(scalar.string)
        }
        switch tag {
        case "":
            return try coreSchemaValue(scalar.string)
        case "!", Tag.Name.str.rawValue:
            return .string(scalar.string)
        case Tag.Name.null.rawValue, Tag.Name.bool.rawValue, Tag.Name.int.rawValue,
            Tag.Name.float.rawValue:
            let value = try coreSchemaValue(scalar.string)
            guard Self.kind(of: value) == tag else { throw .unsupportedTag(tag) }
            return value
        default:
            throw .unsupportedTag(tag)
        }
    }

    private static func kind(of value: Value) -> String? {
        switch value {
        case .null: Tag.Name.null.rawValue
        case .bool: Tag.Name.bool.rawValue
        case .int: Tag.Name.int.rawValue
        case .double: Tag.Name.float.rawValue
        default: nil
        }
    }

    /// Resolves a plain scalar with the YAML 1.2 core schema.
    private static func coreSchemaValue(_ text: String) throws(SkillFrontmatterError) -> Value {
        switch text {
        case "", "~", "null", "Null", "NULL":
            return .null
        case "true", "True", "TRUE":
            return .bool(true)
        case "false", "False", "FALSE":
            return .bool(false)
        default:
            break
        }
        if let integer = try integerValue(text) {
            return .int(integer)
        }
        if isCoreFloat(text) {
            guard let double = Double(text), double.isFinite else {
                throw .unrepresentableNumber(text)
            }
            return .double(double)
        }
        if nonFiniteSpellings.contains(text) {
            throw .unrepresentableNumber(text)
        }
        return .string(text)
    }

    /// Core-schema infinity and not-a-number spellings, which JSON cannot carry.
    private static let nonFiniteSpellings: Set<String> = [
        ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF",
        "-.inf", "-.Inf", "-.INF", ".nan", ".NaN", ".NAN",
    ]

    /// Core-schema integers: `[-+]?[0-9]+`, `0o[0-7]+`, `0x[0-9a-fA-F]+`.
    private static func integerValue(_ text: String) throws(SkillFrontmatterError) -> Int? {
        let digits: Substring
        let radix: Int
        if text.hasPrefix("0o") {
            digits = text.dropFirst(2)
            radix = 8
            guard !digits.isEmpty, digits.allSatisfy({ ("0"..."7").contains($0) }) else { return nil }
        } else if text.hasPrefix("0x") {
            digits = text.dropFirst(2)
            radix = 16
            guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return nil }
        } else {
            let unsigned = text.first == "-" || text.first == "+" ? text.dropFirst() : Substring(text)
            guard !unsigned.isEmpty, unsigned.allSatisfy({ ("0"..."9").contains($0) }) else {
                return nil
            }
            guard let value = Int(text) else { throw .unrepresentableNumber(text) }
            return value
        }
        guard let value = Int(digits, radix: radix) else { throw .unrepresentableNumber(text) }
        return value
    }

    /// Core-schema floats: `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`.
    private static func isCoreFloat(_ text: String) -> Bool {
        var characters = Substring(text)
        if characters.first == "-" || characters.first == "+" {
            characters = characters.dropFirst()
        }
        let mantissaEnd = characters.firstIndex(where: { $0 == "e" || $0 == "E" }) ?? characters.endIndex
        let mantissa = characters[..<mantissaEnd]
        let isDigit: (Character) -> Bool = { ("0"..."9").contains($0) }
        let parts = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard !parts[0].isEmpty, parts[0].allSatisfy(isDigit) else { return false }
        case 2:
            let integerPart = parts[0]
            let fraction = parts[1]
            guard integerPart.allSatisfy(isDigit), fraction.allSatisfy(isDigit),
                !(integerPart.isEmpty && fraction.isEmpty)
            else {
                return false
            }
        default:
            return false
        }
        guard mantissaEnd != characters.endIndex else {
            // A plain integer is handled by `integerValue`; only a dotted
            // mantissa is a float without an exponent.
            return parts.count == 2
        }
        var exponent = characters[characters.index(after: mantissaEnd)...]
        if exponent.first == "-" || exponent.first == "+" {
            exponent = exponent.dropFirst()
        }
        return !exponent.isEmpty && exponent.allSatisfy(isDigit)
    }
}
