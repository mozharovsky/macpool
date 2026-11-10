public import Foundation
public import Network
import Synchronization

/// A connection that carries one JSON message per line.
///
/// The daemon, its clients, and the VM supervisors all talk through channels over Unix sockets,
/// and a channel runs the same way over any stream connection. Sends are queued in call order and
/// never wait. One task at a time reads with ``receive(_:)``, which returns `nil` once the peer
/// closes the connection or the connection fails. ``close()`` ends a pending receive.
///
/// If the peer stops reading, the queue still has a bound. ``delivered()`` waits until the queued
/// messages left. If a send would queue more than 4 MiB, it closes the connection instead.
///
/// A request can switch its connection to raw bytes. ``takeStream()`` then hands the connection
/// over as a ``ByteStream`` with the bytes that arrived after the last line.
public final class MessageChannel: Sendable {
    /// The longest line that a channel accepts, in bytes.
    static let maximumLineLength = 1 << 20

    /// The most bytes that may wait to leave before a send closes the connection.
    static let maximumQueuedBytes = 4 << 20

    /// The underlying connection.
    private let connection: NWConnection

    /// The socket path or network endpoint of the peer, for error messages.
    let peer: String

    /// The bytes that arrived and do not yet form a complete line, and who uses the connection.
    private let state = Mutex(ChannelState())

    /// Wraps a connection and starts it on its own queue.
    ///
    /// - Parameters:
    ///   - connection: A connection that a listener accepted, or one that already started.
    ///   - peer: The socket path or network endpoint of the peer, for error messages.
    ///   - start: Whether to start the connection.
    init(connection: NWConnection, peer: String, start: Bool) {
        self.connection = connection
        self.peer = peer
        if start {
            connection.start(queue: DispatchQueue(label: "macpool.channel"))
        }
    }

    /// Connects to a listening socket and waits until the connection is ready.
    ///
    /// A path that Network would truncate, or that is too long for a socket address, goes through
    /// a symbolic link to its directory in the user's temporary directory. When that connection
    /// fails and earlier builds listened on the truncated name, the call tries that name too. A
    /// supervisor that an earlier build started listens there, and the daemon would otherwise
    /// count it as unresponsive and end its VM.
    ///
    /// - Parameters:
    ///   - socket: The socket file.
    ///   - timeout: The longest wait for each connection attempt.
    /// - Returns: A ready channel.
    /// - Throws: ``PoolError/socketPathTooLong(path:length:)`` for a path that no socket can
    ///   reach, ``PoolError/connection(path:reason:)`` when the socket is missing, refuses the
    ///   connection, or does not answer in time, or another ``PoolError`` when the link cannot be
    ///   made.
    public static func connect(to socket: URL, timeout: Duration = .seconds(5)) async throws(PoolError)
        -> MessageChannel {
        try await connect(to: socket, timeout: timeout, aliasDirectory: SocketPath.userTemporaryDirectory)
    }

    /// Connects like ``connect(to:timeout:)`` with the alias in a given directory.
    ///
    /// - Parameters:
    ///   - socket: The socket file.
    ///   - timeout: The longest wait for each connection attempt.
    ///   - aliasDirectory: The directory for an alias of the socket's directory, which must admit
    ///     only the user. `nil` allows no alias.
    /// - Returns: A ready channel.
    /// - Throws: ``PoolError/socketPathTooLong(path:length:)`` for a path that no socket can
    ///   reach, ``PoolError/connection(path:reason:)`` when the socket is missing, refuses the
    ///   connection, or does not answer in time, or another ``PoolError`` when the alias cannot be
    ///   made.
    static func connect(
        to socket: URL,
        timeout: Duration,
        aliasDirectory: URL?,
    ) async throws(PoolError) -> MessageChannel {
        let path = socket.path(percentEncoded: false)
        let endpoint = try SocketPath.endpoint(for: socket, aliasDirectory: aliasDirectory)
        do {
            return try await open(.unix(path: endpoint), using: .tcp, peer: path, timeout: timeout)
        } catch {
            guard SocketPath.hasTruncatedName(path) else {
                throw error
            }
            // Network truncates the path the same way that it did for the earlier build.
            guard let channel = try? await open(.unix(path: path), using: .tcp, peer: path, timeout: timeout) else {
                throw error
            }
            return channel
        }
    }

