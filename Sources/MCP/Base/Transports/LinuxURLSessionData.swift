#if os(Linux)
  import Foundation
  import FoundationNetworking
  import Synchronization

  extension URLSession {
    package func mcpTransportData(
      for request: URLRequest
    ) async throws -> (Data, URLResponse) {
      let operation = URLSessionDataOperation()

      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          let task = dataTask(with: request) { data, response, error in
            operation.complete(data: data, response: response, error: error)
          }

          guard operation.install(continuation: continuation, task: task) else {
            continuation.resume(throwing: CancellationError())
            return
          }
          task.resume()
        }
      } onCancel: {
        operation.cancel()
      }
    }
  }

  private final class URLSessionDataOperation: Sendable {
    private struct State {
      var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
      var task: URLSessionDataTask?
      var isCancelled = false
    }

    private let state = Mutex(State())

    func install(
      continuation: CheckedContinuation<(Data, URLResponse), any Error>,
      task: URLSessionDataTask
    ) -> Bool {
      state.withLock { state in
        guard !state.isCancelled else { return false }
        state.continuation = continuation
        state.task = task
        return true
      }
    }

    func complete(data: Data?, response: URLResponse?, error: (any Error)?) {
      let continuation = state.withLock { state in
        let continuation = state.continuation
        state.continuation = nil
        state.task = nil
        return continuation
      }

      guard let continuation else { return }
      if let error {
        continuation.resume(throwing: error)
      } else if let data, let response {
        continuation.resume(returning: (data, response))
      } else {
        continuation.resume(throwing: URLError(.badServerResponse))
      }
    }

    func cancel() {
      let task = state.withLock { state in
        state.isCancelled = true
        return state.task
      }
      task?.cancel()
    }
  }
#endif
