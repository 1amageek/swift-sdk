import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A protocol that answers every request synchronously from `startLoading`,
/// on the session's loading thread as FoundationNetworking requires, so a
/// cancellation issued while the request runs races the completion.
private final class ImmediateURLProtocol: URLProtocol {
    static let body = Data("ok".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("URLSession data cancellation")
struct URLSessionDataCancellationTests {
    @Test(
        "Cancelling a request that races its completion resumes the caller exactly once",
        .timeLimit(.minutes(1))
    )
    func cancellationRacingCompletion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImmediateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.mcpInvalidate() }
        let request = URLRequest(url: URL(string: "https://localhost/race")!)

        for iteration in 0..<1_000 {
            let task = Task { try await session.mcpData(for: request) }
            for _ in 0..<(iteration % 8) {
                await Task.yield()
            }
            task.cancel()
            do {
                let (data, response) = try await task.value
                #expect(data == ImmediateURLProtocol.body)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
            } catch is CancellationError {
                // Cancelled before the request started, or on
                // FoundationNetworking while it ran.
            } catch let error as URLError where error.code == .cancelled {
                // Cancelled by Darwin Foundation while the request ran.
            }
        }
    }
}
