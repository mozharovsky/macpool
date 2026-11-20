import Foundation
import Network
import Synchronization

/// Connections from a client to the daemon.
public enum PoolClient {
    /// The interval at which a connection to another Mac's daemon sends
    /// ``PoolRequest/heartbeat``.
    ///
    /// A host closes a paired Mac's connection after 60 seconds without a request. Three
    /// heartbeats fit in that time, so one lost heartbeat does not cost the connection.
    public static let heartbeatInterval = Duration.seconds(20)

    /// Connects to the daemon that serves a data directory.
    ///
    /// - Parameter directory: The daemon's data directory.
    /// - Returns: A ready connection.
    /// - Throws: ``PoolError/daemonUnreachable(path:reason:)`` when no daemon listens, or
    ///   ``PoolError/socketPathTooLong(path:length:)`` for a data directory whose socket cannot
    ///   exist.
    public static func connect(to directory: PoolDirectory) async throws(PoolError) -> MessageChannel {
        do {
            return try await MessageChannel.connect(to: directory.daemonSocket)
        } catch let .connection(path, reason) {
            throw .daemonUnreachable(path: path, reason: reason)
        } catch {
            throw error
        }
    }

    /// Connects to the daemon of another Mac and waits for its greeting.
    ///
    /// Both Macs prove their keys in the TLS handshake. The host must present the pinned key. A
    /// host that refuses this Mac's key lets the handshake finish on this side and then closes
    /// the connection, so only its greeting confirms that it accepted the key.
    ///
    /// The connection sends ``PoolRequest/heartbeat`` at `heartbeat` intervals until it closes or
    /// a ``ByteStream`` takes it. A heartbeat after ``PoolRequest/connect(_:)`` would reach the
    /// guest, so open a stream on a connection from another call.
    ///
    /// - Parameters:
    ///   - endpoint: The host's address and port.
    ///   - identity: This Mac's key and certificate.
    ///   - hostKey: The fingerprint of the key that the host must present.
    ///   - timeout: The longest wait for the handshake, and then for the greeting.
    ///   - protocols: The application protocols to offer, in order of preference.
    ///   - closedReason: The reason in the error when the host closes the connection before its
    ///     greeting.
    ///   - heartbeat: The interval between heartbeats.
    /// - Returns: A connection that is ready for requests.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the connection fails, the host
    ///   presents another key, refuses this Mac's key or the connection, closes the connection or
    ///   stays silent before its greeting, or greets with another protocol version or role, or
    ///   ``PoolError/unusableIdentity(path:reason:)`` when Security rejects this Mac's key.
    static func connect(
        to endpoint: NWEndpoint,
        as identity: MacIdentity,
        hostKey: KeyFingerprint,
        timeout: Duration = .seconds(10),
        protocols: [String] = [PeerSecurity.protocolName],
        closedReason: String = "the host closed the connection, so it does not accept this Mac's key",
        heartbeat: Duration = heartbeatInterval,
    ) async throws(PoolError) -> MessageChannel {
        let channel = try await connect(
            to: endpoint,
            as: identity,
            timeout: timeout,
            protocols: protocols,
            closedReason: closedReason,
            expected: hostKey.rawValue,
        ) { $0 == hostKey }
        startHeartbeat(on: channel, every: heartbeat)
        return channel
    }

    /// Sends heartbeats on a channel until the channel closes or goes away.
    ///
    /// - Parameters:
    ///   - channel: A connection to another Mac's daemon.
    ///   - interval: The time between heartbeats.
    static func startHeartbeat(on channel: MessageChannel, every interval: Duration) {
        Task { [weak channel] in
            while true {
                try? await Task.sleep(for: interval)
                guard let channel, channel.isOpen else {
                    return
                }
                try? channel.send(PoolRequest.heartbeat)
            }
        }
    }

