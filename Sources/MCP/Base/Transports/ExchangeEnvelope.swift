import Foundation

/// An immutable request or cancellation delivered through the package-internal
/// exchange seam. Cancellation is a distinct case so it can never be mistaken
/// for an empty HTTP POST.
package enum ExchangeEnvelope: Sendable {
    case request(
        exchangeID: ExchangeID,
        body: Data,
        headers: [String: String],
        context: HTTPRequest,
        era: ProtocolEra
    )
    case cancellation(exchangeID: ExchangeID)

    package var exchangeID: ExchangeID {
        switch self {
        case .request(let exchangeID, _, _, _, _),
                .cancellation(let exchangeID):
            return exchangeID
        }
    }
}
