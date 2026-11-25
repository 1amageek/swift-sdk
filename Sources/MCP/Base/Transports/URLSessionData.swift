import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
  import Synchronization
#endif

// FoundationNetworking's `URLSessionTask.cancel()` traps when it races the
// task's completion: the cancellation reports a failure for a task that the
// completion already removed from the session ("Trying to access a behaviour
// for a task that in not in the registry"), and `data(for:delegate:)`
// additionally resumes its continuation twice. The SDK therefore never
// cancels a FoundationNetworking task. A cancelled caller returns at once and
// the abandoned exchange runs to completion, bounded by the session's
// request timeout. Darwin Foundation has no such race and keeps cancellation.
extension URLSession {
  /// Loads `request` and resumes the caller exactly once.
  ///
  /// Every buffered HTTP exchange in the SDK goes through this method. On
  /// FoundationNetworking, cancelling the calling task resumes it with
  /// `CancellationError` without cancelling the data task, whose result is
  /// then discarded; the session delegate still receives task callbacks such
  /// as redirects. Darwin Foundation uses `data(for:)`.
  ///
  /// - Throws: `CancellationError` when the calling task is cancelled on
  ///   FoundationNetworking, and the session's error otherwise.
  package func mcpData(for request: URLRequest) async throws -> (Data, URLResponse) {
    #if canImport(FoundationNetworking)
      let operation = URLSessionDataOperation()

      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          guard operation.install(continuation) else {
            continuation.resume(throwing: CancellationError())
            return
          }
          let task = dataTask(with: request) { data, response, error in
            operation.complete(data: data, response: response, error: error)
          }
          task.resume()
        }
      } onCancel: {
        operation.cancel()
      }
    #else
      return try await data(for: request)
    #endif
  }

  /// Invalidates the session without racing in-flight completions.
  ///
  /// Darwin Foundation cancels outstanding tasks. FoundationNetworking lets
  /// them finish, because cancelling a task that is completing traps.
  package func mcpInvalidate() {
    #if canImport(FoundationNetworking)
      finishTasksAndInvalidate()
    #else
      invalidateAndCancel()
    #endif
  }
}

#if canImport(FoundationNetworking)
  /// The caller's continuation for one ``URLSession/mcpData(for:)`` call.
  ///
  /// Whichever of completion and cancellation comes first takes the
  /// continuation; the other finds none and does nothing.
  private final class URLSessionDataOperation: Sendable {
    private struct State {
      var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
      var isCancelled = false
    }

    private let state = Mutex(State())

    /// Stores `continuation`, or returns `false` when the caller was already
    /// cancelled.
    func install(_ continuation: CheckedContinuation<(Data, URLResponse), any Error>) -> Bool {
      state.withLock { state in
        guard !state.isCancelled else { return false }
        state.continuation = continuation
        return true
      }
    }

    func complete(data: Data?, response: URLResponse?, error: (any Error)?) {
      guard let continuation = takeContinuation(cancelling: false) else { return }
      if let error {
        continuation.resume(throwing: error)
      } else if let data, let response {
        continuation.resume(returning: (data, response))
      } else {
        continuation.resume(throwing: URLError(.badServerResponse))
      }
    }

    func cancel() {
      takeContinuation(cancelling: true)?.resume(throwing: CancellationError())
    }

    private func takeContinuation(
      cancelling: Bool
    ) -> CheckedContinuation<(Data, URLResponse), any Error>? {
      state.withLock { state in
        if cancelling {
          state.isCancelled = true
        }
        let continuation = state.continuation
        state.continuation = nil
        return continuation
      }
    }
  }
#endif
