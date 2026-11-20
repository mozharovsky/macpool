import Foundation
@testable import MacpoolPool
import Network
import Synchronization
import Testing

/// Tests of streams from clients to the SSH servers of leases' guests.
@Suite(.timeLimit(.minutes(1)))
struct GuestStreamTests {
    /// A mebibyte without a short repeating pattern.
    static let payload = Data((0 ..< 1 << 20).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8)) })

    /// Relays a mebibyte in both directions over the local socket and passes each normal end on.
    @Test func relaysAMebibyteOverTheLocalSocket() async throws {
        let guest = try await EchoServer()
        defer { guest.close() }
        let pool = try PoolFixture()
        let daemon = try await pool.start(guestSSH: guest.endpoint)
        let granted = try await pool.readyLease(pool.terms())

        let opened = try await PoolClient.openStream(to: granted.lease.id, in: pool.directory)
        #expect(opened.lease == granted.lease)
        #expect(try pool.guestAddresses.all == [#require(granted.lease.address)])
        #expect(try await Self.echo(Self.payload, through: opened.stream) == Self.payload)
        try await opened.stream.finishSending()
        #expect(await Self.end(of: opened.stream) == .finished)
        #expect(await eventually { guest.ends == [.finished] })
        #expect(await eventually { pool.logs.entries("A stream ended").count == 1 })
        #expect(await daemon.summary().leases.map(\.phase) == [.ready])
        opened.stream.close()
        await daemon.shutdown()
    }

    /// Relays a mebibyte for a paired Mac over TLS, where the end of the Mac's sending direction
    /// closes the whole stream.
    @Test func relaysAMebibyteOverTLS() async throws {
        let guest = try await EchoServer()
        defer { guest.close() }
        let pool = try PoolFixture()
        let mac = try RemoteMac(trustedBy: pool)
        let daemon = try await pool.start(
            offeredSources: ["base": pool.source],
            peers: loopbackSettings(),
            guestSSH: guest.endpoint,
        )
        let host = try await mac.host(of: daemon)
        let granted = try await mac.readyLease(on: host)

        let opened = try await PoolClient.openStream(to: granted.lease.id, on: host, directory: mac.directory)
        #expect(opened.lease == granted.lease)
        #expect(try await Self.echo(Self.payload, through: opened.stream) == Self.payload)
        try await opened.stream.finishSending()
        #expect(await eventually { guest.ends == [.finished] })
        #expect(await eventually { pool.logs.entries("A stream ended").count == 1 })
        granted.client.close()
        await daemon.shutdown()
    }

    /// Passes the end of the guest's sending direction to a paired Mac over TLS, and gives the
    /// guest a normal end in return.
    @Test func passesTheGuestsEndToAPairedMac() async throws {
        let guest = try await EchoServer()
        defer { guest.close() }
        let pool = try PoolFixture()
        let mac = try RemoteMac(trustedBy: pool)
        let daemon = try await pool.start(
            offeredSources: ["base": pool.source],
            peers: loopbackSettings(),
            guestSSH: guest.endpoint,
        )
        let host = try await mac.host(of: daemon)
        let granted = try await mac.readyLease(on: host)
        let opened = try await PoolClient.openStream(to: granted.lease.id, on: host, directory: mac.directory)
        #expect(try await Self.echo(Data("ping".utf8), through: opened.stream) == Data("ping".utf8))

        #expect(try await Self.echo(EchoServer.quit, through: opened.stream) == EchoServer.quit)
        #expect(await Self.end(of: opened.stream) == .finished)
        #expect(await eventually { guest.ends == [.finished] })
        granted.client.close()
        await daemon.shutdown()
    }

    /// Resets the guest's side when a paired Mac's connection breaks without a normal end, and
    /// leaves the lease ready.
    @Test func passesAClientResetToTheGuest() async throws {
        let guest = try await EchoServer()
        defer { guest.close() }
        let pool = try PoolFixture()
        let mac = try RemoteMac(trustedBy: pool)
        let daemon = try await pool.start(
            offeredSources: ["base": pool.source],
            peers: loopbackSettings(),
            guestSSH: guest.endpoint,
        )
        let host = try await mac.host(of: daemon)
        let granted = try await mac.readyLease(on: host)
        let opened = try await PoolClient.openStream(to: granted.lease.id, on: host, directory: mac.directory)
        #expect(try await Self.echo(Data("ping".utf8), through: opened.stream) == Data("ping".utf8))

        opened.stream.reset()
        #expect(await eventually { guest.ends == [.failed] })
        #expect(await eventually { pool.logs.entries("A stream ended").count == 1 })
        #expect(await daemon.summary().leases.map(\.phase) == [.ready])
        granted.client.close()
        await daemon.shutdown()
    }

    /// Refuses a stream to another Mac's lease, to a lease that is not ready, and on a connection
    /// that holds a lease. The daemon keeps serving the connection after each refusal.
    @Test func refusesStreamsThatCannotOpen() async throws {
        let guest = try await EchoServer()
        defer { guest.close() }
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source], guestSSH: guest.endpoint)
        let alice = try LeaseLedgerTests.paired("a")
        let holder = try await pool.pairedClient(of: daemon, owner: alice)
        let ready = try await Self.readyLease(on: holder)

        let bob = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("b"))
        try bob.send(PoolRequest.connect(ready.id))
        #expect(try await next(bob) == .failure(PoolError.unknownLease(id: ready.id.rawValue).description))
        try holder.send(PoolRequest.connect(ready.id))
        let busy = PoolError.invalidRequest(
            reason: "a connection that waits for or holds a lease cannot carry a stream. Open another connection",
        )
        #expect(try await next(holder) == .failure(busy.description))

        let gate = Gate()
        pool.launcher.plan(FakeBehavior(listenGate: gate))
        try holder.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 3600)))
        let starting = try #require(await next(holder).lease)
        let idle = try await pool.pairedClient(of: daemon, owner: alice)
        try idle.send(PoolRequest.connect(starting.id))
        let notReady = PoolError.invalidRequest(
            reason: "lease \(starting.id) is starting, and only a ready lease takes connections",
        )
        #expect(try await next(idle) == .failure(notReady.description))
        try idle.send(PoolRequest.status)
        guard case .status = try await next(idle) else {
            Issue.record("the daemon stopped serving the connection after a refusal")
            return
        }
        #expect(pool.guestAddresses.all.isEmpty)
        gate.open()
        await daemon.shutdown()
    }

    /// Sends a local client the guest's failure and a paired Mac a reason without the guest's
    /// address when the guest's SSH server refuses the connection.
    @Test func reportsAGuestThatRefuses() async throws {
        // Nothing listens on port 1 of the loopback interface.
        let refusing = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1)
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source], guestSSH: refusing)
        let local = try await pool.readyLease(pool.terms())
        await #expect {
            try await PoolClient.openStream(to: local.lease.id, in: pool.directory)
        } throws: { error in
            if case let .daemonRefused(message) = error as? PoolError {
                message.contains("\(refusing)")
            } else {
                false
            }
        }

        let alice = try LeaseLedgerTests.paired("a")
        let holder = try await pool.pairedClient(of: daemon, owner: alice)
        let ready = try await Self.readyLease(on: holder)
        let streamer = try await pool.pairedClient(of: daemon, owner: alice)
        try streamer.send(PoolRequest.connect(ready.id))
        #expect(try await next(streamer) == .failure("the guest's SSH server did not accept the connection"))
        #expect(try await isClosed(streamer))
        #expect(pool.logs.entries("A lease's guest refused a stream").count == 2)
        #expect(await daemon.summary().leases.map(\.phase) == [.ready, .ready])
        await daemon.shutdown()
    }

    /// Resets a stream when its lease ends, so that a paired Mac and the guest's SSH server both
    /// see a failure.
    @Test func endsTheStreamWithItsLease() async throws {
        let guest = try await EchoServer()
        defer { guest.close() }
        let pool = try PoolFixture()
        let mac = try RemoteMac(trustedBy: pool)
        let daemon = try await pool.start(
            offeredSources: ["base": pool.source],
            peers: loopbackSettings(),
            guestSSH: guest.endpoint,
        )
        let host = try await mac.host(of: daemon)
        let granted = try await mac.readyLease(on: host)
        let opened = try await PoolClient.openStream(to: granted.lease.id, on: host, directory: mac.directory)
        #expect(try await Self.echo(Data("ping".utf8), through: opened.stream) == Data("ping".utf8))

        let id = granted.lease.id
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        #expect(await Self.end(of: opened.stream) == .failed)
        #expect(await eventually { guest.ends == [.failed] })
        granted.client.close()
        await daemon.shutdown()
    }

    /// Resets a paired Mac's streams when the host revokes the Mac, even when its lease runs on,
    /// and counts the streams among the closed connections.
    @Test func endsTheStreamsOfARevokedMac() async throws {
        let guest = try await EchoServer()
        defer { guest.close() }
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source], guestSSH: guest.endpoint)
        let alice = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = alice else {
            return
        }
        let holder = try await pool.pairedClient(of: daemon, owner: alice)
        let ready = try await Self.readyLease(on: holder, detached: true)
        let stream = try await Self.openStream(to: ready, of: alice, in: pool, daemon: daemon)

        let revoked = try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
        #expect(revoked == .revoked(PairedMac(name: "client", key: key), connections: 2, leases: 0))
        // A Unix socket carries no reset, so the client sees the end of the stream.
        #expect(await Self.end(of: stream) != .timedOut)
        #expect(await eventually { guest.ends == [.failed] })
        #expect(await daemon.summary().leases.map(\.phase) == [.ready])
        await daemon.shutdown()
    }

    /// Resets a paired Mac's streams when the list of paired clients drops the Mac and one of its
    /// connections sends a request, even when its lease runs on.
    @Test func endsTheStreamsOfAMacThatTheListDrops() async throws {
        let guest = try await EchoServer()
        defer { guest.close() }
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source], guestSSH: guest.endpoint)
        let alice = try LeaseLedgerTests.paired("a")
        let holder = try await pool.pairedClient(of: daemon, owner: alice)
        let ready = try await Self.readyLease(on: holder, detached: true)
        let stream = try await Self.openStream(to: ready, of: alice, in: pool, daemon: daemon)

        try TrustList<TrustedClient>().save(to: pool.directory)
        try holder.send(PoolRequest.status)
        let refusal = PoolError.invalidRequest(reason: "the host no longer accepts this Mac")
        #expect(try await next(holder) == .failure(refusal.description))
        // A Unix socket carries no reset, so the client sees the end of the stream.
        #expect(await Self.end(of: stream) != .timedOut)
        #expect(await eventually { guest.ends == [.failed] })
        #expect(await daemon.summary().leases.map(\.phase) == [.ready])
        await daemon.shutdown()
    }

    /// Resets every stream when the daemon stops, so that the guest's SSH server sees a failure.
    @Test func endsStreamsWhenTheDaemonStops() async throws {
        let guest = try await EchoServer()
        defer { guest.close() }
        let pool = try PoolFixture()
        let daemon = try await pool.start(guestSSH: guest.endpoint)
        let granted = try await pool.readyLease(pool.terms())
        let opened = try await PoolClient.openStream(to: granted.lease.id, in: pool.directory)
        #expect(try await Self.echo(Data("ping".utf8), through: opened.stream) == Data("ping".utf8))

        await daemon.shutdown()
        #expect(await Self.end(of: opened.stream) != .timedOut)
        #expect(await eventually { guest.ends == [.failed] })
    }

    /// Refuses a paired Mac's stream beyond ``PoolDaemon/streamsPerPeer`` until one of its
    /// streams ends, and sets the local user no limit.
    @Test func limitsTheStreamsOfOneMac() async throws {
        let guest = try await EchoServer()
        defer { guest.close() }
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source], guestSSH: guest.endpoint)
        let alice = try LeaseLedgerTests.paired("a")
        let holder = try await pool.pairedClient(of: daemon, owner: alice)
        let ready = try await Self.readyLease(on: holder)
        var streams: [ByteStream] = []
        for _ in 0 ..< PoolDaemon.streamsPerPeer {
            try await streams.append(Self.openStream(to: ready, of: alice, in: pool, daemon: daemon))
        }

        let extra = try await pool.pairedClient(of: daemon, owner: alice)
        try extra.send(PoolRequest.connect(ready.id))
        let full = PoolError.invalidRequest(
            reason: "this Mac already has 8 streams to the host's guests, the most it may have",
        )
        #expect(try await next(extra) == .failure(full.description))
        let local = try await PoolClient.openStream(to: ready.id, in: pool.directory)
        local.stream.close()
        streams[0].close()
        #expect(await eventually { pool.logs.entries("A stream ended").count == 2 })
        try extra.send(PoolRequest.connect(ready.id))
        #expect(try await next(extra) == .ready(ready))
        for stream in streams {
            stream.close()
        }
        await daemon.shutdown()
    }

    /// Requests a lease of the offered source on a paired Mac's connection and waits until it is
    /// ready.
    ///
    /// - Parameters:
    ///   - client: The Mac's connection.
    ///   - detached: Whether the lease outlives the connection.
    /// - Returns: The ready lease as the Mac sees it.
    /// - Throws: An error when the daemon does not answer with a starting and a ready lease.
    private static func readyLease(on client: MessageChannel, detached: Bool = false) async throws -> LeaseSummary {
        try client.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 3600, detached: detached)))
        #expect(try await next(client).lease?.phase == .starting)
        let lease = try #require(await next(client).lease)
        #expect(lease.phase == .ready)
        return lease
    }

    /// Opens a stream to a lease's guest on a new connection that the daemon serves for a paired
    /// Mac.
    ///
    /// - Parameters:
    ///   - lease: The lease as the Mac sees it.
    ///   - owner: The Mac.
    ///   - pool: The fixture.
    ///   - daemon: The daemon.
    /// - Returns: The stream.
    /// - Throws: An error when the daemon does not answer with the ready lease.
    private static func openStream(
        to lease: LeaseSummary,
        of owner: LeaseOwner,
        in pool: PoolFixture,
        daemon: PoolDaemon,
    ) async throws -> ByteStream {
        let channel = try await pool.pairedClient(of: daemon, owner: owner)
        try channel.send(PoolRequest.connect(lease.id))
        #expect(try await next(channel) == .ready(lease))
        return try channel.takeStream()
    }

    /// Sends bytes through a stream while it reads the same number of bytes back.
    ///
    /// - Parameters:
    ///   - data: The bytes.
    ///   - stream: The stream.
    /// - Returns: The bytes that came back.
    /// - Throws: ``PoolError`` when the send fails.
    private static func echo(_ data: Data, through stream: ByteStream) async throws -> Data {
        let sending = Task { try await stream.send(data) }
        let received = await stream.read(count: data.count)
        try await sending.value
        return received
    }

    /// Reads until a stream ends and reports how it ended.
    ///
    /// A receive does not end on task cancellation, so the call closes the stream when it stays
    /// open too long.
    ///
    /// - Parameters:
    ///   - stream: The stream.
    ///   - timeout: The longest wait.
    /// - Returns: How the stream ended.
    private static func end(of stream: ByteStream, within timeout: Duration = .seconds(10)) async -> StreamEnd {
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            stream.close()
        }
        defer { watchdog.cancel() }
        do throws(PoolError) {
            while try await stream.receive() != nil {}
            return .finished
        } catch let .connection(_, reason) where reason == "the stream was closed" {
            return .timedOut
        } catch {
            return .failed
        }
    }
}