    /// Connects to a network endpoint and waits until the connection is ready.
    ///
    /// The parameters choose the transport and any security protocol. A refused or unreachable
    /// endpoint fails at once instead of waiting for the network to change.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint, such as a host and port.
    ///   - parameters: The connection's protocols and options.
    ///   - timeout: The longest wait for the connection, including any handshake.
    /// - Returns: A ready channel.
    /// - Throws: ``PoolError/connection(path:reason:)`` with the endpoint when the connection
    ///   fails or is not ready in time.
    public static func connect(
        to endpoint: NWEndpoint,
        using parameters: NWParameters,
        timeout: Duration = .seconds(5),
    ) async throws(PoolError) -> MessageChannel {
        try await open(endpoint, using: parameters, peer: "\(endpoint)", timeout: timeout)
    }

    /// Opens one connection and waits until it is ready.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to hand to Network.
    ///   - parameters: The connection's protocols and options.
    ///   - peer: The socket path or network endpoint, for error messages.
    ///   - timeout: The longest wait for the connection.
    /// - Returns: A ready channel.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the peer is missing, refuses the
    ///   connection, or does not answer in time.
    private static func open(
        _ endpoint: NWEndpoint,
        using parameters: NWParameters,
        peer: String,
        timeout: Duration,
    ) async throws(PoolError) -> MessageChannel {
        let connection = NWConnection(to: endpoint, using: parameters)
        let failure: String? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            // A missing Unix socket and a refused or unreachable endpoint leave the connection
            // waiting for a path change, so waiting counts as a failure here.
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: nil)
                case let .waiting(error), let .failed(error):
                    once.resume(returning: "\(error)")
                case .cancelled:
                    once.resume(returning: "cancelled")
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "macpool.channel"))
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(returning: "no answer within \(timeout)")
            }
        }
        if let failure {
            connection.stateUpdateHandler = nil
            connection.cancel()
            throw .connection(path: peer, reason: failure)
        }
        return MessageChannel(connection: connection, peer: peer, start: false)
    }

    /// Queues a message for sending.
    ///
    /// The call does not wait for the peer. A message sent after ``close()`` or
    /// ``finish(within:)`` began, or after the connection went to a ``ByteStream``, is dropped.
    /// If the message would bring the bytes that wait to leave above 4 MiB, the call drops it and
    /// closes the connection. A peer that far behind has stopped reading.
    ///
    /// - Parameter message: The message to send.
    /// - Throws: ``PoolError/malformedMessage(reason:)`` when the message cannot be encoded.
    public func send(_ message: some Encodable) throws(PoolError) {
        let data: Data
        do {
            data = try MessageCoding.encoder.encode(message) + Data("\n".utf8)
        } catch {
            throw .malformedMessage(reason: "\(error)")
        }
        // Queueing under the lock keeps a line from following the bytes of a stream that took
        // the connection in between.
        let overflows = state.withLock { state in
            guard state.user == .channel else {
                return false
            }
            guard state.queuedBytes + data.count <= Self.maximumQueuedBytes else {
                state.user = .ending
                return true
            }
            state.queuedBytes += data.count
            connection.send(content: data, completion: .contentProcessed { _ in self.left(data.count) })
            return false
        }
        if overflows {
            connection.cancel()
            releaseWaiters()
        }
    }

    /// Waits until the messages sent so far left for the peer.
    ///
    /// A message has left once Network passed it to the system's socket. For a peer that stops
    /// reading, that happens only after the peer read earlier bytes. The wait also ends when the
    /// channel closes its connection, and it returns at once after the connection went to a
    /// ``ByteStream``.
    public func delivered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waits = state.withLock { state in
                guard state.user == .channel, state.queuedBytes > 0 else {
                    return false
                }
                state.waiters.append(continuation)
                return true
            }
            if !waits {
                continuation.resume()
            }
        }
    }

    /// Counts bytes that left and wakes the tasks in ``delivered()`` once nothing waits.
    ///
    /// - Parameter count: The number of bytes that left.
    private func left(_ count: Int) {
        let waiters = state.withLock { state in
            state.queuedBytes -= count
            guard state.queuedBytes == 0 else {
                return [CheckedContinuation<Void, Never>]()
            }
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Wakes the tasks in ``delivered()`` after the channel stopped using its connection.
    private func releaseWaiters() {
        let waiters = state.withLock { state in
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Receives the next message.
    ///
    /// One task at a time may wait. The wait ignores task cancellation, so the owner calls
    /// ``close()`` to end it early. Once the channel begins to close its connection, lines that
    /// arrived earlier are dropped.
    ///
    /// - Parameter type: The message type.
    /// - Returns: The message, or `nil` once the connection has ended, the channel began to close
    ///   it, or it went to a ``ByteStream``.
    /// - Throws: ``PoolError/malformedMessage(reason:)`` when a line is not a valid message or is
    ///   longer than 1 MiB.
    public func receive<Message: Decodable>(_ type: Message.Type) async throws(PoolError) -> Message? {
        while true {
            let scan = try state.withLock { state throws(PoolError) -> LineScan in
                guard state.user == .channel else {
                    return .unavailable
                }
                return try state.buffer.takeLine().map(LineScan.line) ?? .incomplete
            }
            switch scan {
            case .unavailable:
                return nil
            case let .line(line):
                do {
                    return try MessageCoding.decoder.decode(type, from: line)
                } catch {
                    throw .malformedMessage(reason: "\(error)")
                }
            case .incomplete:
                guard let chunk = await connection.receiveBytes() else {
                    return nil
                }
                state.withLock { $0.buffer.append(chunk) }
            }
        }
    }

    /// Ends the line framing and hands the connection over as a byte stream.
    ///
    /// The stream first returns the bytes that arrived after the last line that ``receive(_:)``
    /// returned. Call this while no receive waits. The channel then drops sends, its receives
    /// return `nil`, and its ``close()`` and ``finish(within:)`` leave the connection to the
    /// stream.
    ///
    /// - Returns: The stream that now owns the connection.
    /// - Throws: ``PoolError/connection(path:reason:)`` when an earlier call already handed the
    ///   connection to a stream, or when ``close()`` or ``finish(within:)`` already began to end
    ///   it.
    public func takeStream() throws(PoolError) -> ByteStream {
        let claim: Result<Data, PoolError> = state.withLock { state in
            switch state.user {
            case .channel:
                state.user = .stream
                return .success(state.buffer.takeAll())
            case .ending:
                return .failure(.connection(path: peer, reason: "the channel is closing it"))
            case .stream:
                return .failure(.connection(path: peer, reason: "a byte stream already owns it"))
            }
        }
        return try ByteStream(connection: connection, peer: peer, leftover: claim.get())
    }

    /// Closes the connection and ends a pending receive.
    ///
    /// Messages that are still queued may be lost. Use ``finish(within:)`` to deliver them first.
    /// A connection that went to a ``ByteStream`` stays open, and ``takeStream()`` refuses the
    /// connection once the close begins.
    public func close() {
        let ownsConnection = state.withLock { state in
            guard state.user != .stream else {
                return false
            }
            state.user = .ending
            return true
        }
        if ownsConnection {
            connection.cancel()
        }
        releaseWaiters()
    }

    /// Delivers the queued messages, signals the end of the stream, and closes the connection.
    ///
    /// The call returns at once when the connection went to a ``ByteStream``, which keeps it open,
    /// or when ``close()`` or another finish already ends it. ``takeStream()`` refuses the
    /// connection once the finish begins, so the end never reaches a stream.
    ///
    /// - Parameter timeout: The longest wait for the queued messages to leave.
    public func finish(within timeout: Duration = .seconds(2)) async {
        let starts = state.withLock { state in
            guard state.user == .channel else {
                return false
            }
            state.user = .ending
            return true
        }
        guard starts else {
            return
        }
        await connection.sendEnd(within: timeout)
        connection.cancel()
        releaseWaiters()
    }
}

/// What a channel finds when it looks for the next line.
private enum LineScan {
    /// The channel began to close the connection, or the connection went to a ``ByteStream``.
    case unavailable
    /// No line is complete yet.
    case incomplete
    /// A complete line without its line break.
    case line(Data)
}

/// The receiving state of a channel and who uses its connection.
private struct ChannelState {
    /// The bytes after the last complete line.
    var buffer = LineBuffer(maximumLength: MessageChannel.maximumLineLength)

    /// Who uses the connection, which changes only under the channel's lock.
    var user = ConnectionUser.channel

    /// The bytes that were queued and have not left yet.
    var queuedBytes = 0

    /// The tasks in ``MessageChannel/delivered()``.
    var waiters: [CheckedContinuation<Void, Never>] = []
}

/// Who uses a channel's connection.
private enum ConnectionUser {
    /// The channel sends and receives lines.
    case channel
    /// The channel began to close the connection, and no stream may take it.
    case ending
    /// A ``ByteStream`` owns the connection.
    case stream
}

/// Bytes that arrived on a connection and do not yet form a complete line.
struct LineBuffer {
    /// The longest line that the buffer accepts, in bytes, without its line break.
    let maximumLength: Int

    /// The bytes after the last complete line.
    private var bytes = Data()

    /// Creates an empty buffer.
    ///
    /// - Parameter maximumLength: The longest line that the buffer accepts, in bytes.
    init(maximumLength: Int) {
        self.maximumLength = maximumLength
    }

    /// Adds bytes that arrived.
    ///
    /// - Parameter data: The bytes, in arrival order.
    mutating func append(_ data: Data) {
        bytes.append(data)
    }

    /// Removes the first complete line.
    ///
    /// - Returns: The line without its line break, or `nil` when no line is complete.
    /// - Throws: ``PoolError/malformedMessage(reason:)`` when more than ``maximumLength`` bytes
    ///   wait without a line break.
    mutating func takeLine() throws(PoolError) -> Data? {
        guard let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) else {
            guard bytes.count <= maximumLength else {
                throw .malformedMessage(reason: "a line exceeds \(maximumLength) bytes")
            }
            return nil
        }
        let line = Data(bytes[bytes.startIndex ..< newline])
        bytes.removeSubrange(bytes.startIndex ... newline)
        return line
    }

    /// Removes every byte that waits, whether or not it forms a line.
    ///
    /// - Returns: The bytes.
    mutating func takeAll() -> Data {
        defer { bytes = Data() }
        return Data(bytes)
    }
}

/// The transfers that channels and byte streams share.
extension NWConnection {
    /// Waits for the next bytes from the peer.
    ///
    /// - Returns: Up to 64 KiB, or `nil` when the peer ended its sending direction, the
    ///   connection failed, or it was cancelled.
    func receiveBytes() async -> Data? {
        while true {
            let chunk: Data?? = await withCheckedContinuation { continuation in
                receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: .some(data))
                    } else if isComplete || error != nil {
                        continuation.resume(returning: .some(nil))
                    } else {
                        continuation.resume(returning: .none)
                    }
                }
            }
            if let chunk {
                return chunk
            }
        }
    }

    /// Delivers the queued sends and then signals the end of the sending direction.
    ///
    /// - Parameter timeout: The longest wait for the queued sends to leave.
    func sendEnd(within timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            let completion = NWConnection.SendCompletion.contentProcessed { _ in once.resume(returning: ()) }
            // Sends complete in order, so the final message completes after every earlier one.
            send(content: Data?.none, contentContext: .finalMessage, isComplete: true, completion: completion)
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(returning: ())
            }
        }
    }
}

/// The JSON settings that every channel uses.
enum MessageCoding {
    /// The encoder for messages, which writes one line with sorted keys and ISO 8601 dates.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The decoder for messages, which reads ISO 8601 dates.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A continuation that resumes once, whichever of several callbacks comes first.
final class ResumeOnce<Value: Sendable>: Sendable {
    /// The continuation until its first resume.
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    /// Wraps a continuation.
    ///
    /// - Parameter continuation: The continuation to resume once.
    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = Mutex(continuation)
    }

    /// Resumes the continuation unless an earlier call already did.
    ///
    /// - Parameter value: The value to resume with.
    func resume(returning value: Value) {
        let continuation = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        continuation?.resume(returning: value)
    }
}
