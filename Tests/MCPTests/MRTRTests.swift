import Foundation
import Testing

@testable import MCP

@Suite("MRTR and Subscriptions")
struct MRTRTests {
    private static func metadata() throws -> RequestMetadata {
        try RequestMetadata(
            protocolVersion: Version.modern,
            clientCapabilities: CapabilitySet(["elicitation": .object([:])])
        )
    }

    @Test("Input-required results preserve opaque state and keyed requests")
    func inputRequiredRoundTrip() throws {
        let result = InputRequiredResult(
            inputRequests: [
                "approval": InputRequest(
                    method: .elicitationCreate,
                    params: .object(["message": .string("Approve")])
                )
            ],
            requestState: "opaque-state-9"
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(InputRequiredResult.self, from: data)

        #expect(decoded == result)
        #expect(decoded.requestState == "opaque-state-9")
    }

    @Test("Input responses retain keyed values and tolerate extra keys")
    func inputResponsesRoundTrip() throws {
        let approval = try InputResponse(
            method: .elicitationCreate,
            value: .object(["action": .string("accept")])
        )
        let additional = try InputResponse(
            method: .rootsList,
            value: .object(["roots": .array([])])
        )
        let responses: InputResponses = [
            "approval": approval,
            "additional": additional,
        ]
        let parameters = InputResponseRequestParams(
            metadata: try Self.metadata(),
            requestState: "opaque-state-9",
            inputResponses: responses,
            additionalFields: ["extension": .bool(true)]
        )

        let data = try JSONEncoder().encode(parameters)
        let decoded = try JSONDecoder().decode(InputResponseRequestParams.self, from: data)

        #expect(decoded == parameters)
        #expect(decoded.inputResponses?["additional"] == additional)
    }

    @Test("Accepted elicitation responses may include validated content")
    func acceptedElicitationContentRoundTrip() throws {
        let response = try InputResponse(
            method: .elicitationCreate,
            value: .object([
                "action": .string("accept"),
                "content": .object([
                    "name": .string("Ada"),
                    "count": .int(2),
                    "enabled": .bool(true),
                    "tags": .array([.string("swift")]),
                ]),
            ])
        )
        let decoded = try JSONDecoder().decode(
            InputResponse.self,
            from: JSONEncoder().encode(response)
        )
        #expect(decoded == response)
    }

    @Test("Input response union tolerates extension keys that resemble another member")
    func inputResponseUnionIgnoresDiscriminatorLikeExtensions() throws {
        let value: Value = .object([
            "action": .string("accept"),
            "model": .string("extension-defined-value"),
        ])
        let response = try JSONDecoder().decode(
            InputResponse.self,
            from: JSONEncoder().encode(value)
        )

        #expect(response.value == value)
        try response.validate(for: .elicitationCreate)

        #expect(throws: ProtocolCoreError.self) {
            try response.validate(for: .samplingCreateMessage)
        }
    }

