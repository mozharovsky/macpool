/// Connections from a client to the daemon.
public enum PoolClient {
    /// Connects to the daemon that serves a data directory.
    ///
    /// - Parameter directory: The daemon's data directory.
    /// - Returns: A ready connection.
    /// - Throws: ``PoolError/daemonUnreachable(path:reason:)`` when no daemon listens, or
    ///   ``PoolError/socketPathTooLong(path:)`` for a data directory whose socket cannot exist.
    public static func connect(to directory: PoolDirectory) async throws(PoolError) -> MessageChannel {
        do {
            return try await MessageChannel.connect(to: directory.daemonSocket)
        } catch let .connection(path, reason) {
            throw .daemonUnreachable(path: path, reason: reason)
        } catch {
            throw error
        }
    }

    /// Sends one request and returns the daemon's first reply.
    ///
    /// - Parameters:
    ///   - request: The request, which must not be a lease request.
    ///   - directory: The daemon's data directory.
    /// - Returns: The reply.
    /// - Throws: ``PoolError/daemonRefused(message:)`` when the daemon answers with a failure,
    ///   ``PoolError/connectionClosed`` when it closes the connection first, or another
    ///   ``PoolError`` when the connection fails.
    public static func send(_ request: PoolRequest, to directory: PoolDirectory) async throws(PoolError) -> PoolReply {
        let channel = try await connect(to: directory)
        defer { channel.close() }
        try channel.send(request)
        guard let reply = try await channel.receive(PoolReply.self) else {
            throw .connectionClosed
        }
        if case let .failure(message) = reply {
            throw .daemonRefused(message: message)
        }
        return reply
    }
}
