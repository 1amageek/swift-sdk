import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension URLProtocol {
    /// Answers the current request with `respond` on a new task and reports
    /// the outcome to the client, unless `loadingState` was stopped first.
    func deliverResponse(
        guardedBy loadingState: URLProtocolLoadingState,
        _ respond: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
    ) {
        let handoff = URLProtocolHandoff(urlProtocol: self)
        let request = self.request
        Task {
            let urlProtocol = handoff.urlProtocol
            do {
                let (response, data) = try await respond(request)
                guard loadingState.beginCompletion() else { return }
                urlProtocol.client?.urlProtocol(
                    urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
                urlProtocol.client?.urlProtocol(urlProtocol, didLoad: data)
                urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
            } catch {
                guard loadingState.beginCompletion() else { return }
                urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: error)
            }
        }
    }
}

/// Carries a URL protocol to the task that answers its request.
///
/// FoundationNetworking does not mark `URLProtocol` as `Sendable`, and its
/// client reads the session's task registry, which it otherwise touches only
/// on the session's work queue. A protocol cannot reach that queue, so these
/// mocks report from a task: the task only calls client methods, and
/// `URLProtocolLoadingState` lets at most one outcome through. The report can
/// still race FoundationNetworking adding or removing another task of the
/// same session, so a test must not churn many tasks on one session through
/// these mocks; `URLSessionDataCancellationTests` answers on the loading
/// thread instead.
private struct URLProtocolHandoff: @unchecked Sendable {
    let urlProtocol: URLProtocol
}
