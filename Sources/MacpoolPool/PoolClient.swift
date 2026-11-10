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
    /// - Returns: A connection that is ready for requests.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the connection fails, the host
    ///   presents another key, refuses this Mac's key, closes the connection or stays silent
    ///   before its greeting, or greets with another protocol version or role, or
    ///   ``PoolError/unusableIdentity(path:reason:)`` when Security rejects this Mac's key.
    static func connect(
        to endpoint: NWEndpoint,
        as identity: MacIdentity,
        hostKey: KeyFingerprint,
        timeout: Duration = .seconds(10),
        protocols: [String] = [PeerSecurity.protocolName],
    ) async throws(PoolError) -> MessageChannel {
        let place = "\(endpoint)"
        let presented = Mutex<KeyFingerprint?>(nil)
        let parameters = try PeerSecurity.parameters(identity: identity, protocols: protocols, isServer: false) { key in
            presented.withLock { $0 = key }
            return key == hostKey
        }
        let channel: MessageChannel
        do {
            channel = try await MessageChannel.connect(to: endpoint, using: parameters, timeout: timeout)
        } catch {
            if let key = presented.withLock({ $0 }), key != hostKey {
                throw .connection(path: place, reason: "the host presented the key \(key) instead of \(hostKey)")
            }
            throw error
        }
        let greeting = try await greeting(on: channel, from: place, within: timeout)
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
    /// - Returns: The greeting.
    /// - Throws: ``PoolError/connection(path:reason:)`` when the host closes the connection,
    ///   sends something else, or stays silent for `timeout`.
    private static func greeting(
        on channel: MessageChannel,
        from place: String,
        within timeout: Duration,
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
        let received: Result<HostGreeting?, PoolError>
        do {
            received = try await .success(channel.receive(HostGreeting.self))
        } catch {
            received = .failure(error)
        }
        watchdog.cancel()
        if await watchdog.value {
            throw .connection(path: place, reason: "the host sent no greeting within \(timeout)")
        }
        switch received {
        case let .success(greeting?):
            return greeting
        case .success(nil):
            channel.close()
            throw .connection(
                path: place,
                reason: "the host closed the connection, so it does not accept this Mac's key",
            )
        case let .failure(error):
            channel.close()
            throw .connection(path: place, reason: "the host sent no greeting: \(error)")
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
