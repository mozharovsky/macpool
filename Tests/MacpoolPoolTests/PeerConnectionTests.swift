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

    /// Refuses a client that offers no protocol version that the host speaks.
    @Test func refusesAnotherProtocolVersion() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let daemon = try await fixture.start(peers: TrustList([KeyFingerprint(digest: client.keyDigest)]).settings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let hostKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: fixture.directory).keyDigest)

        // Without ALPN the handshake succeeds, so the host refuses after it.
        for protocols in [["macpool/2"], []] {
            #expect(await refusal { () async throws(PoolError) in
                try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey, protocols: protocols)
            } != nil, "\(protocols)")
        }
        #expect(fixture.logs.entries("A paired Mac connected").isEmpty)
        // A client that also offers version 1 gets it.
        let channel = try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey, protocols: [
            "macpool/2",
            PeerSecurity.protocolName,
        ])
        channel.close()
        await daemon.shutdown()
    }

    /// Refuses a trusted client that speaks only TLS 1.2.
    @Test func refusesTLS12() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let daemon = try await fixture.start(peers: TrustList([KeyFingerprint(digest: client.keyDigest)]).settings())
        let endpoint = try await loopback(listeningPort(of: daemon))

        let parameters = try PeerSecurity.parameters(identity: client, isServer: false) { _ in true }
        let options = try securityOptions(of: parameters)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        #expect(await !hostGreets(endpoint, using: parameters))
        #expect(fixture.logs.entries("A paired Mac connected").isEmpty)
        // The same client gets in with TLS 1.3.
        let standard = try PeerSecurity.parameters(identity: client, isServer: false) { _ in true }
        #expect(await hostGreets(endpoint, using: standard))
        await daemon.shutdown()
    }

    /// Names a client by the first certificate that it sends. A trusted certificate later in the
    /// chain admits nobody.
    @Test func refusesATrustedCertificateAfterTheFirst() async throws {
        let fixture = try PoolFixture()
        let trusted = try makeIdentity()
        let daemon = try await fixture.start(peers: TrustList([KeyFingerprint(digest: trusted.keyDigest)]).settings())
        let endpoint = try await loopback(listeningPort(of: daemon))

        let stranger = try makeIdentity()
        let parameters = try PeerSecurity.parameters(identity: stranger, isServer: false) { _ in true }
        try present(stranger, then: trusted.certificate, in: parameters)
        #expect(await !hostGreets(endpoint, using: parameters))
        #expect(fixture.logs.entries("A paired Mac connected").isEmpty)
        // The trusted key gets in when it comes first.
        let standard = try PeerSecurity.parameters(identity: trusted, isServer: false) { _ in true }
        #expect(await hostGreets(endpoint, using: standard))
        await daemon.shutdown()
    }

    /// Names a host by the first certificate that it sends. The pinned certificate later in the
    /// chain does not make another Mac the host.
    @Test func refusesAHostWithThePinnedCertificateAfterTheFirst() async throws {
        let client = try makeIdentity()
        let host = try makeIdentity()
        let impostor = try makeIdentity()
        let parameters = try PeerSecurity.parameters(identity: impostor, isServer: true) { _ in true }
        try present(impostor, then: host.certificate, in: parameters)
        var greeting = try JSONEncoder().encode(HostGreeting(version: PeerSecurity.protocolVersion, role: .host))
        greeting.append(UInt8(ascii: "\n"))
        let line = greeting
        let listener = try await LoopbackListener(using: parameters) { connection in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: line, completion: .idempotent)
                }
            }
            connection.start(queue: DispatchQueue(label: "macpool.test.impostor"))
        }
        defer { listener.close() }

        let endpoint = try loopback(listener.port)
        let hostKey = KeyFingerprint(digest: host.keyDigest)
        let reason = try #require(await refusal { () async throws(PoolError) in
            try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)
        })
        let impostorKey = KeyFingerprint(digest: impostor.keyDigest)
        #expect(reason == "the host presented the key \(impostorKey) instead of \(hostKey)")
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
        let holder = try await LoopbackListener()
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
        let client = try await PoolClient.connect(to: fixture.directory).takeStream()
        // Padding makes each request 2 KiB. Once the replies back up, fewer than 200 such
        // requests fill the sockets and the daemon's read buffer, so 1000 leave a wide margin.
        // Few requests keep the daemon's work small, so tests that run beside this one keep
        // their timing.
        var line = try MessageCoding.encoder.encode(PoolRequest.status)
        line.append(Data(repeating: UInt8(ascii: " "), count: 2048))
        line.append(UInt8(ascii: "\n"))
        let count = 1000
        let requests = Data(Array(repeating: line, count: count).joined())
        let sending = Task { try? await client.send(requests) }
        #expect(await !finishes(within: .milliseconds(500)) { await sending.value })
        var replies = Data()
        var lineBreaks = 0
        while lineBreaks < count, let chunk = await client.receive() {
            replies.append(chunk)
            lineBreaks += chunk.count { $0 == UInt8(ascii: "\n") }
        }
        let lines = replies.split(separator: UInt8(ascii: "\n"))
        #expect(lines.count == count)
        #expect(try lines.allSatisfy { line in
            if case .status = try MessageCoding.decoder.decode(PoolReply.self, from: Data(line)) {
                true
            } else {
                false
            }
        })
        #expect(await finishes(within: .seconds(10)) { await sending.value })
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

