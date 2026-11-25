import Logging

import Foundation

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

// Import for specific low-level operations not yet in Swift System
#if canImport(Darwin)
    import Darwin.POSIX
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    /// An implementation of the MCP stdio transport protocol.
    ///
    /// This transport implements the [stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#stdio)
    /// specification from the Model Context Protocol.
    ///
    /// The stdio transport works by:
    /// - Reading JSON-RPC messages from standard input
    /// - Writing JSON-RPC messages to standard output
    /// - Using newline characters as message delimiters
    /// - Supporting non-blocking I/O operations
    ///
    /// This transport is the recommended option for most MCP applications due to its
    /// simplicity and broad platform support.
    ///
    /// - Important: This transport is available on Apple platforms and Linux distributions with glibc
    ///   (Ubuntu, Debian, Fedora, CentOS, RHEL).
    ///
    /// ## Example Usage
    ///
    /// ```swift
    /// import MCP
    ///
    /// // Initialize the client
    /// let client = Client(name: "MyApp", version: "1.0.0")
    ///
    /// // Create a transport and connect
    /// let transport = StdioTransport()
    /// try await client.connect(transport: transport)
    /// ```
    public actor StdioTransport: Transport {
        private let input: FileDescriptor
        private let output: FileDescriptor
        /// Logger instance for transport-related events
        public nonisolated let logger: Logger

        private let limits: Limits?
        private var readTask: Task<Void, Never>?
        private var writes: [UUID: Task<Void, Swift.Error>] = [:]
        private var lastWrite: Task<Void, Swift.Error>?
        private var finished = false
        private var isConnected = false
        private let messageStream: AsyncThrowingStream<Data, Swift.Error>
        private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

        /// Creates a new stdio transport with the specified file descriptors
        ///
        /// - Parameters:
        ///   - input: File descriptor for reading (defaults to standard input)
        ///   - output: File descriptor for writing (defaults to standard output)
        ///   - logger: Optional logger instance for transport events
        ///   - limits: Optional bounds on frame size, buffered messages, and
        ///     write time; `nil` keeps the transport unbounded
        public init(
            input: FileDescriptor = FileDescriptor.standardInput,
            output: FileDescriptor = FileDescriptor.standardOutput,
            logger: Logger? = nil,
            limits: Limits? = nil
        ) {
            self.limits = limits
            self.input = input
            self.output = output
            self.logger =
                logger
                ?? Logger(
                    label: "mcp.transport.stdio",
                    factory: { _ in SwiftLogNoOpLogHandler() })

            // Create message stream
            var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
            self.messageStream = AsyncThrowingStream(bufferingPolicy: limits.map { .bufferingOldest(max(1, min(1024, $0.maximumBufferedMessages))) } ?? .unbounded) { continuation = $0 }
            self.messageContinuation = continuation
        }

        /// Establishes connection with the transport
        ///
        /// This method configures the file descriptors for non-blocking I/O
        /// and starts the background message reading loop.
        ///
        /// - Throws: Error if the file descriptors cannot be configured
        public func connect() async throws {
            guard !isConnected else { return }
            if let limits {
                guard !finished, (1...16_777_216).contains(limits.maximumMessageBytes), (1...1024).contains(limits.maximumBufferedMessages), limits.writeTimeout > .zero else { throw MCPError.invalidParams("Invalid or completed bounded stdio profile") }
            }

            // Set non-blocking mode
            try setNonBlocking(fileDescriptor: input)
            try setNonBlocking(fileDescriptor: output)

            isConnected = true
            logger.debug("Transport connected successfully")

            // Start reading loop in background
            readTask = Task {
                await readLoop()
            }
        }

        /// Configures a file descriptor for non-blocking I/O
        ///
        /// - Parameter fileDescriptor: The file descriptor to configure
        /// - Throws: Error if the operation fails
        private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                // Get current flags
                let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
                guard flags >= 0 else {
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }

                // Set non-blocking flag
                let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
                guard result >= 0 else {
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }
            #else
                // For platforms where non-blocking operations aren't supported
                throw MCPError.internalError(
                    "Setting non-blocking mode not supported on this platform")
            #endif
        }

        /// Continuous loop that reads and processes incoming messages
        ///
        /// This method runs in the background while the transport is connected,
        /// parsing complete messages delimited by newlines and yielding them
        /// to the message stream.
        private func readLoop() async {
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            var pendingData = Data()

            while isConnected && !Task.isCancelled {
                do {
                    let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                        try input.read(into: UnsafeMutableRawBufferPointer(pointer))
                    }

                    if bytesRead == 0 {
                        logger.notice("EOF received")
                        if limits != nil && !pendingData.isEmpty { throw MCPError.parseError("Truncated stdio frame at EOF") }
                        break
                    }

                    pendingData.append(Data(buffer[..<bytesRead]))

                    // Process complete messages
                    while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                        let messageData = pendingData[..<newlineIndex]
                        if let limits, messageData.count > limits.maximumMessageBytes { throw MCPError.invalidRequest("Stdio frame exceeds its byte budget") }
                        pendingData = pendingData[(newlineIndex + 1)...]

                        if !messageData.isEmpty {
                            logger.trace(
                                "Message received", metadata: ["size": "\(messageData.count)"])
                            if case .dropped = messageContinuation.yield(Data(messageData)) { throw MCPError.invalidRequest("Stdio input queue exceeded its message budget") }
                        }
                    }
                    if let limits, pendingData.count > limits.maximumMessageBytes { throw MCPError.invalidRequest("Stdio frame exceeds its byte budget") }
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                    continue
                } catch {
                    if !Task.isCancelled {
                        logger.error("Read error occurred", metadata: ["error": "\(error)"])
                        if limits != nil { messageContinuation.finish(throwing: error) }
                    }
                    break
                }
            }

            finished = true
            messageContinuation.finish()
        }

        /// Disconnects from the transport
        ///
        /// This stops the message reading loop and releases associated resources.
        public func disconnect() async {
            isConnected = false
            let reader = readTask; readTask = nil; reader?.cancel()
            let pendingWrites = Array(writes.values)
            for task in pendingWrites { task.cancel() }
            if let reader { await reader.value }
            for task in pendingWrites { _ = await task.result }
            writes.removeAll(); lastWrite = nil
            messageContinuation.finish()
            logger.debug("Transport disconnected")
        }

        /// Sends a message over the transport.
        ///
        /// This method supports sending both individual JSON-RPC messages and JSON-RPC batches.
        /// Batches should be encoded as a JSON array containing multiple request/notification objects
        /// according to the JSON-RPC 2.0 specification.
        ///
        /// - Parameter message: The message data to send (without a trailing newline)
        /// - Throws: Error if the message cannot be sent
        public func send(_ message: Data) async throws {
            guard isConnected else { throw MCPError.transportError(Errno(rawValue: ENOTCONN)) }
            if let limits { guard message.count <= limits.maximumMessageBytes, writes.count < limits.maximumBufferedMessages else { throw MCPError.invalidRequest("Stdio output exceeds its message/queue budget") } }
            let id = UUID(), previous = lastWrite
            let task = Task {
                if let previous { try await previous.value }
                try Task.checkCancellation()
                try await self.writeFrame(message)
            }
            writes[id] = task; lastWrite = task
            defer { writes[id] = nil; if writes.isEmpty { lastWrite = nil } }
            do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
            catch {
                if limits != nil {
                    messageContinuation.finish(throwing: error)
                    await disconnect()
                }
                throw error
            }
        }

        private func writeFrame(_ message: Data) async throws {
            var bytes = message; bytes.append(UInt8(ascii: "\n"))
            var offset = 0
            let deadline = limits.map { ContinuousClock.now.advanced(by: $0.writeTimeout) }
            while offset < bytes.count {
                try Task.checkCancellation()
                guard isConnected else { throw MCPError.transportError(Errno(rawValue: ENOTCONN)) }
                if let deadline, ContinuousClock.now >= deadline { throw MCPError.internalError("Stdio write deadline exceeded") }
                do {
                    let written = try bytes.withUnsafeBytes { buffer in
                        try output.write(UnsafeRawBufferPointer(rebasing: buffer[offset...]))
                    }
                    guard written > 0 else { throw MCPError.internalError("Stdio write made no progress") }
                    offset += written
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try await Task.sleep(for: .milliseconds(10))
                } catch { throw MCPError.transportError(error) }
            }
        }

        /// Receives messages from the transport.
        ///
        /// Messages may be individual JSON-RPC requests, notifications, responses,
        /// or batches containing multiple requests/notifications encoded as JSON arrays.
        /// Each message is guaranteed to be a complete JSON object or array.
        ///
        /// - Returns: An AsyncThrowingStream of Data objects representing JSON-RPC messages
        public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
            return messageStream
        }
    }
#endif
