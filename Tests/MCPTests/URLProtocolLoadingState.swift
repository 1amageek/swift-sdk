import NIOConcurrencyHelpers

final class URLProtocolLoadingState: Sendable {
    private let mayComplete = NIOLockedValueBox(true)

    func beginCompletion() -> Bool {
        mayComplete.withLockedValue { mayComplete in
            guard mayComplete else { return false }
            mayComplete = false
            return true
        }
    }

    func stop() {
        mayComplete.withLockedValue { mayComplete in
            mayComplete = false
        }
    }
}
