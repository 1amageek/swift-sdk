import Foundation
import Testing

@testable import MCP

@Suite("Tool Header Resolver")
struct ToolHeaderResolverTests {
    @Test("Resolver extracts nested primitive properties")
    func nestedExtraction() throws {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "region": .object([
                    "type": .string("string"),
                    "x-mcp-header": .string("Region"),
                ]),
                "options": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "attempt": .object([
                            "type": .string("integer"),
                            "x-mcp-header": .string("Attempt"),
                        ]),
                        "enabled": .object([
                            "type": .string("boolean"),
                            "x-mcp-header": .string("Enabled"),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let resolver = try ToolHeaderResolver(schema: schema)

        let headers = try resolver.resolve(arguments: [
            "region": .string("us-west1"),
            "options": .object([
                "attempt": .int(3),
                "enabled": .bool(true),
            ]),
        ])

        #expect(headers == [
            "Mcp-Param-Region": "us-west1",
            "Mcp-Param-Attempt": "3",
            "Mcp-Param-Enabled": "true",
        ])
    }

    @Test("Resolver omits missing and null values")
    func missingAndNullAreOmitted() throws {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "token": .object([
                    "type": .string("string"),
                    "x-mcp-header": .string("Token"),
                ])
            ]),
        ])
        let resolver = try ToolHeaderResolver(schema: schema)

        #expect(try resolver.resolve(arguments: ["token": .null]).isEmpty)
        #expect(try resolver.resolve(arguments: [:]).isEmpty)
    }

    @Test("Header values use the sentinel encoding for unsafe strings")
    func safeValueEncoding() throws {
        #expect(try ToolHeaderResolver.encodeHeaderValue(.string("plain")) == "plain")
        #expect(try ToolHeaderResolver.encodeHeaderValue(.string("Hello, 世界")) == "=?base64?SGVsbG8sIOS4lueVjA==?=")
        #expect(try ToolHeaderResolver.encodeHeaderValue(.string(" padded ")) == "=?base64?IHBhZGRlZCA=?=")
        #expect(try ToolHeaderResolver.encodeHeaderValue(.string("=?base64?literal?=")) == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
    }

    @Test("Resolver rejects invalid annotations and unsafe integer values")
    func invalidSchemasAndValuesFail() throws {
        let numberSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "ratio": .object([
                    "type": .string("number"),
                    "x-mcp-header": .string("Ratio"),
                ])
            ]),
        ])
        let duplicateSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "first": .object([
                    "type": .string("string"),
                    "x-mcp-header": .string("X-Trace"),
                ]),
                "second": .object([
                    "type": .string("boolean"),
                    "x-mcp-header": .string("x-trace"),
                ]),
            ]),
        ])

        #expect(throws: ProtocolCoreError.self) {
            try ToolHeaderResolver(schema: numberSchema)
        }
        #expect(throws: ProtocolCoreError.self) {
            try ToolHeaderResolver(schema: duplicateSchema)
        }

        let primitiveSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "count": .object([
                    "type": .string("integer"),
                    "x-mcp-header": .string("Count"),
                ])
            ]),
        ])
        let resolver = try ToolHeaderResolver(schema: primitiveSchema)
        #expect(throws: ProtocolCoreError.self) {
            try resolver.resolve(arguments: ["count": .int(9_007_199_254_740_992)])
        }
    }

    @Test("Resolver does not traverse forbidden schema branches")
    func forbiddenBranchesAreRejected() throws {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "items": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("string"),
                        "x-mcp-header": .string("Nested"),
                    ]),
                ])
            ]),
        ])

        #expect(throws: ProtocolCoreError.self) {
            try ToolHeaderResolver(schema: schema)
        }
    }

    @Test("Resolver rejects annotations under any non-properties schema keyword")
    func unknownSchemaBranchIsRejected() throws {
        let schema: Value = .object([
            "type": .string("object"),
            "x-vendor-extension": .object([
                "nested": .object([
                    "x-mcp-header": .string("Hidden"),
                    "type": .string("string"),
                ])
            ]),
        ])

        #expect(throws: ProtocolCoreError.self) {
            try ToolHeaderResolver(schema: schema)
        }
    }

    @Test("Resolver accepts a valid schema beyond the former node threshold")
    func deepSchemaIsAccepted() throws {
        let width = 4_100
        let depth = 64
        var properties: [String: Value] = [:]
        for index in 0..<width {
            properties["field\(index)"] = .object(["type": .string("string")])
        }

        var deepSchema: Value = .object([
            "type": .string("string"),
            "x-mcp-header": .string("Deep"),
        ])
        for index in stride(from: depth - 1, through: 0, by: -1) {
            deepSchema = .object([
                "type": .string("object"),
                "properties": .object(["level\(index)": deepSchema]),
            ])
        }
        properties["deep"] = deepSchema
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object(properties),
        ])

        var arguments: Value = .string("value")
        for index in stride(from: depth - 1, through: 0, by: -1) {
            arguments = .object(["level\(index)": arguments])
        }

        let resolver = try ToolHeaderResolver(schema: schema)
        #expect(try resolver.resolve(arguments: .object(["deep": arguments])) == ["Mcp-Param-Deep": "value"])
    }

    @Test("Resolver leaves local and remote references opaque")
    func referencesAreNotDereferenced() throws {
        let schema: Value = .object([
            "type": .string("object"),
            "$ref": .string("https://example.invalid/schema.json"),
        ])

        let resolver = try ToolHeaderResolver(schema: schema)
        #expect(try resolver.resolve(arguments: [:]).isEmpty)
    }
}
