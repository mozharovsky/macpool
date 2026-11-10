import CryptoKit
import Foundation
@testable import MacpoolPool
import Network
import Synchronization
import Testing

/// Tests of connections between Macs over TLS on the loopback interface.
@Suite(.timeLimit(.minutes(1)))
struct PeerConnectionTests {
    /// Serves a trusted Mac as the owner of its key after a greeting.
    @Test func servesATrustedMac() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        let trust = TrustList([clientKey])
        let daemon = try await fixture.start(peers: trust.settings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let hostKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: fixture.directory).keyDigest)

        let channel = try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)
        try channel.send(PoolRequest.status)
        guard case let .status(summary) = try await next(channel) else {
            Issue.record("the host did not answer with its status")
            return
        }
        #expect(summary.leases.isEmpty)
        // Only a paired Mac must name an offered source. The refusal shows that the daemon serves
        // the connection for the client's key.
        try channel.send(PoolRequest.lease(fixture.terms()))
        let refusal = PoolError.invalidRequest(reason: "the host offers no source named \(fixture.source)")
        #expect(try await next(channel) == .failure(refusal.description))
        let connected = fixture.logs.entries("A paired Mac connected")
        #expect(connected.map { $0.metadata["key"] } == [clientKey.rawValue])
        channel.close()
        await daemon.shutdown()
    }

    /// Refuses a Mac whose key the host does not trust.
    @Test func refusesAnUntrustedMac() async throws {
        let fixture = try PoolFixture()
        let trust = try TrustList([KeyFingerprint(digest: makeIdentity().keyDigest)])
        let daemon = try await fixture.start(peers: trust.settings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let hostKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: fixture.directory).keyDigest)

        let stranger = try makeIdentity()
        let reason = try #require(await refusal { () async throws(PoolError) in
            try await PoolClient.connect(to: endpoint, as: stranger, hostKey: hostKey)
        })
        #expect(reason.contains("does not accept this Mac's key"), "\(reason)")
        #expect(fixture.logs.entries("A paired Mac connected").isEmpty)
        await daemon.shutdown()
    }

    /// Admits nobody while the set of trusted keys is empty.
    @Test func admitsNobodyWithoutTrustedKeys() async throws {
        let fixture = try PoolFixture()
        let daemon = try await fixture.start(peers: TrustList().settings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let hostKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: fixture.directory).keyDigest)

        for _ in 0 ..< 2 {
            let client = try makeIdentity()
            #expect(await refusal { () async throws(PoolError) in
                try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)
            } != nil)
        }
        #expect(fixture.logs.entries("A paired Mac connected").isEmpty)
        await daemon.shutdown()
    }

    /// Refuses a host that presents another key than the pinned one.
    @Test func refusesAnotherHostKey() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let daemon = try await fixture.start(peers: TrustList([KeyFingerprint(digest: client.keyDigest)]).settings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let hostKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: fixture.directory).keyDigest)
        let pinned = try KeyFingerprint(digest: makeIdentity().keyDigest)

        let reason = try #require(await refusal { () async throws(PoolError) in
            try await PoolClient.connect(to: endpoint, as: client, hostKey: pinned)
        })
        #expect(reason == "the host presented the key \(hostKey) instead of \(pinned)")
        #expect(fixture.logs.entries("A paired Mac connected").isEmpty)
        await daemon.shutdown()
    }

    /// Refuses a client that offers only a protocol version that the host does not speak.
    @Test func refusesAnotherProtocolVersion() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let daemon = try await fixture.start(peers: TrustList([KeyFingerprint(digest: client.keyDigest)]).settings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let hostKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: fixture.directory).keyDigest)

        #expect(await refusal { () async throws(PoolError) in
            try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey, protocols: ["macpool/2"])
        } != nil)
        #expect(fixture.logs.entries("A paired Mac connected").isEmpty)
        // A client that also offers version 1 gets it.
        let channel = try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey, protocols: [
            "macpool/2",
            PeerSecurity.protocolName,
        ])
        channel.close()
        await daemon.shutdown()
    }

    /// Checks the trusted keys during every handshake, so a change applies to the next connection.
    @Test func readsTrustedKeysAtEveryHandshake() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        let trust = TrustList([clientKey])
        let daemon = try await fixture.start(peers: trust.settings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let hostKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: fixture.directory).keyDigest)

        try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey).close()
        trust.replace(with: [])
        #expect(await refusal { () async throws(PoolError) in
            try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)
        } != nil)
        trust.replace(with: [clientKey])
        try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey).close()
        #expect(fixture.logs.entries("A paired Mac connected").count == 2)
        await daemon.shutdown()
    }

    /// Keeps serving the local socket while this Mac's key cannot be read, and listens once it
    /// can.
    @Test func keepsTheLocalSocketWithAnUnusableKey() async throws {
        let fixture = try PoolFixture()
        let daemon = try fixture.daemon(peers: TrustList().settings())
        try fixture.directory.prepareTrustDirectory()
        let keyFile = fixture.directory.identityFile.path(percentEncoded: false)
        #expect(FileManager.default.createFile(
            atPath: keyFile,
            contents: Data("not a key\n".utf8),
            attributes: [.posixPermissions: 0o600],
        ))
        try await daemon.start()

        guard case .status = try await PoolClient.send(.status, to: fixture.directory) else {
            Issue.record("the local socket did not answer")
            return
        }
        #expect(await eventually { !fixture.logs.entries("The listener for paired Macs cannot start").isEmpty })
        // Several attempts fail the same way and log once.
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.logs.entries("The listener for paired Macs cannot start").count == 1)
        #expect(await daemon.peerPort == nil)

        try FileManager.default.removeItem(atPath: keyFile)
        _ = try await listeningPort(of: daemon)
        #expect(fixture.logs.entries("Listening for paired Macs").count == 1)
        guard case .status = try await PoolClient.send(.status, to: fixture.directory) else {
            Issue.record("the local socket did not answer")
            return
        }
        await daemon.shutdown()
    }

    /// Keeps serving the local socket while another process holds the port, and listens once
    /// the port is free.
    @Test func keepsTheLocalSocketWithABusyPort() async throws {
        let fixture = try PoolFixture()
        let holder = try await PortHolder()
        let daemon = try await fixture.start(peers: TrustList().settings(port: holder.port))

        guard case .status = try await PoolClient.send(.status, to: fixture.directory) else {
            Issue.record("the local socket did not answer")
            return
        }
        #expect(await eventually { !fixture.logs.entries("The listener for paired Macs cannot start").isEmpty })
        #expect(await daemon.peerPort == nil)

        holder.close()
        #expect(try await listeningPort(of: daemon) == holder.port)
        guard case .status = try await PoolClient.send(.status, to: fixture.directory) else {
            Issue.record("the local socket did not answer")
            return
        }
        await daemon.shutdown()
    }

    /// Delivers the bytes and the end of the stream over TLS by closing the connection.
    @Test func finishesSendingOverTLS() async throws {
        let host = try makeIdentity()
        let client = try makeIdentity()
        let hostKey = KeyFingerprint(digest: host.keyDigest)
        let listener = try await PeerListener(
            identity: host,
            settings: TrustList([KeyFingerprint(digest: client.keyDigest)]).settings(),
        )
        defer { listener.close() }
        let parameters = try PeerSecurity.parameters(identity: client, isServer: false) { $0 == hostKey }
        let channel = try await MessageChannel.connect(to: loopback(listener.port), using: parameters)
        var connections = listener.connections.makeAsyncIterator()
        let peer = try #require(await connections.next())
        #expect(peer.fingerprint == KeyFingerprint(digest: client.keyDigest))

        let clientStream = try channel.takeStream()
        let serverStream = try peer.channel.takeStream()
        let payload = Data((0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0) })
        try await serverStream.send(payload)
        await serverStream.finishSending()
        // If the end does not arrive, the watchdog ends the read after 10 seconds.
        let start = ContinuousClock.now
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            clientStream.close()
        }
        #expect(await clientStream.read(count: payload.count + 1) == payload)
        watchdog.cancel()
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(await serverStream.receive() == nil)
        clientStream.close()
        serverStream.close()
    }

    /// Reads a client's next request only after the replies to the previous one left, so a
    /// client that stops reading stops its own requests too.
    @Test func waitsForRepliesBeforeTheNextRequest() async throws {
        let fixture = try PoolFixture()
        let daemon = try await fixture.start()
        let client = try await PoolClient.connect(to: fixture.directory)
        // The replies fill the socket's buffers many times over and stay far below the limit
        // on queued bytes.
        let count = 20000
        for _ in 0 ..< count {
            try client.send(PoolRequest.status)
        }
        #expect(await !finishes(within: .milliseconds(500)) { await client.delivered() })
        for index in 0 ..< count {
            guard case .status = try await next(client) else {
                Issue.record("reply \(index) of \(count) is missing")
                break
            }
        }
        #expect(await finishes(within: .seconds(10)) { await client.delivered() })
        client.close()
        await daemon.shutdown()
    }
}

