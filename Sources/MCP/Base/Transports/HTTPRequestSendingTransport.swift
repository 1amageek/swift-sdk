import Foundation

/// Package boundary for one outbound HTTP request with Client-derived headers.
package protocol HTTPRequestSendingTransport: Transport {
    func send(_ data: Data, headers: [String: String]) async throws
    func updateNegotiatedProtocolVersion(_ version: String)
}
