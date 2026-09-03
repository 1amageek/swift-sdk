import Foundation

/// A pure compiler and evaluator for the `x-mcp-header` tool-schema
/// extension. The resolver retains only an immutable path plan for one schema.
struct ToolHeaderResolver: Sendable {
    private enum HeaderValueKind: String, Sendable {
        case string
        case integer
        case boolean
    }

    private struct HeaderBinding: Sendable {
        let path: [String]
        let name: String
        let kind: HeaderValueKind
    }

    private struct ScanContext {
        var names: Set<String> = []
        var bindings: [HeaderBinding] = []
    }

    private let bindings: [HeaderBinding]

    var recognizedHeaderNames: Set<String> {
        Set(bindings.map { "Mcp-Param-\($0.name)".lowercased() })
    }

    init(schema: Value) throws {
        guard case .object(let fields) = schema else {
            throw ProtocolCoreError.invalidToolSchema("schema must be an object")
        }
        if let rawType = fields["type"] {
            guard rawType.stringValue == "object" else {
                throw ProtocolCoreError.invalidToolSchema("root schema type must be object")
            }
        }

        var context = ScanContext()
        try Self.scanSchema(schema, path: nil, context: &context)
        bindings = context.bindings
    }

    /// Compiles and evaluates a schema in one operation without retaining a
    /// resolver beyond the caller's operation.
    static func resolve(
        schema: Value,
        arguments: [String: Value]
    ) throws -> [String: String] {
        let resolver = try Self(schema: schema)
        return try resolver.resolve(arguments: arguments)
    }

    /// Resolves argument values at the exact statically reachable property
    /// paths captured by this schema.
    func resolve(arguments: [String: Value]) throws -> [String: String] {
        let values = try resolveValues(arguments: arguments)
        var headers: [String: String] = [:]
        headers.reserveCapacity(values.count)
        for (name, value) in values {
            headers[name] = try Self.encodeHeaderValue(value)
        }
        return headers
    }

    func resolveValues(arguments: [String: Value]) throws -> [String: Value] {
        var values: [String: Value] = [:]
        values.reserveCapacity(bindings.count)
        for binding in bindings {
            guard let value = Self.value(at: binding.path, in: arguments), !value.isNull else {
                continue
            }
            _ = try Self.encodeHeaderValue(value, as: binding.kind)
            values["Mcp-Param-\(binding.name)"] = value
        }
        return values
    }

    /// Resolves arguments supplied as a lossless protocol value.
    func resolve(arguments: Value) throws -> [String: String] {
        guard case .object(let fields) = arguments else {
            throw ProtocolCoreError.invalidHeaderValue("arguments must be an object")
        }
        return try resolve(arguments: fields)
    }

    /// Encodes a string, safe integer, or boolean for use in an HTTP header.
    static func encodeHeaderValue(_ value: Value) throws -> String {
        switch value {
        case .string(let string):
            return encodeString(string)
        case .int(let integer):
            guard isSafeInteger(integer) else {
                throw ProtocolCoreError.invalidHeaderValue("integer is outside the JavaScript safe range")
            }
            return String(integer)
        case .bool(let boolean):
            return boolean ? "true" : "false"
        default:
            throw ProtocolCoreError.invalidHeaderValue("only string, integer, and boolean values are supported")
        }
    }

