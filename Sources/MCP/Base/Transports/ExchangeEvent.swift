import Foundation

/// A response event addressed to exactly one modern HTTP exchange.
package enum ExchangeEvent: Sendable {
    /// Delivers one JSON-RPC payload. A terminal event closes the exchange.
    case data(exchangeID: ExchangeID, data: Data, terminal: Bool)

    /// Ends an exchange with a typed local failure.
    case failure(exchangeID: ExchangeID, error: MCPError)
}
