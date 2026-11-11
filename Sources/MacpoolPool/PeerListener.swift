import Foundation
import Network
import Synchronization

/// How the daemon listens for paired Macs.
public struct PeerSettings: Sendable {
    /// The host's name that a client Mac receives when it pairs.
    public var name: String

    /// The numeric IPv4 or IPv6 address to listen on, such as `127.0.0.1` or `::1`.
    ///
    /// The listener binds only to this address. It has no default, so a caller never opens every
    /// interface by accident. Network binds to every interface for a host name or an unspecified
    /// address. The listener therefore refuses a host name, `0.0.0.0`, and `::`. It also refuses
    /// an IPv6 zone such as `%en0` and a shortened IPv4 address such as `127.1`.
    public var address: String

    /// The TCP port, or 0 for a free port that the system picks.
    public var port: UInt16

    /// The wait before the daemon tries to listen again after this Mac's key, the list of paired
    /// clients, or the port failed, or after the listener stopped.
    public var retryInterval: Duration

    /// Creates listener settings.
    ///
    /// - Parameters:
    ///   - name: The host's name for clients, or `nil` for the first 64 Unicode scalars of this
    ///     Mac's name in Sharing settings. If that name has characters that a pairing rejects, the
    ///     default is `Mac`.
    ///   - address: The numeric IP address to listen on.
    ///   - port: The TCP port, or 0 for a free port.
    ///   - retryInterval: The wait before another attempt to listen.
    public init(
        name: String? = nil,
        address: String,
        port: UInt16,
        retryInterval: Duration = .seconds(10),
    ) {
        self.name = name ?? Self.computerName()
        self.address = address
        self.port = port
        self.retryInterval = retryInterval
    }

    /// Returns this Mac's name in Sharing settings in a form that a pairing accepts.
    ///
    /// - Returns: The first 64 Unicode scalars of the name, or `Mac` when they are not a valid
    ///   name.
    private static func computerName() -> String {
        let scalars = (Host.current().localizedName ?? "").unicodeScalars.prefix(PairedMac.maximumNameLength)
        let name = String(String.UnicodeScalarView(scalars))
        return PairedMac.isValidName(name) ? name : "Mac"
    }
}

