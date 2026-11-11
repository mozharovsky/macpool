import Foundation
import Network
import Synchronization

/// Connections from a client to the daemon.
public enum PoolClient {
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
    /// - Parameters:
    ///   - endpoint: The host's address and port.
    ///   - identity: This Mac's key and certificate.
    ///   - hostKey: The fingerprint of the key that the host must present.
    ///   - timeout: The longest wait for the handshake, and then for the greeting.
    ///   - protocols: The application protocols to offer, in order of preference.
    ///   - closedReason: The reason in the error when the host closes the connection before its
    ///     greeting.
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
    ) async throws(PoolError) -> MessageChannel {
        try await connect(
            to: endpoint,
            as: identity,
            timeout: timeout,
            protocols: protocols,
            closedReason: closedReason,
            expected: hostKey.rawValue,
        ) { $0 == hostKey }
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
