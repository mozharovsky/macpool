public import Foundation
import Network
import Synchronization

/// A connection that carries raw bytes after a ``MessageChannel`` stopped reading lines.
///
/// ``MessageChannel/takeStream()`` creates the stream, which then owns the connection. One task at
/// a time receives and one task at a time sends. ``send(_:)`` returns once Network has taken the
/// bytes, so a loop that receives from one stream and sends to another moves data no faster than
/// the slower side accepts it.
///
/// The owner ends the connection with ``close()``, after ``finishSending(within:)`` when the
/// peer should get every byte. A stream that goes away without ``close()`` cancels its connection
/// when it is deinitialized. The peer then still sees the end, at a moment that the owner does not
/// choose, and bytes that have not left yet may be lost.
public final class ByteStream: Sendable {
    /// The underlying connection.
    private let connection: NWConnection

    /// The socket path or network endpoint of the peer, for error messages.
    let peer: String

    /// The bytes that arrived before the handoff, which the next receive returns first.
    private let leftover: Mutex<Data>

    /// Takes over a connection from a channel.
    ///
    /// - Parameters:
    ///   - connection: A started connection.
    ///   - peer: The socket path or network endpoint of the peer, for error messages.
    ///   - leftover: The bytes that the channel received after its last line.
    init(connection: NWConnection, peer: String, leftover: Data) {
        self.connection = connection
        self.peer = peer
        self.leftover = Mutex(leftover)
    }

    /// Cancels the connection, so a stream that its owner dropped still ends the peer's reads.
    deinit {
        connection.cancel()
    }

    /// Receives the next bytes.
    ///
    /// The wait ignores task cancellation, so the owner calls ``close()`` to end it early.
    ///
    /// - Returns: The bytes that arrived before the handoff, then up to 64 KiB per call, or `nil`
    ///   once the peer ended its sending direction, the connection failed, or it was closed.
    public func receive() async -> Data? {
        let early = leftover.withLock { leftover in
            defer { leftover = Data() }
            return leftover
        }
        guard early.isEmpty else {
            return early
        }
        return await connection.receiveBytes()
    }

    /// Sends bytes and waits until Network has taken them.
    ///
    /// The wait lasts as long as the peer reads nothing and Network's buffer is full. It ignores
    /// task cancellation, so the owner calls ``close()`` to end it early.
    ///
    /// - Parameter data: The bytes.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the connection failed or was closed.
    public func send(_ data: Data) async throws(PoolError) {
        let failure: String? = await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error.map { "\($0)" })
            })
        }
        if let failure {
            throw .connection(path: peer, reason: failure)
        }
    }

    /// Ends the sending direction after the bytes sent so far and keeps receiving.
    ///
    /// - Parameter timeout: The longest wait for the bytes sent so far to leave.
    public func finishSending(within timeout: Duration = .seconds(2)) async {
        await connection.sendEnd(within: timeout)
    }

    /// Closes the connection and ends a pending receive or send.
    ///
    /// Bytes that have not left yet may be lost. Call ``finishSending(within:)`` first to deliver
    /// them.
    public func close() {
        connection.cancel()
    }
}