/// Keys that a test trusts.
///
/// The test may change them while a listener runs.
private final class TrustList: Sendable {
    /// The trusted keys.
    private let keys: Mutex<Set<KeyFingerprint>>

    /// Creates a list.
    ///
    /// - Parameter keys: The keys that are trusted at first.
    init(_ keys: Set<KeyFingerprint> = []) {
        self.keys = Mutex(keys)
    }

    /// Replaces the trusted keys.
    ///
    /// - Parameter keys: The keys that are trusted from now on.
    func replace(with keys: Set<KeyFingerprint>) {
        self.keys.withLock { $0 = keys }
    }

    /// Creates settings that listen on 127.0.0.1 with this list and retry quickly.
    ///
    /// - Parameter port: The port, or 0 for a free one.
    /// - Returns: The settings.
    func settings(port: UInt16 = 0) -> PeerSettings {
        PeerSettings(
            address: "127.0.0.1",
            port: port,
            trustedKeys: { self.keys.withLock { $0 } },
            retryInterval: .milliseconds(100),
        )
    }
}

/// A plain TCP listener on 127.0.0.1 that holds a port.
private final class PortHolder: Sendable {
    /// The underlying listener.
    private let listener: NWListener

    /// The port that the listener holds.
    let port: UInt16

    /// Starts listening on a free port and waits until the listener is ready.
    ///
    /// - Throws: An error when the listener cannot start.
    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { $0.cancel() }
        let failure: String? = await withCheckedContinuation { ready in
            let once = ResumeOnce(ready)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: nil)
                case let .failed(error), let .waiting(error):
                    once.resume(returning: "\(error)")
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "macpool.test.holder"))
        }
        if let failure {
            listener.cancel()
            throw PoolError.connection(path: "127.0.0.1", reason: failure)
        }
        self.listener = listener
        port = try #require(listener.port?.rawValue)
    }

    /// Frees the port.
    func close() {
        listener.cancel()
    }
}

