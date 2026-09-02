/// The server-initiated method that a client may need to fulfill during an
/// input-required round.
public enum InputRequestMethod: String, Codable, Hashable, Sendable {
    case samplingCreateMessage = "sampling/createMessage"
    case rootsList = "roots/list"
    case elicitationCreate = "elicitation/create"
}