    /// Connects to the daemon of another Mac whose key passes a check, and waits for its
    /// greeting.
    ///
    /// - Parameters:
    ///   - endpoint: The host's address and port.
    ///   - identity: This Mac's key and certificate.
    ///   - timeout: The longest wait for the handshake, and then for the greeting.
    ///   - protocols: The application protocols to offer, in order of preference.
    ///   - closedReason: The reason in the error when the host closes the connection before its
    ///     greeting.
    ///   - expected: The text that names the expected key in the error when the host presents
    ///     another key.
    ///   - accepts: Decides whether the key that the host presents is the expected one.
    /// - Returns: A connection that is ready for requests.
    /// - Throws: The errors of ``connect(to:as:hostKey:timeout:protocols:closedReason:)``.
    private static func connect(
        to endpoint: NWEndpoint,
        as identity: MacIdentity,
        timeout: Duration,
        protocols: [String],
        closedReason: String,
        expected: String,
        accepts: @escaping @Sendable (KeyFingerprint) -> Bool,
    ) async throws(PoolError) -> MessageChannel {
        let place = "\(endpoint)"
        let presented = Mutex<KeyFingerprint?>(nil)
        let parameters = try PeerSecurity.parameters(identity: identity, protocols: protocols, isServer: false) { key in
            presented.withLock { $0 = key }
            return accepts(key)
        }
        let channel: MessageChannel
        do {
            channel = try await MessageChannel.connect(to: endpoint, using: parameters, timeout: timeout)
        } catch {
            if let key = presented.withLock({ $0 }), !accepts(key) {
                throw .connection(path: place, reason: "the host presented the key \(key) instead of \(expected)")
            }
            throw error
        }
        let greeting = try await greeting(on: channel, from: place, within: timeout, closedReason: closedReason)
        guard greeting == HostGreeting(version: PeerSecurity.protocolVersion, role: .host) else {
            channel.close()
            throw .connection(
                path: place,
                reason: "the peer speaks version \(greeting.version) as \(greeting.role.rawValue), not version "
                    + "\(PeerSecurity.protocolVersion) as a host",
            )
        }
        return channel
    }