    static func decodeHeaderValue(_ value: String) throws -> String {
        let prefix = "=?base64?"
        let suffix = "?="
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return value }
        let encoded = value.dropFirst(prefix.count).dropLast(suffix.count)
        guard let data = Data(base64Encoded: String(encoded)),
            let decoded = String(data: data, encoding: .utf8)
        else {
            throw ProtocolCoreError.invalidHeaderValue("invalid Base64 sentinel value")
        }
        return decoded
    }

    private final class PathNode {
        let parent: PathNode?
        let key: String
        let depth: Int

        init(parent: PathNode?, key: String) {
            self.parent = parent
            self.key = key
            self.depth = (parent?.depth ?? 0) + 1
        }

        func materialized() -> [String] {
            var path = Array(repeating: "", count: depth)
            var current: PathNode? = self
            var index = depth - 1
            while let node = current {
                path[index] = node.key
                index -= 1
                current = node.parent
            }
            return path
        }
    }

    private final class SchemaFrame {
        enum Phase {
            case fields
            case properties
        }

        let fields: [String: Value]
        let path: PathNode?
        var fieldIterator: Dictionary<String, Value>.Iterator
        var properties: [String: Value]?
        var propertyIterator: Dictionary<String, Value>.Iterator?
        var phase: Phase = .fields

        init(fields: [String: Value], path: PathNode?) {
            self.fields = fields
            self.path = path
            self.fieldIterator = fields.makeIterator()
        }
    }

    private final class ForbiddenFrame {
        enum Children {
            case object(Dictionary<String, Value>.Iterator)
            case array(IndexingIterator<[Value]>)
        }

        var children: Children?

        init(value: Value) {
            switch value {
            case .object(let fields):
                children = .object(fields.makeIterator())
            case .array(let values):
                children = .array(values.makeIterator())
            default:
                children = nil
            }
        }
    }

    private enum ScanFrame {
        case schema(SchemaFrame)
        case forbidden(ForbiddenFrame)
    }

    /// Walks a finite schema without recursion or an arbitrary node-count
    /// rejection. Schema frames keep one iterator per active depth; forbidden
    /// branches are inspected with the same bounded-depth worklist.
    private static func scanSchema(
        _ schema: Value,
        path: PathNode?,
        context: inout ScanContext
    ) throws {
        guard case .object(let fields) = schema else {
            throw ProtocolCoreError.invalidToolSchema("property schema must be an object")
        }
        if fields["x-mcp-header"] != nil {
            throw ProtocolCoreError.invalidToolSchema("x-mcp-header is only valid on properties")
        }

        var frames: [ScanFrame] = [.schema(SchemaFrame(fields: fields, path: path))]
        while !frames.isEmpty {
            switch frames[frames.count - 1] {
            case .schema(let frame):
                switch frame.phase {
                case .fields:
                    guard let (key, branch) = frame.fieldIterator.next() else {
                        frame.phase = .properties
                        if let properties = frame.properties {
                            frame.propertyIterator = properties.makeIterator()
                        }
                        continue
                    }

                    if key == "x-mcp-header" {
                        continue
                    }
                    if key == "properties" {
                        guard case .object(let properties) = branch else {
                            throw ProtocolCoreError.invalidToolSchema("properties must be an object")
                        }
                        frame.properties = properties
                        continue
                    }

                    frames.append(.forbidden(ForbiddenFrame(value: branch)))

                case .properties:
                    guard var iterator = frame.propertyIterator,
                        let (property, propertySchema) = iterator.next()
                    else {
                        frames.removeLast()
                        continue
                    }
                    frame.propertyIterator = iterator
                    let childPath = PathNode(parent: frame.path, key: property)
                    guard case .object(let childFields) = propertySchema else {
                        throw ProtocolCoreError.invalidToolSchema("property schema must be an object")
                    }
                    try validateSchemaNode(childFields, path: childPath, context: &context)
                    frames.append(.schema(SchemaFrame(fields: childFields, path: childPath)))
                }

            case .forbidden(let frame):
                guard let children = frame.children else {
                    frames.removeLast()
                    continue
                }

                switch children {
                case .object(var iterator):
                    guard let (key, child) = iterator.next() else {
                        frames.removeLast()
                        continue
                    }
                    frame.children = .object(iterator)
                    guard key != "x-mcp-header" else {
                        throw ProtocolCoreError.invalidToolSchema(
                            "x-mcp-header is not statically reachable through a schema branch"
                        )
                    }
                    frames.append(.forbidden(ForbiddenFrame(value: child)))

                case .array(var iterator):
                    guard let child = iterator.next() else {
                        frames.removeLast()
                        continue
                    }
                    frame.children = .array(iterator)
                    frames.append(.forbidden(ForbiddenFrame(value: child)))
                }
            }
        }
    }

    private static func validateSchemaNode(
        _ fields: [String: Value],
        path: PathNode,
        context: inout ScanContext
    ) throws {
        guard let marker = fields["x-mcp-header"] else { return }
        guard let name = marker.stringValue, !name.isEmpty,
            name.utf8.allSatisfy(isTChar)
        else {
            throw ProtocolCoreError.invalidToolSchema("x-mcp-header must be a non-empty HTTP token")
        }
        guard let type = fields["type"]?.stringValue,
            let kind = HeaderValueKind(rawValue: type)
        else {
            throw ProtocolCoreError.invalidToolSchema(
                "x-mcp-header requires a string, integer, or boolean property type"
            )
        }
        let normalized = name.lowercased()
        guard context.names.insert(normalized).inserted else {
            throw ProtocolCoreError.invalidToolSchema("x-mcp-header values must be case-insensitively unique")
        }
        context.bindings.append(HeaderBinding(path: path.materialized(), name: name, kind: kind))
    }

    private static func value(at path: [String], in arguments: [String: Value]) -> Value? {
        guard let first = path.first, var current = arguments[first] else { return nil }
        for key in path.dropFirst() {
            guard case .object(let fields) = current, let next = fields[key] else { return nil }
            current = next
        }
        return current
    }

    private static func encodeHeaderValue(
        _ value: Value,
        as kind: HeaderValueKind
    ) throws -> String {
        switch (kind, value) {
        case (.string, .string), (.integer, .int), (.boolean, .bool):
            return try encodeHeaderValue(value)
        default:
            throw ProtocolCoreError.invalidHeaderValue("argument type does not match its schema")
        }
    }

    private static func encodeString(_ string: String) -> String {
        let bytes = string.utf8
        let first = bytes.first
        let last = bytes.last
        let isSafe = bytes.allSatisfy { byte in
            (0x21...0x7E).contains(byte) || byte == 0x20 || byte == 0x09
        }
        let hasBoundaryWhitespace = first == 0x20 || first == 0x09 || last == 0x20 || last == 0x09
        let matchesSentinel = string.hasPrefix("=?base64?") && string.hasSuffix("?=")
        guard isSafe, !hasBoundaryWhitespace, !matchesSentinel else {
            let encoded = Data(bytes).base64EncodedString()
            return "=?base64?\(encoded)?="
        }
        return string
    }

    private static func isSafeInteger(_ integer: Int) -> Bool {
        let maximum = 9_007_199_254_740_991
        return integer >= -maximum && integer <= maximum
    }

    private static func isTChar(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x30...0x39,
            0x41...0x5A, 0x5E, 0x5F, 0x60, 0x61...0x7A, 0x7C, 0x7E:
            return true
        default:
            return false
        }
    }
}
