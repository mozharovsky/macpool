import ArgumentParser
import Foundation
@testable import MacpoolCLI
@testable import MacpoolPool
import Network
import System
import Testing

/// Tests of `macpool connect` and of the relay between a process's input and output and a stream.
@Suite(.timeLimit(.minutes(1)))
struct ConnectCommandTests {
    /// Parses the lease, the paired host, and the data directory, and defaults to this Mac's daemon.
    @Test func parsesConnectOptions() throws {
        let remote = try #require(
            try Macpool.parseAsRoot(["connect", "--data-dir", "/pool", "--pool", "lab", "0a1b2c3d"])
                as? ConnectCommand,
        )
        #expect(remote.lease == "0a1b2c3d")
        #expect(remote.selection.host == "lab")
        #expect(remote.location.directory.root.path(percentEncoded: false) == "/pool")
        let local = try #require(try Macpool.parseAsRoot(["connect", "0a1b2c3d"]) as? ConnectCommand)
        #expect(local.selection.host == nil)
        #expect(local.location.directory == .standard)
        #expect(throws: (any Error).self) {
            try Macpool.parseAsRoot(["connect"])
        }
    }

    /// Relays a mebibyte from the input through an echo peer to the output, passes the end of the
    /// input on, and returns once the peer ends the stream.
    @Test func relaysTheInputAndTheOutput() async throws {
        let pair = try await StreamPair.open()
        let echo = Task { await pair.echo() }
        let input = try FileDescriptor.pipe()
        let output = try FileDescriptor.pipe()
        let payload = Data((0 ..< 1 << 20).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8)) })
        let writing = Task { await Self.write(payload, to: input.writeEnd) }
        let reading = Task { await Self.readAll(from: output.readEnd) }

        try await Self.relay(pair.client, input: input.readEnd, output: output.writeEnd)
        try output.writeEnd.close()
        #expect(await reading.value == payload)
        #expect(await echo.value == .finished)
        await writing.value
        try input.readEnd.close()
        try output.readEnd.close()
    }

    /// Fails with the stream's error when the peer resets the stream.
    @Test func failsWhenTheStreamBreaks() async throws {
        let pair = try await StreamPair.open()
        let input = try FileDescriptor.pipe()
        let output = try FileDescriptor.pipe()
        pair.peer.reset()
        await #expect {
            try await Self.relay(pair.client, input: input.readEnd, output: output.writeEnd)
        } throws: { error in
            if case .pool(.connection) = error as? CommandError {
                true
            } else {
                false
            }
        }
        for descriptor in [input.readEnd, input.writeEnd, output.readEnd, output.writeEnd] {
            try descriptor.close()
        }
    }

    /// Fails and resets the stream when the output cannot take the bytes.
    @Test func resetsTheStreamWhenTheOutputFails() async throws {
        let pair = try await StreamPair.open()
        let input = try FileDescriptor.pipe()
        let output = try FileDescriptor.pipe()
        // A write to a pipe without a reader then fails with EPIPE instead of ending the process.
        _ = fcntl(output.writeEnd.rawValue, F_SETNOSIGPIPE, 1)
        try output.readEnd.close()
        try await pair.peer.send(Data("banner".utf8))
        await #expect {
            try await Self.relay(pair.client, input: input.readEnd, output: output.writeEnd)
        } throws: { error in
            if case let .standardIO(operation, _) = error as? CommandError {
                operation == "writing standard output"
            } else {
                false
            }
        }
        #expect(await StreamPair.end(of: pair.peer) == .failed)
        for descriptor in [input.readEnd, input.writeEnd, output.writeEnd] {
            try descriptor.close()
        }
    }

    /// Returns without an error when the end of the input closes a TLS stream.
    @Test func endsWithTheInputOverTLS() async throws {
        let pair = try await StreamPair.open(tls: true)
        let input = try FileDescriptor.pipe()
        let output = try FileDescriptor.pipe()
        try input.writeEnd.close()

        try await Self.relay(pair.client, input: input.readEnd, output: output.writeEnd)
        #expect(await StreamPair.end(of: pair.peer) == .finished)
        for descriptor in [input.readEnd, output.readEnd, output.writeEnd] {
            try descriptor.close()
        }
    }

    /// Fails with the input's error and resets the stream when the input cannot be read.
    @Test func failsWhenTheInputCannotBeRead() async throws {
        let pair = try await StreamPair.open()
        let input = try FileDescriptor.pipe()
        let output = try FileDescriptor.pipe()
        // The write end of a pipe refuses reads.
        await #expect {
            try await Self.relay(pair.client, input: input.writeEnd, output: output.writeEnd)
        } throws: { error in
            if case let .standardIO(operation, _) = error as? CommandError {
                operation == "reading standard input"
            } else {
                false
            }
        }
        #expect(await StreamPair.end(of: pair.peer) == .failed)
        for descriptor in [input.readEnd, input.writeEnd, output.readEnd, output.writeEnd] {
            try descriptor.close()
        }
    }

    /// Runs the relay, and resets the stream if the relay is still running after 10 seconds.
    ///
    /// - Parameters:
    ///   - stream: The stream.
    ///   - input: The descriptor to read.
    ///   - output: The descriptor to write.
    /// - Throws: The relay's error.
    private static func relay(
        _ stream: ByteStream,
        input: FileDescriptor,
        output: FileDescriptor,
    ) async throws(CommandError) {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            stream.reset()
        }
        defer { watchdog.cancel() }
        try await StandardRelay.run(stream, input: input, output: output)
    }

    /// Writes bytes to a descriptor on a dispatch queue and closes it.
    ///
    /// - Parameters:
    ///   - data: The bytes.
    ///   - descriptor: The write end of a pipe.
    private static func write(_ data: Data, to descriptor: FileDescriptor) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = try? descriptor.writeAll(data)
                try? descriptor.close()
                continuation.resume()
            }
        }
    }

    /// Reads a descriptor to its end on a dispatch queue.
    ///
    /// - Parameter descriptor: The read end of a pipe.
    /// - Returns: The bytes that arrived before the end or a failure.
    private static func readAll(from descriptor: FileDescriptor) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while let count = try? buffer.withUnsafeMutableBytes({ try descriptor.read(into: $0) }), count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                }
                continuation.resume(returning: data)
            }
        }
    }
}