    /// Waits for a host's greeting and closes the channel when none arrives in time.
    ///
    /// - Parameters:
    ///   - channel: A connection whose handshake finished on this side.
    ///   - place: The host's address, for error messages.
    ///   - timeout: The longest wait.
    ///   - closedReason: The reason in the error when the host closes the connection.
    /// - Returns: The greeting.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the host refuses or closes the
    ///   connection, sends something else, or stays silent for `timeout`.
    private static func greeting(
        on channel: MessageChannel,
        from place: String,
        within timeout: Duration,
        closedReason: String,
    ) async throws(PoolError) -> HostGreeting {
        let watchdog = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            channel.close()
            return true
        }
        let received: Result<HostOpening?, PoolError>
        do {
            received = try await .success(channel.receive(HostOpening.self))
        } catch {
            received = .failure(error)
        }
        watchdog.cancel()
        if await watchdog.value {
            throw .connection(path: place, reason: "the host sent no greeting within \(timeout)")
        }
        switch received {
        case let .success(.greeting(greeting)?):
            return greeting
        case let .success(.refusal(reason)?):
            channel.close()
            throw .connection(path: place, reason: "the host refused the connection: \(reason)")
        case .success(nil):
            channel.close()
            throw .connection(path: place, reason: closedReason)
        case let .failure(error):
            channel.close()
            throw .connection(path: place, reason: "the host sent no greeting: \(error)")
        }
    }

    /// Pairs this Mac with a host and adds the host to `trust/hosts.json`.
    ///
    /// The host must present a key that matches the code. This Mac then proves its own key and
    /// sends the code's secret with its name. The host adds this Mac to its list of paired clients
    /// and returns its own name.
    ///
    /// Show the person who pairs the ``KeyFingerprint/shortKey`` of this Mac's key. The host shows
    /// the same text for the client it paired. If the two differ, someone else used the code.
    ///
    /// - Parameters:
    ///   - code: The code from the host.
    ///   - name: The name that the host shows to people for this Mac.
    ///   - directory: This Mac's data directory. The call creates this Mac's key if the directory
    ///     has none.
    ///   - timeout: The longest wait for the handshake, the greeting, and the host's reply, each.
    /// - Returns: The host's name and key.
    /// - Throws: ``PoolError/invalidRequest(reason:)`` when `name` cannot be shown to people,
    ///   ``PoolError/connection(path:reason:)`` when the connection fails or the host presents a
    ///   key that does not match the code, ``PoolError/daemonRefused(message:)`` when the host
    ///   refuses the code, ``PoolError/connectionClosed`` when the host closes the connection
    ///   before it replies, or ``PoolError/malformedMessage(reason:)`` when the reply is of another
    ///   kind or names another key or a host name that this Mac does not accept. Another
    ///   ``PoolError`` means that this Mac's key or the list of hosts cannot be read or written.
    public static func pair(
        using code: PairingCode,
        name: String,
        directory: PoolDirectory,
        timeout: Duration = .seconds(10),
    ) async throws(PoolError) -> PairedMac {
        guard PairedMac.isValidName(name) else {
            throw .invalidRequest(reason: "the name must have \(PairedMac.nameRule)")
        }
        guard let port = NWEndpoint.Port(rawValue: code.port) else {
            throw .invalidRequest(reason: "the code names port \(code.port)")
        }
        let identity = try MacIdentity.loadOrCreate(in: directory)
        let matching = Mutex<KeyFingerprint?>(nil)
        let channel = try await connect(
            to: .hostPort(host: NWEndpoint.Host(code.address), port: port),
            as: identity,
            timeout: timeout,
            protocols: [PeerSecurity.protocolName],
            closedReason: "the host closed the connection, so the code was used, expired, or replaced",
            expected: "a key that matches the code",
        ) { key in
            guard code.matches(key) else {
                return false
            }
            matching.withLock { $0 = key }
            return true
        }
        defer { channel.close() }
        guard let hostKey = matching.withLock({ $0 }) else {
            throw .connection(path: "\(code.address):\(code.port)", reason: "the host proved no key")
        }
        try channel.send(PoolRequest.pair(secret: Base32.encode(code.secret), name: name))
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            channel.close()
        }
        let reply = try await channel.receive(PoolReply.self)
        watchdog.cancel()
        switch reply {
        case let .paired(host)? where host.key == hostKey && PairedMac.isValidName(host.name):
            var hosts = try TrustList<TrustedHost>.load(from: directory)
            hosts.insert(TrustedHost(
                key: hostKey,
                name: host.name,
                address: code.address,
                port: code.port,
                pairedAt: Date(),
            ))
            try hosts.save(to: directory)
            return host
        case let .paired(host)? where host.key == hostKey:
            throw .malformedMessage(reason: "the host's name has characters that macOS on this Mac does not accept. "
                + "The host recorded this Mac. Change the host's name and pair again with a new code")
        case let .failure(message)?:
            throw .daemonRefused(message: message)
        case nil:
            throw .connectionClosed
        case let reply?:
            // The host chose the texts in the reply, and a terminal shows an error as it is. The error
            // therefore names only the kind.
            throw .malformedMessage(reason: "the host replied to a pairing with an unexpected \(reply.kind) reply")
        }
    }

    /// Opens a byte stream to the SSH server of a ready lease's guest on this Mac.
    ///
    /// The stream carries the bytes of the guest's SSH server until the lease stops being ready
    /// or the daemon stops. Over the local socket, ``ByteStream/finishSending(within:)`` ends only
    /// the direction to the guest.
    ///
    /// - Parameters:
    ///   - lease: The lease.
    ///   - directory: The daemon's data directory.
    ///   - timeout: The longest wait for the daemon's reply, which follows the guest's answer.
    /// - Returns: The stream and the lease.
    /// - Throws: ``PoolError/daemonUnreachable(path:reason:)`` when no daemon listens,
    ///   ``PoolError/daemonRefused(message:)`` when the lease is unknown or not ready or the guest
    ///   refuses the connection, ``PoolError/connection(path:reason:)`` when no reply arrives in
    ///   time, or ``PoolError/connectionClosed`` when the daemon closes the connection first.
    public static func openStream(
        to lease: LeaseID,
        in directory: PoolDirectory,
        timeout: Duration = .seconds(30),
    ) async throws(PoolError) -> GuestStream {
        let channel = try await connect(to: directory)
        return try await openStream(
            to: lease,
            on: channel,
            place: directory.daemonSocket.path(percentEncoded: false),
            timeout: timeout,
        )
    }

    /// Opens a byte stream to the SSH server of a ready lease's guest on a paired host.
    ///
    /// The host must present the key in `host`. Network cannot end one direction of a TLS
    /// connection, so ``ByteStream/finishSending(within:)`` on the stream ends both directions.
    ///
    /// - Parameters:
    ///   - lease: The lease, which this Mac must own.
    ///   - host: The host from this Mac's list of paired hosts.
    ///   - directory: This Mac's data directory, which holds its key.
    ///   - timeout: The longest wait for the handshake, the greeting, and then the host's reply.
    /// - Returns: The stream and the lease as the host shows it to this Mac.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the connection fails or the host
    ///   presents another key, ``PoolError/daemonRefused(message:)`` when the host refuses the
    ///   request, ``PoolError/connectionClosed`` when the host closes the connection first, or
    ///   another ``PoolError`` when this Mac's key cannot be read.
    public static func openStream(
        to lease: LeaseID,
        on host: TrustedHost,
        directory: PoolDirectory,
        timeout: Duration = .seconds(30),
    ) async throws(PoolError) -> GuestStream {
        let channel = try await connectForOneRequest(to: host, directory: directory, timeout: timeout)
        return try await openStream(to: lease, on: channel, place: place(of: host), timeout: timeout)
    }

    /// Asks the daemon on this Mac for the account and the pinned host keys of a ready lease's
    /// guest.
    ///
    /// The daemon reads them from the lease's bundle and connects to no guest.
    ///
    /// - Parameters:
    ///   - lease: The lease.
    ///   - directory: The daemon's data directory.
    ///   - timeout: The longest wait for the daemon's reply.
    /// - Returns: The access.
    /// - Throws: ``PoolError/daemonUnreachable(path:reason:)`` when no daemon listens,
    ///   ``PoolError/daemonRefused(message:)`` when the lease is unknown or not ready or the daemon
    ///   cannot read the access, ``PoolError/connection(path:reason:)`` when no reply arrives in
    ///   time, ``PoolError/connectionClosed`` when the daemon closes the connection first, or
    ///   ``PoolError/malformedMessage(reason:)`` when the reply is of another kind.
    public static func guestAccess(
        to lease: LeaseID,
        in directory: PoolDirectory,
        timeout: Duration = .seconds(10),
    ) async throws(PoolError) -> GuestAccess {
        let channel = try await connect(to: directory)
        defer { channel.close() }
        let place = directory.daemonSocket.path(percentEncoded: false)
        return try await access(in: firstReply(to: .access(lease), on: channel, place: place, timeout: timeout))
    }

    /// Asks a paired host for the account and the pinned host keys of a ready lease's guest.
    ///
    /// The host must present the key in `host`. It reads the access from the lease's bundle and
    /// connects to no guest.
    ///
    /// - Parameters:
    ///   - lease: The lease, which this Mac must own.
    ///   - host: The host from this Mac's list of paired hosts.
    ///   - directory: This Mac's data directory, which holds its key.
    ///   - timeout: The longest wait for the handshake, the greeting, and then the host's reply.
    /// - Returns: The access.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the connection fails, the host
    ///   presents another key, or no reply arrives in time, ``PoolError/daemonRefused(message:)``
    ///   when the host refuses the request, ``PoolError/connectionClosed`` when the host closes the
    ///   connection first, ``PoolError/malformedMessage(reason:)`` when the reply is of another
    ///   kind, or another ``PoolError`` when this Mac's key cannot be read.
    public static func guestAccess(
        to lease: LeaseID,
        on host: TrustedHost,
        directory: PoolDirectory,
        timeout: Duration = .seconds(10),
    ) async throws(PoolError) -> GuestAccess {
        let channel = try await connectForOneRequest(to: host, directory: directory, timeout: timeout)
        defer { channel.close() }
        return try await access(in: firstReply(
            to: .access(lease),
            on: channel,
            place: place(of: host),
            timeout: timeout,
        ))
    }

    /// Connects to a paired host for requests and waits for its greeting.
    ///
    /// The host must present the key in `host`. The connection sends ``PoolRequest/heartbeat``
    /// every ``heartbeatInterval`` until it closes, so the host keeps it while a lease request
    /// waits or a lease stays attached. Open a stream with
    /// ``openStream(to:on:directory:timeout:)``, which uses a connection of its own.
    ///
    /// - Parameters:
    ///   - host: The host from this Mac's list of paired hosts.
    ///   - directory: This Mac's data directory, which holds its key.
    ///   - timeout: The longest wait for the handshake, and then for the greeting.
    /// - Returns: A connection that is ready for requests.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the list names an invalid port, the
    ///   connection fails, or the host presents another key, refuses this Mac's key, or greets
    ///   badly or not in time, or another ``PoolError`` when this Mac's key cannot be read.
    public static func connect(
        to host: TrustedHost,
        directory: PoolDirectory,
        timeout: Duration = .seconds(10),
    ) async throws(PoolError) -> MessageChannel {
        try await connect(to: host, directory: directory, timeout: timeout, heartbeat: heartbeatInterval)
    }

    /// Connects to a paired host for requests with a given interval between heartbeats.
    ///
    /// - Parameters:
    ///   - host: The host from this Mac's list of paired hosts.
    ///   - directory: This Mac's data directory, which holds its key.
    ///   - timeout: The longest wait for the handshake, and then for the greeting.
    ///   - heartbeat: The interval between heartbeats.
    /// - Returns: A connection that is ready for requests.
    /// - Throws: The errors of ``connect(to:directory:timeout:)``.
    static func connect(
        to host: TrustedHost,
        directory: PoolDirectory,
        timeout: Duration,
        heartbeat: Duration,
    ) async throws(PoolError) -> MessageChannel {
        let channel = try await connectForOneRequest(to: host, directory: directory, timeout: timeout)
        startHeartbeat(on: channel, every: heartbeat)
        return channel
    }

    /// Sends one request to a paired host and returns the host's first reply.
    ///
    /// The host must present the key in `host`.
    ///
    /// - Parameters:
    ///   - request: The request, which must not be a lease request.
    ///   - host: The host from this Mac's list of paired hosts.
    ///   - directory: This Mac's data directory, which holds its key.
    ///   - timeout: The longest wait for the handshake, the greeting, and then the host's reply.
    /// - Returns: The reply.
    /// - Throws: ``PoolError/invalidRequest(reason:)`` for a heartbeat, which gets no reply,
    ///   ``PoolError/daemonRefused(message:)`` when the host answers with a failure,
    ///   ``PoolError/connection(path:reason:)`` when the connection fails, the host presents
    ///   another key, or no reply arrives in time, ``PoolError/connectionClosed`` when the host
    ///   closes the connection first, or another ``PoolError`` when this Mac's key cannot be read.
    public static func send(
        _ request: PoolRequest,
        to host: TrustedHost,
        directory: PoolDirectory,
        timeout: Duration = .seconds(10),
    ) async throws(PoolError) -> PoolReply {
        guard request != .heartbeat else {
            throw .invalidRequest(reason: "the daemon does not reply to a heartbeat")
        }
        let channel = try await connectForOneRequest(to: host, directory: directory, timeout: timeout)
        defer { channel.close() }
        return try await firstReply(to: request, on: channel, place: place(of: host), timeout: timeout)
    }

    /// Connects to a paired host and waits for its greeting.
    ///
    /// The connection sends no heartbeats, because a heartbeat after a connect request would
    /// reach the guest as bytes of the stream.
    ///
    /// - Parameters:
    ///   - host: The host from this Mac's list of paired hosts.
    ///   - directory: This Mac's data directory, which holds its key.
    ///   - timeout: The longest wait for the handshake, and then for the greeting.
    /// - Returns: A connection that is ready for one request.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the list names an invalid port, the
    ///   connection fails, or the host presents another key, refuses this Mac's key, or greets
    ///   badly or not in time, or another ``PoolError`` when this Mac's key cannot be read.
    private static func connectForOneRequest(
        to host: TrustedHost,
        directory: PoolDirectory,
        timeout: Duration,
    ) async throws(PoolError) -> MessageChannel {
        guard let port = NWEndpoint.Port(rawValue: host.port) else {
            throw .connection(path: place(of: host), reason: "the list of paired hosts names port \(host.port)")
        }
        let identity = try MacIdentity.loadOrCreate(in: directory)
        return try await connect(
            to: .hostPort(host: NWEndpoint.Host(host.address), port: port),
            as: identity,
            timeout: timeout,
            protocols: [PeerSecurity.protocolName],
            closedReason: "the host closed the connection, so it does not accept this Mac's key",
            expected: host.key.rawValue,
        ) { $0 == host.key }
    }

    /// Names a paired host's address and port for error messages.
    ///
    /// - Parameter host: The host.
    /// - Returns: The address and the port, such as `192.0.2.10:7480`.
    private static func place(of host: TrustedHost) -> String {
        "\(host.address):\(host.port)"
    }

    /// Asks for a stream on an open connection and hands the connection to the stream.
    ///
    /// - Parameters:
    ///   - lease: The lease.
    ///   - channel: A connection that sent no request yet.
    ///   - place: The daemon's socket or address, for error messages.
    ///   - timeout: The longest wait for the reply.
    /// - Returns: The stream and the lease.
    /// - Throws: The errors of ``firstReply(to:on:place:timeout:)``, or
    ///   ``PoolError/malformedMessage(reason:)`` when the reply is of another kind or names
    ///   another lease.
    private static func openStream(
        to lease: LeaseID,
        on channel: MessageChannel,
        place: String,
        timeout: Duration,
    ) async throws(PoolError) -> GuestStream {
        do throws(PoolError) {
            let reply = try await firstReply(to: .connect(lease), on: channel, place: place, timeout: timeout)
            guard case let .ready(summary) = reply, summary.id == lease else {
                throw .malformedMessage(reason: "the daemon replied to a connect request with an unexpected "
                    + "\(reply.kind) reply")
            }
            return try GuestStream(lease: summary, stream: channel.takeStream())
        } catch {
            channel.close()
            throw error
        }
    }

    /// Sends one request on an open connection and waits for the daemon's first reply.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - channel: A connection that sent no request yet.
    ///   - place: The daemon's socket or address, for error messages.
    ///   - timeout: The longest wait for the reply. The call closes the connection when it
    ///     passes.
    /// - Returns: The reply, which is never a failure.
    /// - Throws: ``PoolError/daemonRefused(message:)`` when the daemon answers with a failure,
    ///   ``PoolError/connection(path:reason:)`` when no reply arrives in time,
    ///   ``PoolError/connectionClosed`` when the daemon closes the connection first, or another
    ///   ``PoolError`` when the connection fails.
    private static func firstReply(
        to request: PoolRequest,
        on channel: MessageChannel,
        place: String,
        timeout: Duration,
    ) async throws(PoolError) -> PoolReply {
        let watchdog = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            channel.close()
            return true
        }
        let received: Result<PoolReply?, PoolError>
        do throws(PoolError) {
            try channel.send(request)
            received = try await .success(channel.receive(PoolReply.self))
        } catch {
            received = .failure(error)
        }
        watchdog.cancel()
        if await watchdog.value {
            throw .connection(path: place, reason: "the daemon sent no reply within \(timeout)")
        }
        switch received {
        case let .success(.failure(message)?):
            throw .daemonRefused(message: message)
        case let .success(reply?):
            return reply
        case .success(nil):
            throw .connectionClosed
        case let .failure(error):
            throw error
        }
    }

    /// Returns the access that a reply to an access request carries.
    ///
    /// - Parameter reply: The daemon's reply.
    /// - Returns: The access.
    /// - Throws: ``PoolError/malformedMessage(reason:)`` when the reply is of another kind.
    private static func access(in reply: PoolReply) throws(PoolError) -> GuestAccess {
        guard case let .access(guest) = reply else {
            throw .malformedMessage(reason: "the daemon replied to an access request with an unexpected \(reply.kind) "
                + "reply")
        }
        return guest
    }

    /// Sends one request and returns the daemon's first reply.
    ///
    /// - Parameters:
    ///   - request: The request, which must not be a lease request.
    ///   - directory: The daemon's data directory.
    /// - Returns: The reply.
    /// - Throws: ``PoolError/invalidRequest(reason:)`` for a heartbeat, which gets no reply,
    ///   ``PoolError/daemonRefused(message:)`` when the daemon answers with a failure,
    ///   ``PoolError/connectionClosed`` when it closes the connection first, or another
    ///   ``PoolError`` when the connection fails.
    public static func send(_ request: PoolRequest, to directory: PoolDirectory) async throws(PoolError) -> PoolReply {
        guard request != .heartbeat else {
            throw .invalidRequest(reason: "the daemon does not reply to a heartbeat")
        }
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

/// A byte stream to the SSH server of a lease's guest.
public struct GuestStream: Sendable {
    /// The lease as the daemon showed it to this Mac.
    public let lease: LeaseSummary

    /// The connection, which now carries the bytes of the guest's SSH server.
    public let stream: ByteStream
}
