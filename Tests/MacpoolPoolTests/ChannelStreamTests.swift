import Foundation
@testable import MacpoolPool
import Network
import Testing

/// Tests of channels over TCP and of the handoff from lines to raw bytes.
@Suite(.timeLimit(.minutes(1)))
struct ChannelStreamTests {
    /// Splits lines across arrivals and keeps the bytes after the last line.
    @Test func splitsLinesAndKeepsTheRest() throws {
        var buffer = LineBuffer(maximumLength: 16)
        buffer.append(Data("one\ntw".utf8))
        #expect(try buffer.takeLine() == Data("one".utf8))
        #expect(try buffer.takeLine() == nil)
        buffer.append(Data("o\nraw".utf8))
        #expect(try buffer.takeLine() == Data("two".utf8))
        #expect(try buffer.takeLine() == nil)
        #expect(buffer.takeAll() == Data("raw".utf8))
        #expect(buffer.takeAll().isEmpty)
    }

    /// Rejects more bytes than a line may have without a line break.
    @Test func rejectsAnOverlongLine() {
        var buffer = LineBuffer(maximumLength: 4)
        buffer.append(Data("abcd".utf8))
        #expect(throws: Never.self) { try buffer.takeLine() }
        buffer.append(Data("e".utf8))
        #expect(throws: PoolError.malformedMessage(reason: "a line exceeds 4 bytes")) { try buffer.takeLine() }
    }

    /// Exchanges a line over TCP and then raw bytes in both directions until the end of the stream.
    @Test func switchesFromLinesToBytesOverTCP() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        // The line and the first raw bytes leave in one send, so they usually arrive together.
        let clientStream = try client.takeStream()
        try await clientStream.send(Data("{\"request\":\"status\"}\nhello".utf8))
        #expect(try await server.receive(PoolRequest.self) == .status)
        let serverStream = try server.takeStream()
        #expect(await serverStream.read(count: 5) == Data("hello".utf8))

        let payload = Data((0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0) })
        try await serverStream.send(payload)
        await serverStream.finishSending()
        #expect(await clientStream.read(count: payload.count) == payload)
        #expect(await clientStream.receive() == nil)

        try await clientStream.send(Data("after".utf8))
        #expect(await serverStream.read(count: 5) == Data("after".utf8))
        clientStream.close()
        #expect(await serverStream.receive() == nil)
        serverStream.close()
    }

    /// Leaves the connection to the stream once the channel handed it over.
    @Test func keepsTheStreamWhenTheChannelCloses() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        let serverStream = try server.takeStream()
        #expect(try await server.receive(PoolRequest.self) == nil)
        try server.send(PoolReply.queued(position: 1))
        server.close()
        await server.finish()
        try await serverStream.send(Data("bytes\n".utf8))
        // The reply went nowhere and the connection stayed open, so only the raw bytes arrive.
        let clientStream = try client.takeStream()
        #expect(await clientStream.read(count: 6) == Data("bytes\n".utf8))
        clientStream.close()
        serverStream.close()
    }

    /// Refuses to hand a connection to a second stream.
    @Test func handsTheConnectionToOneStream() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        let serverStream = try server.takeStream()
        #expect(throws: PoolError.connection(path: "test client", reason: "a byte stream already owns it")) {
            try server.takeStream()
        }
        try await serverStream.send(Data("one".utf8))
        let clientStream = try client.takeStream()
        #expect(await clientStream.read(count: 3) == Data("one".utf8))
        clientStream.close()
        serverStream.close()
    }

    /// Refuses a stream once the channel began to finish or close, so the end never reaches a
    /// stream.
    @Test func refusesAStreamWhileEnding() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        // The client reads nothing, so these lines keep the finish waiting for them to leave.
        let line = PoolReply.failure(String(repeating: "x", count: 60000))
        for _ in 0 ..< 200 {
            try server.send(line)
        }
        let finishing = Task { await server.finish(within: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        let closing = PoolError.connection(path: "test client", reason: "the channel is closing it")
        #expect(throws: closing) {
            try server.takeStream()
        }
        server.close()
        await finishing.value
        #expect(throws: closing) {
            try server.takeStream()
        }
        client.close()
    }

    /// Ends a stream's own pending receive and send when the stream closes.
    @Test func closeEndsPendingReceiveAndSend() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        let stream = try server.takeStream()
        let receiving = Task { await stream.receive() }
        // The client reads nothing, so Network stops taking bytes long before this many.
        let sending = Task { try await stream.send(Data(count: 64 << 20)) }
        try await Task.sleep(for: .milliseconds(200))
        stream.close()
        #expect(await receiving.value == nil)
        await #expect(throws: PoolError.self) {
            try await sending.value
        }
        client.close()
    }

    /// Ends the peer's reads when a stream goes away without a close.
    @Test func droppedStreamEndsItsConnection() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        _ = try server.takeStream()
        let clientStream = try client.takeStream()
        // The time limit cannot end a waiting receive, so a late close bounds the wait.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            clientStream.close()
        }
        #expect(await clientStream.receive() == nil)
        watchdog.cancel()
        #expect(await (try? watchdog.value) == nil, "the peer saw the end only when the watchdog closed")
        clientStream.close()
    }

    /// Returns the complete lines and then `nil` when the connection breaks inside a line.
    @Test func endsAtABreakInsideALine() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        let clientStream = try client.takeStream()
        try await clientStream.send(Data("{\"request\":\"status\"}\n{\"request\":\"sta".utf8))
        await clientStream.finishSending()
        #expect(try await server.receive(PoolRequest.self) == .status)
        #expect(try await server.receive(PoolRequest.self) == nil)
        clientStream.close()
        server.close()
    }

    /// Fails at once when nothing listens on a TCP port.
    @Test func refusesAClosedPort() async throws {
        let listener = try await LoopbackListener()
        let endpoint = listener.endpoint
        await listener.closeAndWait()
        let start = ContinuousClock.now
        await #expect {
            try await MessageChannel.connect(to: endpoint, using: .tcp, timeout: .seconds(20))
        } throws: { error in
            if case .connection = error as? PoolError {
                true
            } else {
                false
            }
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }
}