/// The two ends of a TCP or TLS connection on the loopback interface, each as a byte stream.
private struct StreamPair {
    /// How a stream ended.
    enum End: Equatable {
        /// The peer ended its sending direction.
        case finished

        /// The connection failed or the peer reset it.
        case failed

        /// The stream stayed open until the test closed it.
        case timedOut
    }

    /// The end that the relay uses.
    let client: ByteStream

    /// The end that stands in for the guest's SSH server.
    let peer: ByteStream

    /// Connects the two ends.
    ///
    /// - Parameter tls: Whether the connection carries TLS, as a connection to a paired host does.
    /// - Returns: The connected ends.
    /// - Throws: An error when the key cannot be created, the listener cannot start, or the
    ///   connection fails.
    static func open(tls: Bool = false) async throws -> StreamPair {
        let (parameters, clientParameters) = try tls ? tlsParameters() : (NWParameters.tcp, NWParameters.tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        let (accepted, continuation) = AsyncStream.makeStream(of: MessageChannel.self)
        listener.newConnectionHandler = { connection in
            continuation.yield(MessageChannel(connection: connection, peer: "relay peer", start: true))
        }
        let ready: Bool = await withCheckedContinuation { ready in
            let once = ResumeOnce(ready)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: true)
                case .failed, .waiting:
                    once.resume(returning: false)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "macpool.test.relay"))
        }
        try #require(ready, "the listener did not start")
        let port = try #require(listener.port)
        let client = try await MessageChannel.connect(
            to: .hostPort(host: .ipv4(.loopback), port: port),
            using: clientParameters,
        )
        var connections = accepted.makeAsyncIterator()
        let peer = try #require(await connections.next())
        return try StreamPair(client: client.takeStream(), peer: peer.takeStream())
    }

    /// Creates the parameters of mutual TLS with a key that exists only in the test.
    ///
    /// - Returns: The parameters of the listener and of the client.
    /// - Throws: An error when the key cannot be created.
    private static func tlsParameters() throws -> (NWParameters, NWParameters) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mp-tls-" + UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try MacIdentity.loadOrCreate(in: PoolDirectory(root: root))
        let server = try PeerSecurity.parameters(identity: identity, isServer: true) { _ in true }
        let client = try PeerSecurity.parameters(identity: identity, isServer: false) { _ in true }
        return (server, client)
    }

    /// Sends every byte back on ``peer`` and ends its sending direction after the client's end.
    ///
    /// - Returns: How the client's direction ended.
    func echo() async -> End {
        do throws(PoolError) {
            while let data = try await peer.receive() {
                try await peer.send(data)
            }
            try await peer.finishSending()
            return .finished
        } catch {
            return .failed
        }
    }

    /// Reads until a stream ends and reports how it ended.
    ///
    /// A receive does not end on task cancellation, so the call closes the stream when it stays
    /// open for 10 seconds.
    ///
    /// - Parameter stream: The stream.
    /// - Returns: How the stream ended.
    static func end(of stream: ByteStream) async -> End {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            stream.close()
        }
        defer { watchdog.cancel() }
        do throws(PoolError) {
            while try await stream.receive() != nil {}
            return .finished
        } catch let .connection(_, reason) where reason == "the stream was closed" {
            return .timedOut
        } catch {
            return .failed
        }
    }
}
