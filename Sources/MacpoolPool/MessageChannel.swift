public import Foundation
import Network
import Synchronization

/// A connection over a Unix socket that carries one JSON message per line.
///
/// The daemon, its clients, and the VM supervisors all talk through channels. Sends are queued in
/// call order and never wait. One task at a time reads with ``receive(_:)``, which returns `nil`
/// once the peer closes the connection or the connection fails. ``close()`` ends a pending
/// receive.
public final class MessageChannel: Sendable {
    /// The longest line that a channel accepts, in bytes.
    static let maximumLineLength = 1 << 20

    /// The underlying connection.
    private let connection: NWConnection

    /// The socket's path, for error messages.
    let path: String

    /// Bytes that arrived and do not yet form a complete line.
    private let pending = Mutex(Data())

    /// Wraps a connection and starts it on its own queue.
    ///
    /// - Parameters:
    ///   - connection: A connection that a listener accepted, or one that already started.
    ///   - path: The socket's path.
    ///   - start: Whether to start the connection.
    init(connection: NWConnection, path: String, start: Bool) {
        self.connection = connection
        self.path = path
        if start {
            connection.start(queue: DispatchQueue(label: "macpool.channel"))
        }
    }

    /// Connects to a listening socket and waits until the connection is ready.
    ///
    /// - Parameters:
    ///   - socket: The socket file.
    ///   - timeout: The longest wait for the connection.
    /// - Returns: A ready channel.
    /// - Throws: ``PoolError/socketPathTooLong(path:)`` for a path that no socket can have, or
    ///   ``PoolError/connection(path:reason:)`` when the socket is missing, refuses the
    ///   connection, or does not answer in time.
    public static func connect(to socket: URL, timeout: Duration = .seconds(5)) async throws(PoolError)
        -> MessageChannel {
        let path = socket.path(percentEncoded: false)
        try SocketPath.check(path)
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        let failure: String? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            // A Unix socket that is missing or refuses connections leaves the connection waiting
            // for a path change, so waiting counts as a failure here.
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
            throw .connection(path: path, reason: failure)
        }
        return MessageChannel(connection: connection, path: path, start: false)
    }

    /// Queues a message for sending.
    ///
    /// The call does not wait for the peer. A message to a closed connection is dropped.
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
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Receives the next message.
    ///
    /// Only one task may wait at a time.
    ///
    /// - Parameter type: The message type.
    /// - Returns: The message, or `nil` once the connection has ended.
    /// - Throws: ``PoolError/malformedMessage(reason:)`` when a line is not a valid message or is
    ///   longer than 1 MiB.
    public func receive<Message: Decodable>(_ type: Message.Type) async throws(PoolError) -> Message? {
        while true {
            if let line = try takeLine() {
                do {
                    return try MessageCoding.decoder.decode(type, from: line)
                } catch {
                    throw .malformedMessage(reason: "\(error)")
                }
            }
            guard let chunk = await receiveChunk() else {
                return nil
            }
            pending.withLock { $0.append(chunk) }
        }
    }

    /// Closes the connection and ends a pending receive.
    ///
    /// Messages that are still queued may be lost. Use ``finish(within:)`` to deliver them first.
    public func close() {
        connection.cancel()
    }

    /// Delivers the queued messages, signals the end of the stream, and closes the connection.
    ///
    /// - Parameter timeout: The longest wait for the queued messages to leave.
    public func finish(within timeout: Duration = .seconds(2)) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            let completion = NWConnection.SendCompletion.contentProcessed { _ in once.resume(returning: ()) }
            // Sends complete in order, so the final message completes after every earlier one.
            connection.send(
                content: Data?.none,
                contentContext: .finalMessage,
                isComplete: true,
                completion: completion,
            )
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(returning: ())
            }
        }
        connection.cancel()
    }

    /// Removes the first complete line from the pending bytes.
    ///
    /// - Returns: The line without its line break, or `nil` when no line is complete.
    /// - Throws: ``PoolError/malformedMessage(reason:)`` when the pending bytes exceed the line
    ///   limit without a line break.
    private func takeLine() throws(PoolError) -> Data? {
        let scan: LineScan = pending.withLock { pending in
            guard let newline = pending.firstIndex(of: UInt8(ascii: "\n")) else {
                return pending.count > Self.maximumLineLength ? .overflow : .incomplete
            }
            let line = Data(pending[pending.startIndex ..< newline])
            pending.removeSubrange(pending.startIndex ... newline)
            return .line(line)
        }
        switch scan {
        case .incomplete:
            return nil
        case .overflow:
            throw .malformedMessage(reason: "a line exceeds \(Self.maximumLineLength) bytes")
        case let .line(line):
            return line
        }
    }

    /// Waits for the next bytes from the peer.
    ///
    /// - Returns: The bytes, or `nil` when the peer closed the connection or it failed.
    private func receiveChunk() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

/// The result of looking for a complete line in a channel's pending bytes.
private enum LineScan {
    /// No line break has arrived yet.
    case incomplete
    /// The pending bytes exceed the line limit without a line break.
    case overflow
    /// A complete line without its line break.
    case line(Data)
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

/// Checks of Unix socket paths.
enum SocketPath {
    /// The size of the path field in a Unix socket address, including the terminating zero byte.
    static let capacity = 104

    /// Rejects a path that does not fit in a Unix socket address.
    ///
    /// - Parameter path: The socket path.
    /// - Throws: ``PoolError/socketPathTooLong(path:)`` when the UTF-8 path has 104 bytes or more.
    static func check(_ path: String) throws(PoolError) {
        guard path.utf8.count < capacity else {
            throw .socketPathTooLong(path: path)
        }
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
