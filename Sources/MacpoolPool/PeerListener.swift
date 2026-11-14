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
/// start one. The listener therefore gives each connection one of a limited number of places and
/// closes a new connection beyond the limit before its handshake begins. A connection whose
/// handshake does not finish in time ends, so a silent peer holds a place for a short time only.
///
/// A connection keeps its place after the handshake until the owner calls
/// ``HandshakePlace/release()`` on ``Peer/place``. Connections that wait in ``connections`` for
/// a busy owner therefore count against the limit, and each of them holds a file descriptor.
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

        /// The connection's place under the listener's handshake limit.
        ///
        /// The owner releases it after it decides to serve the connection, let it pair, or close
        /// it.
        let place: HandshakePlace
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
    ///   - handshakeLimit: The most connections that run their handshake or wait for the owner
    ///     to release their place.
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
        guard let host = Self.listeningHost(for: settings.address) else {
            throw .connection(
                path: place,
                reason: "the listener needs a numeric IP address, "
                    + "such as 192.0.2.20, that is not 0.0.0.0 or :: and has no zone",
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
        let places = HandshakeCount(limit: handshakeLimit)
        listener.newConnectionHandler = { connection in
            guard let place = places.take() else {
                connection.cancel()
                return
            }
            Self.admit(connection, within: handshakeTimeout, holding: place, to: continuation)
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
    /// Network accepts shortened IPv4 forms such as `127.1`. The listener takes only the
    /// canonical dotted form. An IPv4 address in errors and logs is then the address that the
    /// listener binds.
    ///
    /// - Parameter address: The address from ``PeerSettings``.
    /// - Returns: The host, or `nil` when the address is a host name, an unspecified address, an
    ///   IPv6 address with a zone, or an IPv4 address that differs from its canonical dotted form.
    static func listeningHost(for address: String) -> NWEndpoint.Host? {
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
    ///   - place: The connection's place. A failed handshake releases it, and a successful one
    ///     passes it on with the connection.
    ///   - continuation: Receives the connection after the handshake.
    private static func admit(
        _ connection: NWConnection,
        within timeout: Duration,
        holding place: HandshakePlace,
        to continuation: AsyncStream<Peer>.Continuation,
    ) {
        let outcome = HandshakeOutcome(place)
        let peer = "\(connection.endpoint)"
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let place = outcome.succeed() else {
                    return
                }
                // Network finishes the handshake with a client that offers no ALPN at all.
                guard let fingerprint = PeerSecurity.peerFingerprint(of: connection),
                      let version = PeerSecurity.negotiatedVersion(of: connection) else {
                    connection.cancel()
                    place.release()
                    return
                }
                let channel = MessageChannel(connection: connection, peer: peer, start: false)
                let admitted = Peer(channel: channel, fingerprint: fingerprint, version: version, place: place)
                if case .terminated = continuation.yield(admitted) {
                    channel.close()
                    place.release()
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
        outcome.arm(Task {
            try? await Task.sleep(for: timeout)
            if outcome.settle() {
                connection.cancel()
            }
        })
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

/// The number of connections that hold a handshake place, up to a limit.
final class HandshakeCount: Sendable {
    /// The most places that connections hold at once.
    private let limit: Int

    /// The number of places that connections hold.
    private let taken = Mutex(0)

    /// Creates a count of zero.
    ///
    /// - Parameter limit: The most places that connections hold at once.
    init(limit: Int) {
        self.limit = limit
    }

    /// Takes a place for a new connection unless every place is taken.
    ///
    /// - Returns: The place, or `nil` when every place is taken. The connection's owner must
    ///   release the place.
    func take() -> HandshakePlace? {
        let isFree = taken.withLock { taken in
            guard taken < limit else {
                return false
            }
            taken += 1
            return true
        }
        return isFree ? HandshakePlace(in: self) : nil
    }

    /// Frees a place that ``take()`` gave.
    fileprivate func free() {
        taken.withLock { $0 -= 1 }
    }
}

/// One connection's place in a ``HandshakeCount``.
///
/// The place is taken from the moment the listener accepts the connection. It stays taken after
/// the handshake until the owner of the connection releases it.
final class HandshakePlace: Sendable {
    /// The count that includes this place until its release.
    private let count: HandshakeCount

    /// Whether the place was released.
    private let isReleased = Mutex(false)

    /// Creates a place that the count already includes.
    ///
    /// - Parameter count: The count that includes the place.
    fileprivate init(in count: HandshakeCount) {
        self.count = count
    }

    /// Frees the place unless an earlier call did.
    func release() {
        let releases = isReleased.withLock { isReleased in
            defer { isReleased = true }
            return !isReleased
        }
        if releases {
            count.free()
        }
    }
}

/// Whether a connection's handshake finished or ran out of time, whichever came first.
///
/// A handshake that fails or runs out of time releases its ``HandshakePlace`` when the outcome
/// settles. A successful handshake keeps the place for the connection. Settling also cancels the
/// timer, because the timer holds the connection until it ends.
final class HandshakeOutcome: Sendable {
    /// The state that the lock guards.
    private struct State {
        /// Whether the outcome is settled.
        var isSettled = false

        /// The task that ends the handshake when it runs out of time.
        var timer: Task<Void, Never>?
    }

    /// The outcome's state.
    private let state = Mutex(State())

    /// The place of the handshake's connection.
    private let place: HandshakePlace

    /// Creates an outcome that is not settled yet.
    ///
    /// - Parameter place: The place of the handshake's connection.
    init(_ place: HandshakePlace) {
        self.place = place
    }

    /// Keeps the timer of the handshake, or cancels it when the outcome is already settled.
    ///
    /// - Parameter timer: The task that ends the handshake when it runs out of time.
    func arm(_ timer: Task<Void, Never>) {
        let isSettled = state.withLock { state in
            if !state.isSettled {
                state.timer = timer
            }
            return state.isSettled
        }
        if isSettled {
            timer.cancel()
        }
    }

    /// Settles a failed handshake unless an earlier call settled the outcome, cancels the
    /// timer, and releases the place.
    ///
    /// - Returns: Whether this call settled the outcome.
    func settle() -> Bool {
        let isFirst = settleOnce()
        if isFirst {
            place.release()
        }
        return isFirst
    }

    /// Settles a successful handshake unless an earlier call settled the outcome, and cancels
    /// the timer.
    ///
    /// - Returns: The place, or `nil` when an earlier call settled the outcome. The place stays
    ///   taken.
    func succeed() -> HandshakePlace? {
        settleOnce() ? place : nil
    }

    /// Marks the outcome settled and cancels the timer.
    ///
    /// - Returns: Whether this call settled the outcome.
    private func settleOnce() -> Bool {
        let settled = state.withLock { state -> (isFirst: Bool, timer: Task<Void, Never>?) in
            guard !state.isSettled else {
                return (false, nil)
            }
            state.isSettled = true
            defer { state.timer = nil }
            return (true, state.timer)
        }
        settled.timer?.cancel()
        return settled.isFirst
    }
}
