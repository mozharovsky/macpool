import CryptoKit
import Foundation
import Logging
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
        let hostKey = try listClients([clientKey], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
        let endpoint = try await loopback(listeningPort(of: daemon))

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
        let refusal = PoolError.invalidRequest(reason: "the host does not offer the requested source")
        #expect(try await next(channel) == .failure(refusal.description))
        let connected = fixture.logs.entries("A paired Mac connected")
        #expect(connected.map { $0.metadata["key"] } == [clientKey.rawValue])
        channel.close()
        await daemon.shutdown()
    }

    /// Refuses a Mac whose key the host does not trust.
    @Test func refusesAnUntrustedMac() async throws {
        let fixture = try PoolFixture()
        let hostKey = try listClients([randomKey()], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
        let endpoint = try await loopback(listeningPort(of: daemon))

        let stranger = try makeIdentity()
        let reason = try #require(await refusal { () async throws(PoolError) in
            try await PoolClient.connect(to: endpoint, as: stranger, hostKey: hostKey)
        })
        #expect(reason.contains("does not accept this Mac's key"), "\(reason)")
        #expect(fixture.logs.entries("A paired Mac connected").isEmpty)
        await daemon.shutdown()
    }

    /// Admits nobody while no list of paired clients exists.
    @Test func admitsNobodyWithoutTrustedKeys() async throws {
        let fixture = try PoolFixture()
        let daemon = try await fixture.start(peers: loopbackSettings())
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
        let hostKey = try listClients([KeyFingerprint(digest: client.keyDigest)], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
        let endpoint = try await loopback(listeningPort(of: daemon))
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
        let hostKey = try listClients([KeyFingerprint(digest: client.keyDigest)], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
        let endpoint = try await loopback(listeningPort(of: daemon))

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
        try listClients([KeyFingerprint(digest: client.keyDigest)], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
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
        try listClients([KeyFingerprint(digest: trusted.keyDigest)], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
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

    /// Reads the list of paired clients during every handshake, so a change applies to the next
    /// connection. A blocked client is refused like one that the list leaves out.
    @Test func readsTrustedKeysAtEveryHandshake() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        let hostKey = try listClients([clientKey], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
        let endpoint = try await loopback(listeningPort(of: daemon))

        try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey).close()
        for blocked in [true, false] {
            try listClients(blocked ? [clientKey] : [], in: fixture.directory, blocked: [clientKey])
            #expect(await refusal { () async throws(PoolError) in
                try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)
            } != nil, "blocked: \(blocked)")
        }
        try listClients([clientKey], in: fixture.directory)
        try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey).close()
        #expect(fixture.logs.entries("A paired Mac connected").count == 2)
        await daemon.shutdown()
    }

    /// Keeps serving the local socket while this Mac's key cannot be used. A missing key stays
    /// missing while a list of paired clients exists, and the listener starts once the key is
    /// back.
    @Test func keepsTheLocalSocketWithAnUnusableKey() async throws {
        let fixture = try PoolFixture()
        let daemon = try fixture.daemon(peers: loopbackSettings())
        try listClients([randomKey()], in: fixture.directory)
        let keyFile = fixture.directory.identityFile.path(percentEncoded: false)
        let key = try Data(contentsOf: URL(filePath: keyFile))
        try FileManager.default.removeItem(atPath: keyFile)
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
        let failures = { fixture.logs.entries("The listener for paired Macs cannot start") }
        #expect(await eventually { !failures().isEmpty })
        // Several attempts fail the same way and log once.
        try await Task.sleep(for: .milliseconds(400))
        #expect(failures().count == 1)
        #expect(await daemon.peerPort == nil)

        try FileManager.default.removeItem(atPath: keyFile)
        let missing = PoolError.missingIdentity(
            path: keyFile,
            lists: [TrustList<TrustedClient>.file(in: fixture.directory).path(percentEncoded: false)],
        )
        #expect(await eventually { failures().count == 2 })
        #expect(failures().last?.metadata["reason"] == missing.description)
        try await Task.sleep(for: .milliseconds(400))
        #expect(failures().count == 2)
        #expect(!FileManager.default.fileExists(atPath: keyFile))
        #expect(await daemon.peerPort == nil)
        guard case .status = try await PoolClient.send(.status, to: fixture.directory) else {
            Issue.record("the local socket did not answer")
            return
        }

        #expect(FileManager.default.createFile(atPath: keyFile, contents: key, attributes: [.posixPermissions: 0o600]))
        _ = try await listeningPort(of: daemon)
        #expect(fixture.logs.entries("Listening for paired Macs").count == 1)
        #expect(try Data(contentsOf: URL(filePath: keyFile)) == key)
        await daemon.shutdown()
    }

    /// Starts no listener while the list of paired clients cannot be read, and admits nobody
    /// while the list cannot be read later.
    @Test func admitsNobodyWithAnUnreadableList() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let hostKey = try listClients([KeyFingerprint(digest: client.keyDigest)], in: fixture.directory)
        let list = TrustList<TrustedClient>.file(in: fixture.directory).path(percentEncoded: false)
        let unusable = PoolError.unusableTrustList(path: list, reason: "its permissions 644 let other users in")
        #expect(chmod(list, 0o644) == 0)
        let daemon = try await fixture.start(peers: loopbackSettings())

        #expect(await eventually {
            fixture.logs.entries("The listener for paired Macs cannot start").last?.metadata["reason"]
                == unusable.description
        })
        #expect(await daemon.peerPort == nil)
        #expect(chmod(list, 0o600) == 0)
        let endpoint = try await loopback(listeningPort(of: daemon))
        try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey).close()

        #expect(chmod(list, 0o644) == 0)
        for _ in 0 ..< 2 {
            #expect(await refusal { () async throws(PoolError) in
                try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)
            } != nil)
        }
        let unreadable = fixture.logs.entries("The list of paired clients cannot be read, so no paired Mac can connect")
        #expect(unreadable.map { $0.metadata["reason"] } == [unusable.description])
        #expect(chmod(list, 0o600) == 0)
        try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey).close()
        await daemon.shutdown()
    }

    /// Refuses a connection beyond the most that one paired Mac may hold, before the greeting.
    /// Another Mac still connects, and the first Mac connects again once one of its connections
    /// closes. The warning about the limit reaches the warning level once a minute.
    @Test func limitsConnectionsPerMac() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let other = try makeIdentity()
        let hostKey = try listClients(
            [client, other].map { KeyFingerprint(digest: $0.keyDigest) },
            in: fixture.directory,
        )
        let daemon = try await fixture.start(peers: loopbackSettings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let connect = { (mac: MacIdentity) async -> String? in
            await refusal { () async throws(PoolError) in
                try await PoolClient.connect(to: endpoint, as: mac, hostKey: hostKey)
            }
        }

        var channels: [MessageChannel] = []
        for _ in 0 ..< PoolDaemon.connectionsPerPeer {
            try await channels.append(PoolClient.connect(to: endpoint, as: client, hostKey: hostKey))
        }
        #expect(await connect(client) == "the host refused the connection: this Mac already has 4 connections "
            + "to the host, the most it may have")
        #expect(await connect(client) != nil)
        let warnings = {
            fixture.logs.entries("A paired Mac has too many connections").count { $0.level == .warning }
        }
        #expect(warnings() == 1)
        #expect(await connect(other) == nil)

        // Freeing a place and filling it again does not bring the warning back within a minute.
        for _ in 0 ..< 3 {
            channels.removeFirst().close()
            #expect(await eventually {
                guard let channel = try? await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey) else {
                    return false
                }
                channels.append(channel)
                return true
            })
            #expect(await connect(client) != nil)
        }
        #expect(warnings() == 1)
        fixture.clock.advance(by: PeerLogRate.interval)
        #expect(await connect(client) != nil)
        #expect(warnings() == 2)
        for channel in channels {
            channel.close()
        }
        await daemon.shutdown()
    }

    /// Keeps serving the local socket while another process holds the port, and listens once
    /// the port is free.
    @Test func keepsTheLocalSocketWithABusyPort() async throws {
        let fixture = try PoolFixture()
        let holder = try await LoopbackListener()
        let daemon = try await fixture.start(peers: loopbackSettings(port: holder.port))

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

    /// Binds only to the loopback address in the settings. If `listeningHost(for:)` rejects the
    /// address, the listener throws before it binds.
    @Test func bindsToOneAddress() async throws {
        let host = try makeIdentity()
        for address in ["127.0.0.1", "::1"] {
            let listener = try await PeerListener(
                identity: host,
                settings: PeerSettings(address: address, port: 0),
                admits: { _ in false },
            )
            #expect(boundAddresses(port: listener.port) == [address])
            listener.close()
        }
        // If the listener skipped the parser, `127.1` would still bind only to the loopback address.
        await #expect(throws: PoolError.connection(
            path: "127.1:0",
            reason: "the listener needs a numeric IP address, such as 192.0.2.20, that is not 0.0.0.0 or :: "
                + "and has no zone",
        )) {
            _ = try await PeerListener(
                identity: host,
                settings: PeerSettings(address: "127.1", port: 0),
                admits: { _ in false },
            )
        }
    }

    /// Accepts numeric addresses and normalizes IPv6 addresses. Rejects host names, unspecified
    /// addresses, IPv6 zones, and IPv4 addresses that differ from their canonical dotted form.
    @Test func readsListenerAddresses() {
        let accepted = [
            "127.0.0.1": "127.0.0.1",
            "::1": "::1",
            "192.0.2.20": "192.0.2.20",
            "2001:db8::20": "2001:db8::20",
            "2001:DB8:0:0:0:0:0:20": "2001:db8::20",
        ]
        for (address, host) in accepted {
            #expect(PeerListener.listeningHost(for: address).map { "\($0)" } == host, "\(address)")
        }
        for address in [
            "",
            " 127.0.0.1",
            "localhost",
            "example.local",
            "0.0.0.0",
            "::",
            "0:0:0:0:0:0:0:0",
            "::ffff:0.0.0.0",
            "127.1",
            "1",
            "127.000.000.001",
            "fe80::1%lo0",
        ] {
            #expect(PeerListener.listeningHost(for: address) == nil, "\(address)")
        }
    }

    /// Closes a new connection while the most handshakes run. A handshake that fails or runs out
    /// of time frees its place.
    @Test func limitsHandshakesThatRunAtOnce() async throws {
        let host = try makeIdentity()
        let client = try makeIdentity()
        let hostKey = KeyFingerprint(digest: host.keyDigest)
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        let listener = try await PeerListener(
            identity: host,
            settings: loopbackSettings(),
            admits: { $0 == clientKey },
            handshakeTimeout: .seconds(3),
            handshakeLimit: 2,
        )
        defer { listener.close() }
        let endpoint = try loopback(listener.port)
        let parameters = try PeerSecurity.parameters(identity: client, isServer: false) { $0 == hostKey }

        // The host closes a stranger's connection only after the failed handshake left its place.
        for _ in 0 ..< 3 {
            let stranger = try makeIdentity()
            let strangerParameters = try PeerSecurity.parameters(identity: stranger, isServer: false) { _ in true }
            let channel = try await MessageChannel.connect(to: endpoint, using: strangerParameters)
            #expect(await (try? channel.receive(HostGreeting.self)) == nil)
            channel.close()
        }
        // The client may see the end of its connection just before the host's handler for the
        // failed handshake runs.
        try await Task.sleep(for: .milliseconds(200))
        let silent = try await [
            MessageChannel.connect(to: endpoint, using: .tcp),
            MessageChannel.connect(to: endpoint, using: .tcp),
        ]
        await #expect(throws: PoolError.self) {
            try await MessageChannel.connect(to: endpoint, using: parameters)
        }
        for channel in silent {
            #expect(await finishes(within: .seconds(10)) { _ = try? await channel.receive(HostGreeting.self) })
            channel.close()
        }
        let channel = try await MessageChannel.connect(to: endpoint, using: parameters)
        var connections = listener.connections.makeAsyncIterator()
        let peer = try #require(await connections.next())
        #expect(peer.fingerprint == clientKey)
        peer.channel.close()
        channel.close()
    }

    /// Writes one info line per minute about the connections of one paired Mac, and debug lines
    /// in between.
    @Test func limitsConnectionLines() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let hostKey = try listClients([KeyFingerprint(digest: client.keyDigest)], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let levels = { fixture.logs.entries("A paired Mac connected").map(\.level) }
        for _ in 0 ..< 2 {
            try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey).close()
        }
        #expect(await eventually { levels() == [.info, .debug] })
        fixture.clock.advance(by: PeerLogRate.interval)
        try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey).close()
        #expect(await eventually { levels() == [.info, .debug, .info] })
        await daemon.shutdown()
    }

    /// Writes a line at its full level once a minute and at the debug level in between. Each kind
    /// of line and each key has its own time, and the rate forgets times older than a minute.
    @Test func ratesPeerLogLines() throws {
        let key = try #require(KeyFingerprint(String(repeating: "0123456789abcdef", count: 4)))
        let other = try #require(KeyFingerprint(String(repeating: "fedcba9876543210", count: 4)))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = PeerLogRate.interval
        var rate = PeerLogRate()
        #expect(rate.level(of: .connected(key), full: .info, at: start) == .info)
        #expect(rate.level(of: .connected(key), full: .info, at: start + interval - 1) == .debug)
        #expect(rate.level(of: .connected(other), full: .info, at: start + interval - 1) == .info)
        #expect(rate.level(of: .tooManyConnections(key), full: .warning, at: start + interval - 1) == .warning)
        #expect(rate.level(of: .connected(key), full: .info, at: start + interval) == .info)
        #expect(rate.times.count == 3)
        #expect(rate.level(of: .tooManyPairings, full: .warning, at: start + 3 * interval) == .warning)
        #expect(rate.times.keys.elementsEqual([.tooManyPairings]))
    }

    /// Writes a line at its full level again after the clock went back.
    @Test func ratesPeerLogLinesAfterTheClockWentBack() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var rate = PeerLogRate()
        #expect(rate.level(of: .tooManyPairings, full: .warning, at: start) == .warning)
        #expect(rate.level(of: .tooManyPairings, full: .warning, at: start - 3600) == .warning)
        #expect(rate.level(of: .tooManyPairings, full: .warning, at: start - 3599) == .debug)
    }

    /// Cancels the timer of a handshake when the outcome settles, in either order, and frees the
    /// handshake's place once.
    @Test func settlesAHandshakeOnce() {
        let count = HandshakeCount(limit: 1)
        #expect(count.begin())
        let armedFirst = HandshakeOutcome(count)
        let timer = Task { _ = try? await Task.sleep(for: .seconds(60)) }
        armedFirst.arm(timer)
        #expect(!timer.isCancelled)
        #expect(armedFirst.settle())
        #expect(timer.isCancelled)
        #expect(!armedFirst.settle())

        #expect(count.begin())
        let settledFirst = HandshakeOutcome(count)
        #expect(settledFirst.settle())
        let late = Task { _ = try? await Task.sleep(for: .seconds(60)) }
        settledFirst.arm(late)
        #expect(late.isCancelled)
        #expect(count.begin())
        #expect(!count.begin())
    }

    /// Frees a handshake's place when the handshake succeeds, while its connection stays open.
    @Test func freesAPlaceWhenAHandshakeSucceeds() async throws {
        let host = try makeIdentity()
        let client = try makeIdentity()
        let hostKey = KeyFingerprint(digest: host.keyDigest)
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        let listener = try await PeerListener(
            identity: host,
            settings: loopbackSettings(),
            admits: { $0 == clientKey },
            handshakeLimit: 2,
        )
        defer { listener.close() }
        let endpoint = try loopback(listener.port)
        let parameters = try PeerSecurity.parameters(identity: client, isServer: false) { $0 == hostKey }
        var connections = listener.connections.makeAsyncIterator()
        var channels: [MessageChannel] = []
        for _ in 0 ..< 3 {
            try await channels.append(MessageChannel.connect(to: endpoint, using: parameters))
            let peer = try #require(await connections.next())
            channels.append(peer.channel)
        }
        for channel in channels {
            channel.close()
        }
    }

    /// Refuses the new connections of a blocked key and closes its open connection at the next
    /// request.
    @Test func closesABlockedKeyAtItsNextRequest() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        let hostKey = try listClients([clientKey], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let open = try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)

        try listClients([clientKey], in: fixture.directory, blocked: [clientKey])
        #expect(await refusal { () async throws(PoolError) in
            try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)
        } != nil)
        try open.send(PoolRequest.status)
        #expect(try await next(open) == RevocationTests.notAccepted)
        #expect(try await isClosed(open))
        await daemon.shutdown()
    }

    /// Closes the connection of a revoked Mac at once and refuses its new connections.
    @Test func revokesAConnectedMac() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        let hostKey = try listClients([clientKey], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let open = try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)

        let revoked = try await PoolClient.send(.revoke(key: clientKey.shortKey), to: fixture.directory)
        #expect(revoked == .revoked(PairedMac(name: "client", key: clientKey), connections: 1, leases: 0))
        #expect(try await next(open) == RevocationTests.notAccepted)
        #expect(try await isClosed(open))
        #expect(await refusal { () async throws(PoolError) in
            try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)
        } != nil)
        await daemon.shutdown()
    }

    /// Refuses new connections of a revoked Mac while the daemon keeps a block that it could not
    /// save.
    @Test func refusesAMacWithAnUnsavedBlock() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        let hostKey = try listClients([clientKey], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let open = try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)
        try RevocationTests.setImmutable(true, listIn: fixture.directory)
        defer { try? RevocationTests.setImmutable(false, listIn: fixture.directory) }

        await #expect(throws: PoolError.self) {
            try await PoolClient.send(.revoke(key: clientKey.shortKey), to: fixture.directory)
        }
        #expect(try await next(open) == RevocationTests.notAccepted)
        #expect(try await isClosed(open))
        try RevocationTests.setImmutable(false, listIn: fixture.directory)
        #expect(await refusal { () async throws(PoolError) in
            try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)
        } != nil)
        #expect(try TrustList<TrustedClient>.load(from: fixture.directory)[clientKey]?.isBlocked == false)
        await daemon.shutdown()
    }

    /// Admits nobody while the list of paired clients or its directory has an access control
    /// list, and leaves the list in place.
    @Test func admitsNobodyWhileTheListHasAnAccessControlList() async throws {
        let fixture = try PoolFixture()
        let client = try makeIdentity()
        let hostKey = try listClients([KeyFingerprint(digest: client.keyDigest)], in: fixture.directory)
        let daemon = try await fixture.start(peers: loopbackSettings())
        let endpoint = try await loopback(listeningPort(of: daemon))
        let connect = {
            await refusal { () async throws(PoolError) in
                try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey)
            }
        }
        let file = TrustList<TrustedClient>.file(in: fixture.directory)
        let trust = fixture.directory.trustDirectory

        #expect(await connect() == nil)
        for place in [file, trust] {
            try await MacIdentityTests.changeMode("+a", "everyone allow read", place.pathWithoutTrailingSlash)
            #expect(await connect() != nil, "\(place)")
            #expect(try accessControlList(at: place) == .accessControlList, "\(place)")
            try await MacIdentityTests.changeMode("-N", place.pathWithoutTrailingSlash)
            #expect(await connect() == nil, "\(place)")
        }
        await daemon.shutdown()
    }

    /// Delivers the bytes and the end of the stream over TLS by closing the connection.
    @Test func finishesSendingOverTLS() async throws {
        let host = try makeIdentity()
        let client = try makeIdentity()
        let hostKey = KeyFingerprint(digest: host.keyDigest)
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        let listener = try await PeerListener(
            identity: host,
            settings: loopbackSettings(),
            admits: { $0 == clientKey },
        )
        defer { listener.close() }
        let parameters = try PeerSecurity.parameters(identity: client, isServer: false) { $0 == hostKey }
        let channel = try await MessageChannel.connect(to: loopback(listener.port), using: parameters)
        var connections = listener.connections.makeAsyncIterator()
        let peer = try #require(await connections.next())
        #expect(peer.fingerprint == clientKey)

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

/// Lists the local addresses of this process's unconnected TCP sockets on a port.
///
/// The test reads the sockets themselves, because the settings say only what the listener asked
/// for. Darwin has no `SO_ACCEPTCONN`. A socket without a peer therefore stands for a listening
/// one.
///
/// - Parameter port: The TCP port.
/// - Returns: The numeric addresses, in the order of the file descriptors.
func boundAddresses(port: UInt16) -> [String] {
    var addresses: [String] = []
    for descriptor in 0 ..< getdtablesize() {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK else {
            continue
        }
        var type: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &size) == 0, type == SOCK_STREAM else {
            continue
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let converted = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                guard getpeername(descriptor, address, &peerLength) != 0,
                      getsockname(descriptor, address, &length) == 0
                else {
                    return false
                }
                let flags = NI_NUMERICHOST | NI_NUMERICSERV
                return getnameinfo(
                    address,
                    length,
                    &host,
                    socklen_t(host.count),
                    &service,
                    socklen_t(service.count),
                    flags,
                ) == 0
            }
        }
        guard converted, text(of: service) == "\(port)" else {
            continue
        }
        addresses.append(text(of: host))
    }
    return addresses
}