/// A TCP listener that admits only Macs whose key the daemon trusts.
///
/// Every connection runs a TLS 1.3 handshake with ``PeerSecurity`` settings. A client with
/// another key fails the handshake and never reaches ``connections``. If ALPN chose no protocol
/// version that this build speaks, the listener closes the connection after the handshake.
///
/// A peer proves its key only at the end of the handshake, so anyone who reaches the port can
/// start one. The listener therefore limits the handshakes that run at once and closes a new
/// connection beyond the limit before its handshake begins. A connection whose handshake does
/// not finish in time ends, so a silent peer holds a place for a short time only.
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

    /// The fingerprint of the key that the listener presents.
    let hostKey: KeyFingerprint

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
    ///   - settings: The address and the port.
    ///   - admits: Decides whether a key may connect. The listener calls it during every
    ///     handshake on one serial queue, so a slow call delays every handshake.
    ///   - handshakeTimeout: The longest wait for a connection's handshake.
    ///   - handshakeLimit: The most handshakes that run at once.
    /// - Throws: ``PoolError/unusableIdentity(path:reason:)`` when Security rejects the key, or
    ///   ``PoolError/connection(path:reason:)`` when ``PeerSettings/address`` breaks its rules or
    ///   the listener cannot start, for example because another process holds the port.
    init(
        identity: MacIdentity,
        settings: PeerSettings,
        admits: @escaping @Sendable (KeyFingerprint) -> Bool,
        handshakeTimeout: Duration = .seconds(5),
        handshakeLimit: Int = 16,
    ) async throws(PoolError) {
        let place = "\(settings.address):\(settings.port)"
        guard let host = Self.host(settings.address) else {
            throw .connection(
                path: place,
                reason: "the listener needs a numeric IP address, "
                    + "such as 192.168.1.20, that is not 0.0.0.0 or :: and has no zone",
            )
        }
        let parameters = try PeerSecurity.parameters(identity: identity, isServer: true, admits: admits)
        let port = NWEndpoint.Port(rawValue: settings.port) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .connection(path: place, reason: "\(error)")
        }
        let (connections, continuation) = AsyncStream.makeStream(of: Peer.self)
        let handshakes = HandshakeCount(limit: handshakeLimit)
        listener.newConnectionHandler = { connection in
            guard handshakes.begin() else {
                connection.cancel()
                return
            }
            Self.admit(connection, within: handshakeTimeout, counted: handshakes, to: continuation)
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
        hostKey = KeyFingerprint(digest: identity.keyDigest)
        self.connections = connections
        self.continuation = continuation
    }

    /// Reads the address that the listener binds to.
    ///
    /// Network accepts shortened IPv4 forms such as `127.1`. The listener takes only the dotted
    /// form. The address in errors and logs is then the address that it binds.
    ///
    /// - Parameter address: The address from ``PeerSettings``.
    /// - Returns: The host, or `nil` when the address is a host name, an unspecified address, an
    ///   IPv6 address with a zone, or an IPv4 address in another form than four dotted numbers.
    private static func host(_ address: String) -> NWEndpoint.Host? {
        if let ipv4 = IPv4Address(address) {
            return ipv4 != .any && address == "\(ipv4)" ? .ipv4(ipv4) : nil
        }
        if let ipv6 = IPv6Address(address), !address.contains("%") {
            return ipv6 != .any && ipv6.asIPv4 != .any ? .ipv6(ipv6) : nil
        }
        return nil
    }

    /// Runs a connection's handshake and passes the connection on once the peer proved its key.
    ///
    /// - Parameters:
    ///   - connection: A connection that the listener accepted and that has not started.
    ///   - timeout: The longest wait for the handshake.
    ///   - handshakes: The count of running handshakes. It already includes this one. The
    ///     handshake leaves the count once it succeeds, fails, or runs out of time.
    ///   - continuation: Receives the connection after the handshake.
    private static func admit(
        _ connection: NWConnection,
        within timeout: Duration,
        counted handshakes: HandshakeCount,
        to continuation: AsyncStream<Peer>.Continuation,
    ) {
        let outcome = HandshakeOutcome(handshakes)
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
                _ = outcome.settle()
                connection.cancel()
            case .cancelled:
                _ = outcome.settle()
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

/// The number of handshakes that run at once, up to a limit.
private final class HandshakeCount: Sendable {
    /// The most handshakes that run at once.
    private let limit: Int

    /// The handshakes that run.
    private let running = Mutex(0)

    /// Creates a count of zero.
    ///
    /// - Parameter limit: The most handshakes that run at once.
    init(limit: Int) {
        self.limit = limit
    }

    /// Counts a new handshake unless the limit is reached.
    ///
    /// - Returns: Whether the handshake may run. After `true`, a call of ``end()`` must follow.
    func begin() -> Bool {
        running.withLock { running in
            guard running < limit else {
                return false
            }
            running += 1
            return true
        }
    }

    /// Stops counting a handshake that ``begin()`` counted.
    func end() {
        running.withLock { $0 -= 1 }
    }
}

/// Whether a connection's handshake finished or ran out of time, whichever came first.
///
/// The handshake leaves its ``HandshakeCount`` when the outcome settles.
private final class HandshakeOutcome: Sendable {
    /// Whether the outcome is settled.
    private let isSettled = Mutex(false)

    /// The count that includes this handshake until the outcome settles.
    private let handshakes: HandshakeCount

    /// Creates an outcome that is not settled yet.
    ///
    /// - Parameter handshakes: The count that includes this handshake.
    init(_ handshakes: HandshakeCount) {
        self.handshakes = handshakes
    }

    /// Settles the outcome unless an earlier call did.
    ///
    /// - Returns: Whether this call settled it.
    func settle() -> Bool {
        let settled = isSettled.withLock { settled in
            defer { settled = true }
            return !settled
        }
        if settled {
            handshakes.end()
        }
        return settled
    }
}
