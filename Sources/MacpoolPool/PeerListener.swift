import Foundation
import Network
import Synchronization

/// How the daemon listens for paired Macs.
public struct PeerSettings: Sendable {
    /// The local address to listen on, such as `127.0.0.1`, or `nil` for every address.
    public var address: String?

    /// The TCP port, or 0 for a free port that the system picks.
    public var port: UInt16

    /// Returns the fingerprints of the keys that may connect.
    ///
    /// The listener calls it during every handshake, so a key that leaves the set opens no new
    /// connection. An empty set admits nobody. The call runs on the handshake's queue and should
    /// return quickly.
    public var trustedKeys: @Sendable () -> Set<KeyFingerprint>

    /// The wait before the daemon tries to listen again after this Mac's key or the port failed,
    /// or after the listener stopped.
    public var retryInterval: Duration

    /// Creates listener settings.
    ///
    /// - Parameters:
    ///   - address: The local address to listen on, or `nil` for every address.
    ///   - port: The TCP port, or 0 for a free port.
    ///   - trustedKeys: Returns the fingerprints of the keys that may connect.
    ///   - retryInterval: The wait before another attempt to listen.
    public init(
        address: String? = nil,
        port: UInt16,
        trustedKeys: @escaping @Sendable () -> Set<KeyFingerprint>,
        retryInterval: Duration = .seconds(10),
    ) {
        self.address = address
        self.port = port
        self.trustedKeys = trustedKeys
        self.retryInterval = retryInterval
    }
}

/// A TCP listener that admits only Macs whose key the daemon trusts.
///
/// Every connection runs a TLS 1.3 handshake with ``PeerSecurity`` settings. A client with
/// another key fails the handshake and never reaches ``connections``. If ALPN chose no protocol
/// version that this build speaks, the listener closes the connection after the handshake. A
/// connection whose handshake does not finish in time ends, so a silent peer holds no socket for
/// long.
///
/// ``connections`` ends when ``close()`` runs or the listener fails after it was ready.
final class PeerListener: Sendable {
    /// A connection from a Mac that proved a trusted key.
    struct Peer: Sendable {
        /// The connection, ready for messages.
        let channel: MessageChannel

        /// The fingerprint of the key that the Mac proved.
        let fingerprint: KeyFingerprint

        /// The protocol version that ALPN chose.
        let version: Int
    }

    /// The underlying listener.
    private let listener: NWListener

    /// The port on which the listener accepts connections.
    let port: UInt16

    /// The connections that finished their handshake.
    ///
    /// The stream ends when the listener closes or fails.
    let connections: AsyncStream<Peer>

    /// The continuation that feeds ``connections``.
    private let continuation: AsyncStream<Peer>.Continuation

    /// Starts listening and waits until the listener is ready.
    ///
    /// - Parameters:
    ///   - identity: This Mac's key and certificate.
    ///   - settings: The address, the port, and the trusted keys.
    ///   - handshakeTimeout: The longest wait for a connection's handshake.
    /// - Throws: ``PoolError/unusableIdentity(path:reason:)`` when Security rejects the key, or
    ///   ``PoolError/connection(path:reason:)`` when the listener cannot start, for example
    ///   because another process holds the port.
    init(
        identity: MacIdentity,
        settings: PeerSettings,
        handshakeTimeout: Duration = .seconds(10),
    ) async throws(PoolError) {
        let trustedKeys = settings.trustedKeys
        let parameters = try PeerSecurity.parameters(identity: identity, isServer: true) { key in
            trustedKeys().contains(key)
        }
        let port = NWEndpoint.Port(rawValue: settings.port) ?? .any
        let place = "\(settings.address ?? "*"):\(settings.port)"
        let listener: NWListener
        do {
            if let address = settings.address {
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
                listener = try NWListener(using: parameters)
            } else {
                listener = try NWListener(using: parameters, on: port)
            }
        } catch {
            throw .connection(path: place, reason: "\(error)")
        }
        let (connections, continuation) = AsyncStream.makeStream(of: Peer.self)
        listener.newConnectionHandler = { connection in
            Self.admit(connection, within: handshakeTimeout, to: continuation)
        }
        let failure: String? = await withCheckedContinuation { ready in
            let once = ResumeOnce(ready)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: nil)
                case let .failed(error), let .waiting(error):
                    once.resume(returning: "\(error)")
                    // After a listener stops, it accepts no more connections. The end of the
                    // stream tells the owner to listen again.
                    continuation.finish()
                case .cancelled:
                    once.resume(returning: "cancelled")
                    continuation.finish()
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "macpool.peer.listener"))
        }
        guard failure == nil, let bound = listener.port?.rawValue else {
            listener.cancel()
            continuation.finish()
            throw .connection(path: place, reason: failure ?? "no port")
        }
        self.listener = listener
        self.port = bound
        self.connections = connections
        self.continuation = continuation
    }

    /// Runs a connection's handshake and passes the connection on once the peer proved its key.
    ///
    /// - Parameters:
    ///   - connection: A connection that the listener accepted and that has not started.
    ///   - timeout: The longest wait for the handshake.
    ///   - continuation: Receives the connection after the handshake.
    private static func admit(
        _ connection: NWConnection,
        within timeout: Duration,
        to continuation: AsyncStream<Peer>.Continuation,
    ) {
        let outcome = HandshakeOutcome()
        let peer = "\(connection.endpoint)"
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard outcome.settle() else {
                    return
                }
                // Network finishes the handshake with a client that offers no ALPN at all.
                guard let fingerprint = PeerSecurity.peerFingerprint(of: connection),
                      let version = PeerSecurity.negotiatedVersion(of: connection) else {
                    connection.cancel()
                    return
                }
                let channel = MessageChannel(connection: connection, peer: peer, start: false)
                let admitted = Peer(channel: channel, fingerprint: fingerprint, version: version)
                if case .terminated = continuation.yield(admitted) {
                    channel.close()
                }
            case .failed, .waiting:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "macpool.peer.connection"))
        Task {
            try? await Task.sleep(for: timeout)
            if outcome.settle() {
                connection.cancel()
            }
        }
    }

    /// Stops listening and ends ``connections``.
    ///
    /// Connections that were already accepted stay open.
    func close() {
        listener.newConnectionHandler = nil
        listener.cancel()
        continuation.finish()
    }
}

/// Whether a connection's handshake finished or ran out of time, whichever came first.
private final class HandshakeOutcome: Sendable {
    /// Whether the outcome is settled.
    private let isSettled = Mutex(false)

    /// Settles the outcome unless an earlier call did.
    ///
    /// - Returns: Whether this call settled it.
    func settle() -> Bool {
        isSettled.withLock { settled in
            defer { settled = true }
            return !settled
        }
    }
}
