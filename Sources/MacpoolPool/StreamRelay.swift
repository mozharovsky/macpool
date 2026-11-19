import Foundation

/// The copying of bytes between a client's stream and the SSH server of a lease's guest.
///
/// Each direction passes a normal end on as a normal end. A failure in either direction resets
/// both connections, so a TCP peer never takes a broken stream for a complete one. A Unix socket
/// carries no reset, and a local client sees a normal end instead.
///
/// Over TLS a normal end of either direction closes the client's whole connection, because TLS
/// cannot end one direction alone. The guest then gets a normal end too.
enum StreamRelay {
    /// Copies bytes in both directions and closes both connections once both directions ended.
    ///
    /// The call returns early when the owner resets either connection.
    ///
    /// - Parameters:
    ///   - client: The client's connection.
    ///   - guest: The connection to the guest's SSH server.
    static func run(between client: ByteStream, and guest: ByteStream) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(from: client, to: guest) }
            group.addTask { await pump(from: guest, to: client) }
        }
        client.close()
        guest.close()
    }

    /// Copies one direction until its source ends, and passes the end or the failure on.
    ///
    /// - Parameters:
    ///   - source: The connection to read.
    ///   - target: The connection to write.
    private static func pump(from source: ByteStream, to target: ByteStream) async {
        do throws(PoolError) {
            while let data = try await source.receive() {
                try await target.send(data)
            }
            try await target.finishSending()
        } catch {
            // Over TLS the other direction's finish closes the client, which ends this receive.
            // The target then gets a normal end.
            if source.isClosed {
                target.close()
            } else {
                source.reset()
                target.reset()
            }
        }
    }
}
