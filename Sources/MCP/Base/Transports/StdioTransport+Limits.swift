import Foundation

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
extension StdioTransport {
    public struct Limits: Sendable {
        public let maximumMessageBytes: Int
        public let maximumBufferedMessages: Int
        public let writeTimeout: Duration
        public init(maximumMessageBytes: Int, maximumBufferedMessages: Int, writeTimeout: Duration) {
            self.maximumMessageBytes = maximumMessageBytes
            self.maximumBufferedMessages = maximumBufferedMessages
            self.writeTimeout = writeTimeout
        }
    }
}
#endif
