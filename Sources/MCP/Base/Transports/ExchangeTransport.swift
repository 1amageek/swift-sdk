/// Package-internal exchange-aware capability for modern stateless HTTP.
///
/// The public ``Transport`` byte channel remains the compatibility boundary.
/// This capability is used only when an HTTP transport can preserve the
/// identity and lifetime of an individual POST exchange.
package protocol ExchangeTransport: Transport {
    func receiveExchanges() -> AsyncThrowingStream<ExchangeEnvelope, Swift.Error>
    func send(_ event: ExchangeEvent) async throws
    func cancel(exchangeID: ExchangeID) async
}