    @Test("Sampling tool results preserve arbitrary structured content")
    func arbitraryStructuredContentIsAccepted() throws {
        let response = try InputResponse(
            method: .samplingCreateMessage,
            value: .object([
                "model": .string("model-1"),
                "role": .string("assistant"),
                "content": .object([
                    "type": .string("tool_result"),
                    "toolUseId": .string("tool-1"),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("done")])
                    ]),
                    "structuredContent": .array([.string("extension"), .int(3)]),
                ]),
            ])
        )

        let decoded = try JSONDecoder().decode(
            InputResponse.self,
            from: JSONEncoder().encode(response)
        )
        #expect(decoded == response)
    }

    @Test("Sampling tool results reject malformed embedded resources")
    func malformedEmbeddedResourceFails() throws {
        let malformedResources: [Value] = [
            .object([
                "type": .string("resource"),
                "resource": .object(["uri": .string("file:///tmp/a")]),
            ]),
            .object([
                "type": .string("resource"),
                "resource": .object([
                    "uri": .string("file:///tmp/a"),
                    "text": .string("text"),
                    "blob": .string("blob"),
                ]),
            ]),
        ]

        for resource in malformedResources {
            #expect(throws: ProtocolCoreError.self) {
                try InputResponse(
                    method: .samplingCreateMessage,
                    value: .object([
                        "model": .string("model-1"),
                        "role": .string("assistant"),
                        "content": .object([
                            "type": .string("tool_result"),
                            "toolUseId": .string("tool-1"),
                            "content": .array([resource]),
                        ]),
                    ])
                )
            }
        }
    }

    @Test("Input and subscription values sanitize reserved additional fields")
    func reservedAdditionalFieldsAreSanitized() throws {
        let metadata = try Self.metadata()
        let inputRequest = InputRequest(
            method: .elicitationCreate,
            params: .object(["message": .string("Approve")]),
            additionalFields: ["method": .string("spoof"), "extension": .bool(true)]
        )
        #expect(inputRequest.additionalFields == ["extension": .bool(true)])

        let inputResult = InputRequiredResult(
            requestState: "opaque",
            additionalFields: [
                "resultType": .string(ResultType.complete.rawValue),
                "requestState": .string("spoof"),
                "extension": .bool(true),
            ]
        )
        #expect(inputResult.additionalFields == ["extension": .bool(true)])

        let responseParameters = InputResponseRequestParams(
            metadata: metadata,
            requestState: "opaque",
            additionalFields: [
                "_meta": .string("spoof"),
                "requestState": .string("spoof"),
                "extension": .bool(true),
            ]
        )
        #expect(responseParameters.additionalFields == ["extension": .bool(true)])

        let filter = SubscriptionFilter(
            toolsListChanged: true,
            additionalFields: ["toolsListChanged": .bool(false), "extension": .bool(true)]
        )
        #expect(filter.additionalFields == ["extension": .bool(true)])

        let listen = SubscriptionsListenRequest.Parameters(
            notifications: filter,
            metadata: metadata,
            additionalFields: ["notifications": .string("spoof"), "extension": .bool(true)]
        )
        #expect(listen.additionalFields == ["extension": .bool(true)])

        let suppliedMetadata = NotificationMetadata(
            additionalFields: [NotificationMetadata.subscriptionIDKey: .int(999)]
        )
        let acknowledgement = SubscriptionsAcknowledgedNotification.Parameters(
            subscriptionID: 42,
            notifications: filter,
            metadata: suppliedMetadata
        )
        #expect(acknowledgement.metadata.subscriptionID == 42)
        #expect(acknowledgement.metadata.additionalFields.isEmpty)
        let acknowledgementValue = try JSONDecoder().decode(
            Value.self,
            from: JSONEncoder().encode(acknowledgement)
        )
        #expect(
            acknowledgementValue.objectValue?["_meta"]?.objectValue?[NotificationMetadata.subscriptionIDKey]
                == .int(42)
        )

        let terminal = SubscriptionsListenResult(
            subscriptionID: 42,
            additionalFields: ["resultType": .string("vendor"), "extension": .bool(true)]
        )
        #expect(terminal.additionalFields == ["extension": .bool(true)])
    }

    @Test("Input responses reject ambiguous or malformed member shapes")
    func invalidInputResponseShapesFail() throws {
        let invalidValues: [Value] = [
            .object([
                "model": .string("model-1"),
                "role": .string("system"),
                "content": .object(["type": .string("text"), "text": .string("hi")]),
            ]),
            .object([
                "model": .string("model-1"),
                "role": .string("assistant"),
                "content": .object(["type": .string("unknown"), "text": .string("hi")]),
            ]),
            .object([
                "roots": .array([.object(["uri": .int(1)])]),
            ]),
            .object([
                "action": .string("decline"),
                "content": .object(["reason": .string("no")]),
            ]),
            .object([
                "action": .string("accept"),
                "content": .object(["choice": .object(["nested": .bool(true)])]),
            ]),
            .object([
                "action": .string("accept"),
                "model": .string("extension-defined-value"),
                "content": .object(["choice": .object(["nested": .bool(true)])]),
            ]),
        ]

        for value in invalidValues {
            #expect(throws: ProtocolCoreError.self) {
                try JSONDecoder().decode(
                    InputResponse.self,
                    from: JSONEncoder().encode(value)
                )
            }
        }
    }

    @Test("Ambiguous input response values remain lossless without method inference")
    func ambiguousInputResponseRoundTripIsLossless() throws {
        let value = Value.object([
            "roots": .array([]),
            "action": .string("accept"),
            "model": .string("model-1"),
            "role": .string("assistant"),
            "content": .object([
                "type": .string("text"),
                "text": .string("hello"),
            ]),
        ])
        let response = try InputResponse(
            method: .elicitationCreate,
            value: value
        )
        let decoded = try JSONDecoder().decode(
            InputResponse.self,
            from: JSONEncoder().encode(response)
        )

        #expect(decoded == response)
        #expect(decoded.value == value)
        try decoded.validate(for: .elicitationCreate)
        try decoded.validate(for: .samplingCreateMessage)
        try decoded.validate(for: .rootsList)
    }

    @Test("Unsupported input methods and empty input-required results fail explicitly")
    func invalidInputValuesFail() throws {
        let unsupported = Data(#"{"method":"unknown/input","params":{}}"#.utf8)
        #expect(throws: ProtocolCoreError.self) {
            try JSONDecoder().decode(InputRequest.self, from: unsupported)
        }

        let empty = InputRequiredResult(inputRequests: nil, requestState: nil)
        #expect(throws: ProtocolCoreError.self) {
            try JSONEncoder().encode(empty)
        }

        let invalidInputRequests: InputRequests = [
            "approval": InputRequest(
                method: .elicitationCreate,
                params: .object(["message": .string("Approve")])
            )
        ]
        let completeWithInput = ResultEnvelope(
            resultType: .complete,
            fields: [
                "inputRequests": try Value(invalidInputRequests)
            ]
        )
        #expect(throws: ProtocolCoreError.self) {
            try JSONEncoder().encode(completeWithInput)
        }
    }

    @Test("Input-response and subscription requests require modern metadata")
    func requiredRequestMetadataFailsWhenMissing() throws {
        let inputResponseWithoutMetadata = Data(#"{"inputResponses":{}}"#.utf8)
        #expect(throws: ProtocolCoreError.self) {
            try JSONDecoder().decode(InputResponseRequestParams.self, from: inputResponseWithoutMetadata)
        }

        let subscriptionWithoutMetadata = Data(#"{"notifications":{}}"#.utf8)
        #expect(throws: ProtocolCoreError.self) {
            try JSONDecoder().decode(
                SubscriptionsListenRequest.Parameters.self,
                from: subscriptionWithoutMetadata
            )
        }
    }

    @Test("Subscription filters and acknowledgements round trip as protocol values")
    func subscriptionValuesRoundTrip() throws {
        let filter = SubscriptionFilter(
            toolsListChanged: true,
            resourcesListChanged: true,
            resourceSubscriptions: ["file:///tmp/a"]
        )
        let request = SubscriptionsListenRequest.Parameters(
            notifications: filter,
            metadata: try Self.metadata()
        )
        let acknowledgement = SubscriptionsAcknowledgedNotification.Parameters(
            subscriptionID: 42,
            notifications: filter
        )
        let terminal = SubscriptionsListenResult(subscriptionID: 42)

        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(
            SubscriptionsListenRequest.Parameters.self,
            from: requestData
        )
        let acknowledgementData = try JSONEncoder().encode(acknowledgement)
        let decodedAcknowledgement = try JSONDecoder().decode(
            SubscriptionsAcknowledgedNotification.Parameters.self,
            from: acknowledgementData
        )
        let terminalData = try JSONEncoder().encode(terminal)
        let decodedTerminal = try JSONDecoder().decode(
            SubscriptionsListenResult.self,
            from: terminalData
        )

        #expect(decodedRequest == request)
        #expect(decodedAcknowledgement == acknowledgement)
        #expect(decodedTerminal == terminal)
        #expect(SubscriptionsListenRequest.name == "subscriptions/listen")
        #expect(SubscriptionsAcknowledgedNotification.name == "notifications/subscriptions/acknowledged")
    }
}