/// How a stream ended.
enum StreamEnd: Equatable {
    /// The peer ended its sending direction.
    case finished

    /// The connection failed or the peer reset it.
    case failed

    /// The stream stayed open until the test closed it.
    case timedOut
}

/// A stand-in for a guest's SSH server on 127.0.0.1 that sends back every byte it receives.
///
/// When a client ends its sending direction, the server ends its own after the last byte. When
/// a receive returns exactly ``quit``, the server sends it back, ends its sending direction, and
/// waits for the client's end.
final class EchoServer: Sendable {
    /// The bytes that make the server end its sending direction first.
    static let quit = Data("quit".utf8)

    /// The underlying listener.
    private let listener: NWListener

    /// How each connection ended, in the order of the ends.
    private let recordedEnds = Mutex<[StreamEnd]>([])

    /// The address and port on which the server accepts connections.
    var endpoint: NWEndpoint {
        .hostPort(host: .ipv4(.loopback), port: listener.port ?? .any)
    }

    /// How each connection ended, in the order of the ends.
    var ends: [StreamEnd] {
        recordedEnds.withLock { $0 }
    }

    /// Starts listening on a free port of 127.0.0.1 and waits until the listener is ready.
    ///
    /// - Throws: An error when the listener cannot start.
    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [self] connection in
            let channel = MessageChannel(connection: connection, peer: "guest client", start: true)
            guard let stream = try? channel.takeStream() else {
                return
            }
            Task { await self.echo(stream) }
        }
        let listener = listener
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
            listener.start(queue: DispatchQueue(label: "macpool.test.echo"))
        }
        if let failure {
            listener.cancel()
            throw PoolError.connection(path: "127.0.0.1", reason: failure)
        }
    }

    /// Stops listening.
    func close() {
        listener.cancel()
    }

    /// Sends back every byte of a connection and records how the connection ended.
    ///
    /// - Parameter stream: The connection.
    private func echo(_ stream: ByteStream) async {
        do throws(PoolError) {
            var sends = true
            while let data = try await stream.receive() {
                guard sends else {
                    continue
                }
                try await stream.send(data)
                if data == Self.quit {
                    try await stream.finishSending()
                    sends = false
                }
            }
            if sends {
                try await stream.finishSending()
            }
            recordedEnds.withLock { $0.append(.finished) }
        } catch {
            recordedEnds.withLock { $0.append(.failed) }
        }
        stream.close()
    }
}

