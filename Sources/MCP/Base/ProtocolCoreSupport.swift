import Foundation

func _protocolCoreSanitizeAdditionalFields(
    _ fields: [String: Value],
    excluding reserved: Set<String>
) -> [String: Value] {
    fields.filter { !reserved.contains($0.key) }
}

func _protocolCoreDecodeObject(from decoder: Decoder, as subject: String) throws -> [String: Value] {
    do {
        let container = try decoder.singleValueContainer()
        return try container.decode([String: Value].self)
    } catch {
        throw ProtocolCoreError.malformedMessage("\(subject) must be an object")
    }
}

func _protocolCoreDecodeValue<T: Decodable>(_ value: Value, as type: T.Type) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(type, from: data)
}

func _protocolCoreValidateResultTypeCombination(
    _ resultType: ResultType,
    fields: [String: Value]
) throws {
    let hasInputRequests = fields["inputRequests"] != nil
    let hasRequestState = fields["requestState"] != nil
    if resultType == .complete {
        guard !hasInputRequests, !hasRequestState else {
            throw ProtocolCoreError.invalidResultInput
        }
    } else if resultType == .inputRequired {
        guard hasInputRequests || hasRequestState else {
            throw ProtocolCoreError.invalidResultInput
        }
    }
}
