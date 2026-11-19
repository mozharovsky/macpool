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

    /// Finds a line of the longest length that arrives one byte at a time.
    ///
    /// A search that started over at the first byte each time would take minutes for this line.
    /// The test therefore stops after 30 seconds.
    @Test func findsALongLineThatArrivesByteByByte() throws {
        let length = MessageChannel.maximumLineLength
        var buffer = LineBuffer(maximumLength: length)
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0 ..< length {
            buffer.append(Data("a".utf8))
            guard try buffer.takeLine() == nil else {
                Issue.record("a line ended before its line break")
                return
            }
            guard clock.now - start < .seconds(30) else {
                Issue.record("the search took longer than 30 seconds")
                return
            }
        }
        buffer.append(Data("\nb".utf8))
        #expect(try buffer.takeLine() == Data(repeating: UInt8(ascii: "a"), count: length))
        #expect(try buffer.takeLine() == nil)
        buffer.append(Data("c\n".utf8))
        #expect(try buffer.takeLine() == Data("bc".utf8))
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
        try await serverStream.finishSending()
        #expect(await clientStream.read(count: payload.count) == payload)
        #expect(try await clientStream.receive() == nil)

        try await clientStream.send(Data("after".utf8))
        #expect(await serverStream.read(count: 5) == Data("after".utf8))
        clientStream.close()
        #expect(try await serverStream.receive() == nil)
        serverStream.close()
    }

    /// Hands a stream the end that arrived with the channel's last bytes, so the stream reports a
    /// normal end instead of a failure.
    @Test func handsTheEndToTheStream() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        let clientStream = try client.takeStream()
        try await clientStream.send(Data("{\"request\":\"status\"}\ntail".utf8))
        try await clientStream.finishSending()
        // The pause lets the bytes and the end arrive before the first receive.
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await server.receive(PoolRequest.self) == .status)
        let serverStream = try server.takeStream()
        #expect(await serverStream.read(count: 4) == Data("tail".utf8))
        #expect(try await serverStream.receive() == nil)
        serverStream.close()
        clientStream.close()
    }

    /// Keeps an end that arrived without bytes, so later receives and a stream report a normal
    /// end.
    @Test func keepsAnEndWithoutBytes() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        let clientStream = try client.takeStream()
        try await clientStream.finishSending()
        #expect(try await server.receive(PoolRequest.self) == nil)
        #expect(try await server.receive(PoolRequest.self) == nil)
        let serverStream = try server.takeStream()
        #expect(try await serverStream.receive() == nil)
        serverStream.close()
        clientStream.close()
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

    /// Fails a stream's own pending receive and send when the stream closes.
    @Test func closeEndsPendingReceiveAndSend() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        let stream = try server.takeStream()
        let receiving = Task { try await stream.receive() }
        // The client reads nothing, so Network stops taking bytes long before this many.
        let sending = Task { try await stream.send(Data(count: 64 << 20)) }
        try await Task.sleep(for: .milliseconds(200))
        stream.close()
        await #expect(throws: PoolError.self) {
            try await receiving.value
        }
        await #expect(throws: PoolError.self) {
            try await sending.value
        }
        client.close()
    }

    /// Ends the peer's receive with `nil` after a close and with an error after a reset.
    @Test func tellsAResetFromAClose() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        var connections = listener.connections.makeAsyncIterator()
        for resets in [false, true] {
            let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
            let server = try #require(await connections.next())
            let serverStream = try server.takeStream()
            let clientStream = try client.takeStream()
            try await serverStream.send(Data("last".utf8))
            #expect(await clientStream.read(count: 4) == Data("last".utf8))
            if resets {
                serverStream.reset()
                await #expect(throws: PoolError.self) {
                    try await clientStream.receive()
                }
            } else {
                serverStream.close()
                #expect(try await clientStream.receive() == nil)
            }
            clientStream.close()
        }
    }

    /// Fails and resets the connection when the bytes before the end do not leave in time, so the
    /// peer sees a failure instead of a normal end.
    @Test func resetsWhenTheEndCannotLeave() async throws {
        let listener = try await LoopbackListener()
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: listener.endpoint, using: .tcp)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        // The client reads nothing yet. The lines stay below the channel's 4 MiB limit but fill
        // both sockets' buffers, so the end waits behind them.
        let line = PoolReply.failure(String(repeating: "x", count: 60000))
        for _ in 0 ..< 60 {
            try server.send(line)
        }
        let stream = try server.takeStream()
        await #expect {
            try await stream.finishSending(within: .milliseconds(300))
        } throws: { error in
            if case let .connection(_, reason) = error as? PoolError {
                reason.hasPrefix("the bytes did not leave within")
            } else {
                false
            }
        }
        let clientStream = try client.takeStream()
        await #expect(throws: PoolError.self) {
            while try await clientStream.receive() != nil {}
        }
        clientStream.close()
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
        #expect(try await clientStream.receive() == nil)
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
        try await clientStream.finishSending()
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
    /// Receives until a number of bytes arrived or the stream ended or failed.
    ///
    /// - Parameter count: The number of bytes to wait for.
    /// - Returns: The bytes, which are fewer than `count` only when the stream ended or failed.
    func read(count: Int) async -> Data {
        var data = Data()
        while data.count < count, let chunk = try? await receive() {
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
