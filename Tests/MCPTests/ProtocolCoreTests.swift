import Foundation
import Testing

@testable import MCP

@Suite("Protocol Core")
struct ProtocolCoreTests {
    private enum TestMethod: MCP.Method {
        static let name = "test.protocol"
        typealias Parameters = Value
        typealias Result = Value
    }

    private static let modernMetadata: Value = .object([
        RequestMetadata.protocolVersionKey: .string(Version.modern),
        RequestMetadata.clientCapabilitiesKey: .object([:]),
    ])

    @Test("Modern requests require request metadata while legacy requests remain compatible")
    func modernRequestMetadataIsRequired() throws {
        let request = TestMethod.request(
            id: 1,
            .object(["value": .string("ok")])
        )
        let data = try JSONEncoder().encode(request)

        #expect(throws: ProtocolCoreError.self) {
            try MessageCodec(era: .modern).decode(Request<TestMethod>.self, from: data)
        }
        let legacy = try MessageCodec(era: .legacy).decode(Request<TestMethod>.self, from: data)
        #expect(legacy.params.objectValue?["value"] == .string("ok"))
    }

    @Test("Valid modern request metadata survives codec round trip")
    func validModernRequestRoundTrip() throws {
        let request = TestMethod.request(
            id: 1,
            .object([
                "_meta": Self.modernMetadata,
                "value": .string("ok"),
            ])
        )
        let codec = MessageCodec(era: .modern)
        let data = try codec.encode(request)
        let decoded = try codec.decode(Request<TestMethod>.self, from: data)

        #expect(decoded == request)
    }

    @Test("Modern successful results require resultType while legacy results default to complete")
    func modernResultTypeIsRequired() throws {
        let response = Response<TestMethod>(id: 1, result: .success(.object(["value": .string("ok")])))
        let data = try JSONEncoder().encode(response)

        #expect(throws: ProtocolCoreError.self) {
            try MessageCodec(era: .modern).decode(Response<TestMethod>.self, from: data)
        }
        let legacy = try MessageCodec(era: .legacy).decodeResultEnvelope(from: data)
        #expect(legacy.resultType == .complete)
    }

    @Test("Valid modern result survives codec round trip")
    func validModernResultRoundTrip() throws {
        let response = Response<TestMethod>(
            id: 1,
            result: .success(.object([
                "resultType": .string(ResultType.complete.rawValue),
                "value": .string("ok"),
            ])))
        let codec = MessageCodec(era: .modern)
        let data = try codec.encode(response)
        let decoded = try codec.decode(Response<TestMethod>.self, from: data)

        #expect(decoded == response)
    }

    @Test("Modern result preserves unknown result types and rejects invalid cache fields")
    func modernResultValidation() throws {
        let extensionType = Response<TestMethod>(
            id: 1,
            result: .success(.object(["resultType": .string("unknown")])))
        let partialCache = Response<TestMethod>(
            id: 1,
            result: .success(.object([
                "resultType": .string("complete"),
                "ttlMs": .int(1),
            ])))
        let codec = MessageCodec(era: .modern)

        let decodedExtension = try codec.decode(
            Response<TestMethod>.self,
            from: JSONEncoder().encode(extensionType)
        )
        #expect(decodedExtension == extensionType)
        #expect(throws: ProtocolCoreError.self) {
            try codec.decode(Response<TestMethod>.self, from: JSONEncoder().encode(partialCache))
        }
    }

    @Test("Modern request rejects malformed and unsupported metadata versions")
    func modernRequestValidation() throws {
        let malformed = TestMethod.request(
            id: 1,
            .object(["_meta": .object([
                RequestMetadata.protocolVersionKey: .string(Version.modern),
            ])]))
        let unsupported = TestMethod.request(
            id: 1,
            .object(["_meta": .object([
                RequestMetadata.protocolVersionKey: .string("2027-01-01"),
                RequestMetadata.clientCapabilitiesKey: .object([:]),
            ])]))
        let codec = MessageCodec(era: .modern)

        #expect(throws: ProtocolCoreError.self) {
            try codec.decode(Request<TestMethod>.self, from: JSONEncoder().encode(malformed))
        }
        #expect(throws: MCPError.self) {
            try codec.decode(Request<TestMethod>.self, from: JSONEncoder().encode(unsupported))
        }
    }

    @Test("Connection info rejects era and version mismatches")
    func connectionInfoValidation() throws {
        #expect(throws: ProtocolCoreError.self) {
            _ = try ConnectionInfo(era: .modern, protocolVersion: Version.latest)
        }
        #expect(throws: ProtocolCoreError.self) {
            _ = try ConnectionInfo(era: .legacy, protocolVersion: Version.modern)
        }
        #expect(throws: MCPError.self) {
            _ = try ConnectionInfo(protocolVersion: "2027-01-01")
        }

        let valid = try ConnectionInfo(era: .modern, protocolVersion: Version.modern)
        let decoded = try JSONDecoder().decode(
            ConnectionInfo.self,
            from: JSONEncoder().encode(valid)
        )
        #expect(decoded == valid)

        let mismatched = Data(#"{"era":"modern","protocolVersion":"2025-11-25"}"#.utf8)
        #expect(throws: ProtocolCoreError.self) {
            try JSONDecoder().decode(ConnectionInfo.self, from: mismatched)
        }
    }

    @Test("Request metadata is modern-only for constructors and decoding")
    func requestMetadataVersionIsValidatedEverywhere() throws {
        #expect(throws: MCPError.self) {
            _ = try RequestMetadata(protocolVersion: Version.latest)
        }

        let legacy = Data(#"{"io.modelcontextprotocol/protocolVersion":"2025-11-25","io.modelcontextprotocol/clientCapabilities":{}}"#.utf8)
        #expect(throws: MCPError.self) {
            try JSONDecoder().decode(RequestMetadata.self, from: legacy)
        }

        let metadata = try RequestMetadata()
        let decoded = try JSONDecoder().decode(
            RequestMetadata.self,
            from: JSONEncoder().encode(metadata)
        )
        #expect(decoded == metadata)
    }

    @Test("Modern discovery result round trips required fields")
    func discoveryRoundTrip() throws {
        let result = DiscoverResult(
            supportedVersions: [Version.modern],
            capabilities: CapabilitySet(["tools": .object(["listChanged": .bool(true)])]),
            cacheHint: try CacheHint(scope: .public, ttlMs: 0),
            additionalFields: [
                "resultType": .string(ResultType(rawValue: "spoof").rawValue),
                "cacheScope": .string("spoof"),
                "extension": .object(["enabled": .bool(true)]),
            ]
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(DiscoverResult.self, from: data)

        #expect(decoded == result)
        #expect(decoded.additionalFields == [
            "extension": .object(["enabled": .bool(true)]),
        ])
    }

    @Test("Result envelopes require resultType and validate known combinations")
    func resultEnvelopeValidation() throws {
        let missingType = Data(#"{"value":"ok"}"#.utf8)
        #expect(throws: ProtocolCoreError.self) {
            try JSONDecoder().decode(ResultEnvelope.self, from: missingType)
        }

        let completeWithInput = Data(#"{"resultType":"complete","inputRequests":{}}"#.utf8)
        #expect(throws: ProtocolCoreError.self) {
            try JSONDecoder().decode(ResultEnvelope.self, from: completeWithInput)
        }

        let inputWithoutState = Data(#"{"resultType":"input_required"}"#.utf8)
        #expect(throws: ProtocolCoreError.self) {
            try JSONDecoder().decode(ResultEnvelope.self, from: inputWithoutState)
        }

        let extensionResult = Data(#"{"resultType":"vendor_extension","inputRequests":{"extra":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(ResultEnvelope.self, from: extensionResult)
        #expect(decoded.resultType == ResultType(rawValue: "vendor_extension"))
        #expect(decoded.fields["inputRequests"] == .object(["extra": .bool(true)]))
        let reencoded = try JSONDecoder().decode(
            Value.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(reencoded.objectValue?["resultType"] == .string("vendor_extension"))
        #expect(reencoded.objectValue?["inputRequests"] == .object(["extra": .bool(true)]))
    }

    @Test("Protocol errors retain their wire code and data")
    func typedErrorsRoundTrip() throws {
        let errors: [MCPError] = [
            .headerMismatch("method mismatch"),
            .missingRequiredClientCapability(required: ["roots": .object([:])]),
            .unsupportedProtocolVersion(requested: "2027-01-01", supported: [Version.modern]),
        ]

        for error in errors {
            let data = try JSONEncoder().encode(error)
            let decoded = try JSONDecoder().decode(MCPError.self, from: data)
            #expect(decoded == error)
        }
    }

    @Test("Structured protocol errors reject missing and malformed required data")
    func structuredErrorDataIsRequired() throws {
        let malformed = [
            Data(#"{"code":-32021,"message":"missing capability","data":{}}"#.utf8),
            Data(#"{"code":-32021,"message":"missing capability","data":{"requiredCapabilities":"invalid"}}"#.utf8),
            Data(#"{"code":-32022,"message":"unsupported version","data":{}}"#.utf8),
            Data(#"{"code":-32022,"message":"unsupported version","data":{"requested":"2027-01-01","supported":[1]}}"#.utf8),
            Data(#"{"code":-32024,"message":"local limit","data":{"limit":64}}"#.utf8),
            Data(#"{"code":-32024,"message":"local limit","data":{"resource":"tools"}}"#.utf8),
            Data(#"{"code":-32024,"message":"local limit","data":{"resource":1,"limit":64}}"#.utf8),
            Data(#"{"code":-32024,"message":"local limit","data":{"resource":"tools","limit":"64"}}"#.utf8),
        ]

        for data in malformed {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(MCPError.self, from: data)
            }
        }
    }

    @Test("Cache hints reject negative TTL on encoding")
    func negativeCacheHintIsRejected() throws {
        #expect(throws: ProtocolCoreError.self) {
            _ = try CacheHint(scope: .public, ttlMs: -1)
        }

        let invalid = Data(#"{"cacheScope":"public","ttlMs":-1}"#.utf8)
        #expect(throws: ProtocolCoreError.self) {
            try JSONDecoder().decode(CacheHint.self, from: invalid)
        }
    }

    @Test("Typed fields cannot be injected through additional fields")
    func reservedAdditionalFieldsAreSanitized() throws {
        let requestMetadata = try RequestMetadata(
            additionalFields: [
                RequestMetadata.protocolVersionKey: .string("spoof"),
                RequestMetadata.clientCapabilitiesKey: .string("spoof"),
                RequestMetadata.clientInfoKey: .string("spoof"),
                "extension": .bool(true),
            ]
        )
        #expect(requestMetadata.additionalFields == ["extension": .bool(true)])

        let resultMetadata = ResultMetadata(
            additionalFields: [
                ResultMetadata.serverInfoKey: .string("spoof"),
                NotificationMetadata.subscriptionIDKey: .int(99),
                "extension": .bool(true),
            ]
        )
        #expect(resultMetadata.additionalFields == ["extension": .bool(true)])

        let notificationMetadata = NotificationMetadata(
            additionalFields: [
                NotificationMetadata.subscriptionIDKey: .int(99),
                "extension": .bool(true),
            ]
        )
        #expect(notificationMetadata.subscriptionID == nil)
        #expect(notificationMetadata.additionalFields == ["extension": .bool(true)])

        let envelope = ResultEnvelope(
            fields: [
                "resultType": .string("input_required"),
                "_meta": .string("spoof"),
                "cacheScope": .string("public"),
                "ttlMs": .int(1),
                "extension": .bool(true),
            ]
        )
        #expect(envelope.fields == ["extension": .bool(true)])
        let encoded = try JSONDecoder().decode(
            Value.self,
            from: JSONEncoder().encode(envelope)
        )
        #expect(encoded.objectValue?["resultType"] == .string(ResultType.complete.rawValue))
        #expect(encoded.objectValue?["extension"] == .bool(true))
        #expect(encoded.objectValue?["_meta"] == nil)
        #expect(encoded.objectValue?["cacheScope"] == nil)
        #expect(encoded.objectValue?["ttlMs"] == nil)
    }
}