/// Reads of an exact length that the tests compare.
extension ByteStream {
    /// Receives until a number of bytes arrived or the stream ended.
    ///
    /// - Parameter count: The number of bytes to wait for.
    /// - Returns: The bytes, which are fewer than `count` only when the stream ended.
    func read(count: Int) async -> Data {
        var data = Data()
        while data.count < count, let chunk = await receive() {
            data.append(chunk)
        }
        return data
    }
}

/// A TCP listener on the loopback interface that wraps each connection in a channel.
private final class LoopbackListener: Sendable {
    /// The underlying listener.
    private let listener: NWListener

    /// The address and port on which the listener accepts connections.
    let endpoint: NWEndpoint

    /// The accepted connections.
    let connections: AsyncStream<MessageChannel>

    /// Starts listening on a free port of 127.0.0.1 and waits until the listener is ready.
    ///
    /// - Throws: An error when the listener cannot start.
    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let (connections, continuation) = AsyncStream.makeStream(of: MessageChannel.self)
        listener.newConnectionHandler = { connection in
            continuation.yield(MessageChannel(connection: connection, peer: "test client", start: true))
        }
        let failure: String? = await withCheckedContinuation { ready in
            let once = ResumeOnce(ready)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: nil)
                case let .failed(error), let .waiting(error):
                    once.resume(returning: "\(error)")
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "macpool.test.listener"))
        }
        if let failure {
            listener.cancel()
            throw PoolError.connection(path: "127.0.0.1", reason: failure)
        }
        let port = try #require(listener.port)
        self.listener = listener
        self.connections = connections
        endpoint = .hostPort(host: .ipv4(.loopback), port: port)
    }

    /// Stops listening.
    func close() {
        listener.cancel()
    }

    /// Stops listening and waits until the listener closed its socket.
    func closeAndWait() async {
        let listener = listener
        await withCheckedContinuation { (cancelled: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(cancelled)
            listener.stateUpdateHandler = { state in
                if case .cancelled = state {
                    once.resume(returning: ())
                }
            }
            listener.cancel()
        }
    }
}