/// Another Mac with its own data directory and key, which a fixture's host lists as a client.
private final class RemoteMac {
    /// The fixture whose data directory holds the Mac's key.
    private let fixture: PoolFixture

    /// The Mac's key and certificate.
    let identity: MacIdentity

    /// The fingerprint of the host's key.
    let hostKey: KeyFingerprint

    /// The Mac's data directory.
    var directory: PoolDirectory {
        fixture.directory
    }

    /// Creates the Mac's key and replaces the host's list of paired clients with the Mac.
    ///
    /// - Parameter pool: The host's fixture.
    /// - Throws: An error when a key or the list cannot be written.
    init(trustedBy pool: PoolFixture) throws {
        fixture = try PoolFixture()
        identity = try MacIdentity.loadOrCreate(in: fixture.directory)
        hostKey = try listClients([KeyFingerprint(digest: identity.keyDigest)], in: pool.directory)
    }

    /// Returns the record of a listening daemon as this Mac's list of paired hosts would hold it.
    ///
    /// - Parameter daemon: The host's daemon.
    /// - Returns: The host.
    /// - Throws: An error when the daemon does not listen.
    func host(of daemon: PoolDaemon) async throws -> TrustedHost {
        try await TrustedHost(
            key: hostKey,
            name: "host",
            address: "127.0.0.1",
            port: listeningPort(of: daemon),
            pairedAt: Date(),
        )
    }

    /// Leases the offered source over TLS and waits until the lease is ready.
    ///
    /// - Parameter host: The host.
    /// - Returns: The connection that holds the lease, and the lease as this Mac sees it.
    /// - Throws: An error when the connection fails or the daemon does not answer with a starting
    ///   and a ready lease.
    func readyLease(on host: TrustedHost) async throws -> ReadyLease {
        let channel = try await PoolClient.connect(to: loopback(host.port), as: identity, hostKey: hostKey)
        try channel.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 3600)))
        #expect(try await next(channel).lease?.phase == .starting)
        let lease = try #require(await next(channel).lease)
        #expect(lease.phase == .ready)
        return ReadyLease(client: channel, lease: lease)
    }
}
