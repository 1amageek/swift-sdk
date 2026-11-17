import Foundation
import MCP
import Testing
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

@Suite struct StdioTransportLimitsTests {
    @Test(.timeLimit(.minutes(1))) func rejectsUnterminatedOversizedFramesAndTruncatedEOF() async throws {
        for bytes in [Data(repeating: 65, count: 1025), Data("partial".utf8)] {
            let (input, writer) = try FileDescriptor.pipe(), (reader, output) = try FileDescriptor.pipe()
            let transport = StdioTransport(input: input, output: output, limits: .init(maximumMessageBytes: 1024, maximumBufferedMessages: 2, writeTimeout: .seconds(1)))
            try await transport.connect()
            try writer.writeAll(bytes); try writer.close()
            var iterator = await transport.receive().makeAsyncIterator()
            await #expect(throws: (any Error).self) { try await iterator.next() }
            await transport.disconnect(); try input.close(); try output.close(); try reader.close()
        }
    }
    @Test(.timeLimit(.minutes(1))) func concurrentLargeFramesNeverInterleave() async throws {
        let (input, writer) = try FileDescriptor.pipe(), (reader, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, limits: .init(maximumMessageBytes: 65536, maximumBufferedMessages: 8, writeTimeout: .seconds(5)))
        try await transport.connect()
        let first = Data(repeating: 65, count: 32768), second = Data(repeating: 66, count: 32768)
        async let a: Void = transport.send(first)
        async let b: Void = transport.send(second)
        let reading = Task.detached {
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while bytes.count < 65538 {
                let count = try buffer.withUnsafeMutableBytes { try reader.read(into: $0) }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            return bytes.split(separator: 10).map { Data($0) }
        }
        try await a; try await b
        let frames = try await reading.value
        #expect(Set(frames) == Set([first, second]))
        await transport.disconnect(); try input.close(); try writer.close(); try output.close(); try reader.close()
    }
    @Test(.timeLimit(.minutes(1))) func writeDeadlineAndDisconnectDrainBlockedOutput() async throws {
        let (input, writer) = try FileDescriptor.pipe(), (reader, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, limits: .init(maximumMessageBytes: 1_048_576, maximumBufferedMessages: 2, writeTimeout: .milliseconds(50)))
        try await transport.connect()
        await #expect(throws: (any Error).self) { try await transport.send(Data(repeating: 65, count: 1_048_576)) }
        await #expect(throws: (any Error).self) { try await transport.send(Data("new-frame".utf8)) }
        await transport.disconnect(); try input.close(); try writer.close(); try output.close(); try reader.close()
    }
}
