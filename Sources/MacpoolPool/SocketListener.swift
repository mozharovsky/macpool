public import Foundation
import Network

/// A listening Unix socket that yields a ``MessageChannel`` for each connection.
///
/// The socket file takes the process's default permissions. The pool keeps its sockets in a
/// directory that only the owner can enter, which keeps other users out.
public final class SocketListener: Sendable {
    /// The underlying listener.
    private let listener: NWListener

    /// The socket's path.
    private let path: String

    /// The accepted connections, which end when the listener closes.
    public let connections: AsyncStream<MessageChannel>

    /// The continuation that feeds ``connections``.
    private let continuation: AsyncStream<MessageChannel>.Continuation

    /// Starts listening on a socket path and waits until the listener is ready.
    ///
    /// A file left at the path by an earlier process is removed first. Callers make sure that no
    /// other live process listens there, for example through a lock.
    ///
    /// - Parameter socket: The socket file to create.
    /// - Throws: ``PoolError/socketPathTooLong(path:)`` for a path that no socket can have, or
    ///   ``PoolError/connection(path:reason:)`` when the listener cannot start.
    public init(socket: URL) async throws(PoolError) {
        let path = socket.path(percentEncoded: false)
        try SocketPath.check(path)
        guard unlink(path) == 0 || errno == ENOENT else {
            throw .systemCall("removing the stale socket", socket)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .connection(path: path, reason: "\(error)")
        }
        let (connections, continuation) = AsyncStream.makeStream(of: MessageChannel.self)
        listener.newConnectionHandler = { connection in
            continuation.yield(MessageChannel(connection: connection, path: path, start: true))
        }
        let failure: String? = await withCheckedContinuation { ready in
            let once = ResumeOnce(ready)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: nil)
                case let .failed(error), let .waiting(error):
                    once.resume(returning: "\(error)")
                case .cancelled:
                    once.resume(returning: "cancelled")
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "macpool.listener"))
        }
        guard failure == nil else {
            listener.cancel()
            continuation.finish()
            throw .connection(path: path, reason: failure ?? "")
        }
        self.listener = listener
        self.path = path
        self.connections = connections
        self.continuation = continuation
    }

    /// Stops listening, ends ``connections``, and removes the socket file.
    ///
    /// Connections that were already accepted stay open.
    public func close() {
        listener.newConnectionHandler = nil
        listener.cancel()
        continuation.finish()
        unlink(path)
    }
}
