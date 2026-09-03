import Foundation

/// The identity of one admitted modern HTTP request exchange.
package struct ExchangeID: Hashable, Sendable, CustomStringConvertible {
    package let rawValue: String

    package init() {
        self.rawValue = UUID().uuidString
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package var description: String { rawValue }
}
