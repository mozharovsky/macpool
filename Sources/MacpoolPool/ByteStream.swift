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
/// peer should get every byte. ``reset()`` ends it so that the peer sees a failure. A stream that
/// goes away without ``close()`` cancels its connection when it is deinitialized. The peer then
/// still sees the end, at a moment that the owner does not choose, and bytes that have not left
/// yet may be lost.
public final class ByteStream: Sendable {
    /// The underlying connection.
    private let connection: NWConnection

    /// The socket path or network endpoint of the peer, for error messages.
    let peer: String

    /// The bytes from before the handoff, the end of the receiving direction, and whether the
    /// owner closed the stream.
    private let state: Mutex<StreamState>

    /// Whether the connection runs TLS.
    ///
    /// Network cannot end only one direction of a TLS connection.
    private let carriesTLS: Bool

    /// Takes over a connection from a channel.
    ///
    /// - Parameters:
    ///   - connection: A started connection.
    ///   - peer: The socket path or network endpoint of the peer, for error messages.
    ///   - leftover: The bytes that the channel received after its last line.
    ///   - end: How the receiving direction ended, if the channel already saw the end.
    init(connection: NWConnection, peer: String, leftover: Data, end: ReceiveEnd?) {
        self.connection = connection
        self.peer = peer
        state = Mutex(StreamState(leftover: leftover, end: end))
        carriesTLS = connection.parameters.defaultProtocolStack.applicationProtocols.contains {
            $0 is NWProtocolTLS.Options
        }
    }

    /// Cancels the connection, so a stream that its owner dropped still ends the peer's reads.
    deinit {
        connection.cancel()
    }

    /// Receives the next bytes.
    ///
    /// The wait ignores task cancellation, so the owner calls ``close()`` or ``reset()`` to end it
    /// early.
    ///
    /// - Returns: The bytes that arrived before the handoff, then up to 64 KiB per call, or `nil`
    ///   once the peer ended its sending direction.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the connection failed, the peer reset
    ///   it, or the stream closed it.
    public func receive() async throws(PoolError) -> Data? {
        let known = state.withLock { state -> ReceivedBytes? in
            if state.isClosed {
                return .ended(Self.closed)
            }
            if !state.leftover.isEmpty {
                defer { state.leftover = Data() }
                return .bytes(state.leftover, then: nil)
            }
            return state.end.map(ReceivedBytes.ended)
        }
        let received: ReceivedBytes
        if let known {
            received = known
        } else {
            let arrived = await connection.receiveBytes()
            // Network reports the end once, sometimes with the last bytes. Later receives would
            // fail instead.
            received = state.withLock { state in
                if case let .bytes(_, then: end?) = arrived {
                    state.end = end
                } else if case let .ended(end) = arrived {
                    state.end = end
                }
                // A close during the wait can make Network report a normal end.
                if state.isClosed, case .ended = arrived {
                    return .ended(Self.closed)
                }
                return arrived
            }
        }
        switch received {
        case let .bytes(data, _):
            return data
        case .ended(.finished):
            return nil
        case let .ended(.failed(reason)):
            throw .connection(path: peer, reason: reason)
        }
    }

    /// The end that receives report after the owner closed the stream.
    private static let closed = ReceiveEnd.failed("the stream was closed")

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

    /// Ends the sending direction after the bytes sent so far.
    ///
    /// Over TCP and Unix sockets the stream keeps receiving. Network does not pass the end of one
    /// direction through TLS. Over TLS the call therefore closes the connection once the bytes
    /// left, and receives fail from then on.
    ///
    /// - Parameter timeout: The longest wait for the bytes sent so far to leave.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the bytes did not leave within
    ///   `timeout` or the connection failed. The call then resets the connection, so the peer
    ///   sees a failure instead of a normal end.
    public func finishSending(within timeout: Duration = .seconds(2)) async throws(PoolError) {
        if let failure = await connection.sendEnd(within: timeout) {
            reset()
            throw .connection(path: peer, reason: failure)
        }
        if carriesTLS {
            close()
        }
    }

    /// Closes the connection and ends a pending receive or send.
    ///
    /// Bytes that have not left yet may be lost. Call ``finishSending(within:)`` first to deliver
    /// them.
    public func close() {
        state.withLock { $0.isClosed = true }
        connection.cancel()
    }

    /// Ends the connection at once and drops the bytes that wait to leave.
    ///
    /// A TCP peer sees a reset instead of a normal end. Use it to pass a failure on to the peer.
    public func reset() {
        state.withLock { $0.isClosed = true }
        connection.forceCancel()
    }
}

/// What a stream knows about its connection besides Network's state.
private struct StreamState {
    /// The bytes that arrived before the handoff, which the next receive returns first.
    var leftover: Data

    /// How the receiving direction ended, once a receive saw the end.
    var end: ReceiveEnd?

    /// Whether the owner closed or reset the stream, or a finish over TLS closed it.
    var isClosed = false
}