/// A listener on 127.0.0.1 that holds a port or stands in for a host.
private final class LoopbackListener: Sendable {
    /// The underlying listener.
    private let listener: NWListener

    /// The port that the listener holds.
    let port: UInt16

    /// Starts listening on a free port and waits until the listener is ready.
    ///
    /// - Parameters:
    ///   - parameters: The parameters of the listener. The initializer sets their local endpoint.
    ///   - accept: Handles each new connection. By default it closes the connection.
    /// - Throws: An error when the listener cannot start.
    init(
        using parameters: NWParameters = .tcp,
        accept: @escaping @Sendable (NWConnection) -> Void = { $0.cancel() },
    ) async throws {
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = accept
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

/// Returns the TLS options of parameters that ``PeerSecurity`` made, so a test can change them.
///
/// - Parameter parameters: Parameters from ``PeerSecurity/parameters(identity:protocols:isServer:admits:)``.
/// - Returns: The options.
/// - Throws: An error when the parameters carry no TLS.
private func securityOptions(of parameters: NWParameters) throws -> sec_protocol_options_t {
    let tls = try #require(parameters.defaultProtocolStack.applicationProtocols.first as? NWProtocolTLS.Options)
    return tls.securityProtocolOptions
}

/// Makes a connection send an identity's certificate followed by another certificate.
///
/// - Parameters:
///   - identity: The key that the connection proves, and the first certificate.
///   - certificate: The certificate that follows it.
///   - parameters: Parameters from ``PeerSecurity/parameters(identity:protocols:isServer:admits:)``.
/// - Throws: An error when Network rejects the chain.
private func present(_ identity: MacIdentity, then certificate: SecCertificate, in parameters: NWParameters) throws {
    let secIdentity = try identity.secIdentity()
    let chain = [identity.certificate, certificate] as CFArray
    let local = try #require(sec_identity_create_with_certificates(secIdentity, chain))
    try sec_protocol_options_set_local_identity(securityOptions(of: parameters), local)
}

/// Connects with the given parameters and reports whether the host greeted.
///
/// - Parameters:
///   - endpoint: The host.
///   - parameters: The client's parameters.
/// - Returns: Whether a greeting arrived within 10 seconds.
private func hostGreets(_ endpoint: NWEndpoint, using parameters: NWParameters) async -> Bool {
    guard let channel = try? await MessageChannel.connect(to: endpoint, using: parameters) else {
        return false
    }
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(10))
        channel.close()
    }
    defer {
        watchdog.cancel()
        channel.close()
    }
    return await (try? channel.receive(HostGreeting.self)) != nil
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