/// Converts a NUL-terminated C string in a buffer to a string.
///
/// - Parameter buffer: The buffer.
/// - Returns: The text before the first NUL.
private func text(of buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Creates settings that listen on 127.0.0.1 and retry quickly.
///
/// - Parameter port: The port, or 0 for a free one.
/// - Returns: The settings.
func loopbackSettings(port: UInt16 = 0) -> PeerSettings {
    PeerSettings(address: "127.0.0.1", port: port, retryInterval: .milliseconds(100))
}

/// Creates the host's key unless it exists, and replaces the host's list of paired clients.
///
/// The key comes first, because the pool creates no key while a list of paired Macs exists.
///
/// - Parameters:
///   - keys: The fingerprints of the clients' keys.
///   - directory: The host's data directory.
///   - blocked: The keys that the host refuses.
/// - Returns: The fingerprint of the host's key.
/// - Throws: ``PoolError`` when the key or the list cannot be written.
@discardableResult
func listClients(
    _ keys: [KeyFingerprint],
    in directory: PoolDirectory,
    blocked: Set<KeyFingerprint> = [],
) throws(PoolError) -> KeyFingerprint {
    let host = try MacIdentity.loadOrCreate(in: directory)
    var clients = TrustList<TrustedClient>()
    for key in keys {
        clients.insert(TrustedClient(
            key: key,
            name: "client",
            pairedAt: Date(),
            isBlocked: blocked.contains(key),
        ))
    }
    try clients.save(to: directory)
    return KeyFingerprint(digest: host.keyDigest)
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
func makeIdentity() throws(PoolError) -> MacIdentity {
    try MacIdentity(privateKey: P256.Signing.PrivateKey(), file: URL(filePath: "/nonexistent/identity.pem"))
}

/// Names a port of 127.0.0.1.
///
/// - Parameter port: A port number other than 0.
/// - Returns: The endpoint.
/// - Throws: An error when the port is 0.
func loopback(_ port: UInt16) throws -> NWEndpoint {
    try .hostPort(host: .ipv4(.loopback), port: #require(NWEndpoint.Port(rawValue: port)))
}

/// Waits until a daemon listens for paired Macs.
///
/// - Parameters:
///   - daemon: The daemon to poll.
///   - timeout: The longest wait.
/// - Returns: The port.
/// - Throws: An error when the daemon does not listen in time.
func listeningPort(of daemon: PoolDaemon, within timeout: Duration = .seconds(10)) async throws -> UInt16 {
    let deadline = ContinuousClock.now + timeout
    var port = await daemon.peerPort
    while port == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
        port = await daemon.peerPort
    }
    return try #require(port)
}

/// Finds what lets other users reach a file or directory.
///
/// - Parameter place: The file or directory.
/// - Returns: The exposure, or `nil` when there is none.
/// - Throws: ``PoolError`` when the file cannot be opened or inspected.
private func accessControlList(at place: URL) throws(PoolError) -> FileExposure? {
    let descriptor = open(place.pathWithoutTrailingSlash, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw .systemCall("opening", place)
    }
    defer { close(descriptor) }
    return try FileExposure.find(in: descriptor, of: place)
}

/// Connects and returns why the connection failed.
///
/// - Parameter connect: Opens the connection.
/// - Returns: The reason of the failure, or `nil` when the connection opened.
func refusal(_ connect: () async throws(PoolError) -> MessageChannel) async -> String? {
    do {
        try await connect().close()
        return nil
    } catch let .connection(_, reason) {
        return reason
    } catch {
        return error.description
    }
}