/// Creates a key for a Mac that exists only in the test.
///
/// - Returns: The identity. Its key file does not exist.
/// - Throws: ``PoolError`` when the certificate cannot be built.
private func makeIdentity() throws(PoolError) -> MacIdentity {
    try MacIdentity(privateKey: P256.Signing.PrivateKey(), file: URL(filePath: "/nonexistent/identity.pem"))
}

/// Names a port of 127.0.0.1.
///
/// - Parameter port: A port number other than 0.
/// - Returns: The endpoint.
/// - Throws: An error when the port is 0.
private func loopback(_ port: UInt16) throws -> NWEndpoint {
    try .hostPort(host: .ipv4(.loopback), port: #require(NWEndpoint.Port(rawValue: port)))
}

/// Waits until a daemon listens for paired Macs.
///
/// - Parameters:
///   - daemon: The daemon to poll.
///   - timeout: The longest wait.
/// - Returns: The port.
/// - Throws: An error when the daemon does not listen in time.
private func listeningPort(of daemon: PoolDaemon, within timeout: Duration = .seconds(10)) async throws -> UInt16 {
    let deadline = ContinuousClock.now + timeout
    var port = await daemon.peerPort
    while port == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
        port = await daemon.peerPort
    }
    return try #require(port)
}

/// Connects and returns why the connection failed.
///
/// - Parameter connect: Opens the connection.
/// - Returns: The reason of the failure, or `nil` when the connection opened.
private func refusal(_ connect: () async throws(PoolError) -> MessageChannel) async -> String? {
    do {
        try await connect().close()
        return nil
    } catch let .connection(_, reason) {
        return reason
    } catch {
        return error.description
    }
}
