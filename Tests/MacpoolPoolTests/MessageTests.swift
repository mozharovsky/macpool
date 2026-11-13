import Foundation
@testable import MacpoolPool
import Synchronization
import Testing

/// Tests of the messages, the line channel, and the supervisor socket.
@Suite(.timeLimit(.minutes(1)))
struct MessageTests {
    /// Accepts only eight lowercase hexadecimal digits as a lease identifier.
    @Test func validatesLeaseIdentifiers() throws {
        #expect(LeaseID("0a1b2c3d")?.rawValue == "0a1b2c3d")
        #expect(LeaseID("0A1B2C3D") == nil)
        #expect(LeaseID("0a1b2c3") == nil)
        #expect(LeaseID("../../etc") == nil)
        #expect(LeaseID("0a1b2c3g") == nil)
        for _ in 0 ..< 100 {
            #expect(LeaseID(LeaseID.random().rawValue) != nil)
        }
        #expect(throws: DecodingError.self) {
            try MessageCoding.decoder.decode(LeaseID.self, from: Data(#""../x""#.utf8))
        }
    }

    /// Encodes requests and replies with their kind and decodes them back.
    @Test func roundTripsMessages() throws {
        let id = try #require(LeaseID("0a1b2c3d"))
        let terms = LeaseTerms(source: "/vms/base", timeToLive: 60, sharedDirectory: "/share")
        let lease = LeaseSummary(
            id: id,
            source: "/vms/base",
            bundle: "/pool/leases/0a1b2c3d",
            phase: .ready,
            address: "192.168.64.2",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            restarts: 1,
            detached: false,
            priority: 0,
        )
        let requests: [PoolRequest] = [
            .lease(terms),
            .attach(id),
            .release(id),
            .renew(id),
            .status,
            .invite(address: "127.0.0.1", priorityCeiling: 3),
            .revoke(key: "mzxw-6ytb-oi2d-k3lq", endLeases: true),
            .forget(endLeases: true),
        ]
        for request in requests {
            let data = try MessageCoding.encoder.encode(request)
            #expect(try MessageCoding.decoder.decode(PoolRequest.self, from: data) == request)
        }
        let replies: [PoolReply] = [
            .queued(position: 2),
            .starting(lease),
            .ready(lease),
            .restarting(lease, reason: "boom"),
            .ended(id, reason: "the lease expired"),
            .renewed(lease),
            .released(id),
            .status(PoolSummary(slots: 2, leases: [lease], queue: [])),
            .failure("no lease"),
            .paired(PairedMac(name: "runner", key: randomKey())),
            .alreadyPaired(PairedMac(name: "runner", key: randomKey())),
            .wrongCode,
            .revoked(PairedMac(name: "runner", key: randomKey()), connections: 2, leases: 1),
            .forgotten(leases: 3),
        ]
        for reply in replies {
            let data = try MessageCoding.encoder.encode(reply)
            #expect(try MessageCoding.decoder.decode(PoolReply.self, from: data) == reply)
        }
        let invite = Data(#"{"request":"invite","address":"127.0.0.1"}"#.utf8)
        #expect(try MessageCoding.decoder.decode(PoolRequest.self, from: invite) == .invite(address: "127.0.0.1"))
        let revoke = Data(#"{"request":"revoke","key":"mzxw-6ytb-oi2d-k3lq"}"#.utf8)
        #expect(try MessageCoding.decoder.decode(PoolRequest.self, from: revoke) == .revoke(key: "mzxw-6ytb-oi2d-k3lq"))
        let forget = Data(#"{"request":"forget"}"#.utf8)
        #expect(try MessageCoding.decoder.decode(PoolRequest.self, from: forget) == .forget())
        var hidden = lease
        hidden.source = "base"
        hidden.bundle = nil
        hidden.address = nil
        let hiddenText = try String(decoding: MessageCoding.encoder.encode(PoolReply.ready(hidden)), as: UTF8.self)
        #expect(!hiddenText.contains("bundle"))
        #expect(try MessageCoding.decoder.decode(PoolReply.self, from: Data(hiddenText.utf8)) == .ready(hidden))
        let text = try String(decoding: MessageCoding.encoder.encode(PoolRequest.lease(terms)), as: UTF8.self)
        #expect(text.hasPrefix(#"{"request":"lease","terms":{"#))
        #expect(text.contains(#""restart":"on-failure""#))
        let outcomes: [MachineOutcome] = [.requested, .guestShutdown, .failed("x"), .lost]
        for outcome in outcomes {
            let data = try MessageCoding.encoder.encode(SupervisorStatus(phase: .exited, outcome: outcome))
            #expect(try MessageCoding.decoder.decode(SupervisorStatus.self, from: data).outcome == outcome)
        }
    }

    /// Writes a read-only share under its own key. A daemon that does not know the key then
    /// boots the guest without a share.
    @Test func encodesReadOnlyShareUnderItsOwnKey() throws {
        let terms = LeaseTerms(
            source: "/vms/base",
            timeToLive: 60,
            sharedDirectory: "/share",
            sharedDirectoryIsReadOnly: true,
        )
        let text = try String(decoding: MessageCoding.encoder.encode(terms), as: UTF8.self)
        #expect(text.contains(#""read_only_shared_directory":"/share""#), "\(text)")
        #expect(!text.contains(#""shared_directory""#), "\(text)")
        #expect(try MessageCoding.decoder.decode(LeaseTerms.self, from: Data(text.utf8)) == terms)

        let writable = LeaseTerms(source: "/vms/base", timeToLive: 60, sharedDirectory: "/share")
        let writableText = try String(decoding: MessageCoding.encoder.encode(writable), as: UTF8.self)
        #expect(writableText.contains(#""shared_directory":"/share""#), "\(writableText)")
        #expect(!writableText.contains("read_only"), "\(writableText)")
        #expect(try MessageCoding.decoder.decode(LeaseTerms.self, from: Data(writableText.utf8)) == writable)

        let both = writableText.replacingOccurrences(
            of: #""shared_directory""#,
            with: #""read_only_shared_directory":"/other","shared_directory""#,
        )
        #expect(throws: DecodingError.self) {
            try MessageCoding.decoder.decode(LeaseTerms.self, from: Data(both.utf8))
        }
    }

    /// Writes the supervisor protocol version into every status and requires it when reading.
    @Test func carriesSupervisorProtocolVersion() throws {
        let status = SupervisorStatus(phase: .ready, address: "192.168.64.2")
        let text = try String(decoding: MessageCoding.encoder.encode(status), as: UTF8.self)
        #expect(text.contains(#""protocol":\#(SupervisorStatus.currentProtocol)"#), "\(text)")
        #expect(try MessageCoding.decoder.decode(SupervisorStatus.self, from: Data(text.utf8)) == status)
        // A supervisor from before the version field cannot be trusted.
        #expect(throws: DecodingError.self) {
            try MessageCoding.decoder.decode(SupervisorStatus.self, from: Data(#"{"phase":"ready"}"#.utf8))
        }
    }

    /// Writes the greeting as a reply line and refuses any other reply in its place.
    @Test func encodesTheHostGreeting() throws {
        let greeting = HostGreeting(version: 1, role: .host)
        let text = try String(decoding: MessageCoding.encoder.encode(greeting), as: UTF8.self)
        #expect(text == #"{"reply":"hello","role":"host","version":1}"#)
        #expect(try MessageCoding.decoder.decode(HostGreeting.self, from: Data(text.utf8)) == greeting)
        let status = try MessageCoding.encoder.encode(PoolReply.status(PoolSummary(slots: 1, leases: [], queue: [])))
        #expect(throws: DecodingError.self) {
            try MessageCoding.decoder.decode(HostGreeting.self, from: status)
        }
    }

    /// Rejects terms with relative paths or durations out of range.
    @Test func validatesTerms() {
        #expect(throws: Never.self) {
            try LeaseTerms(source: "/vms/base", timeToLive: 60).validate()
        }
        let invalid = [
            LeaseTerms(source: "vms/base", timeToLive: 60),
            LeaseTerms(source: "/vms/base", timeToLive: 60, sharedDirectory: "share"),
            LeaseTerms(source: "/vms/base", timeToLive: 0),
            LeaseTerms(source: "/vms/base", timeToLive: LeaseTerms.maximumTimeToLive + 1),
            LeaseTerms(source: "/vms/base", timeToLive: 60, bootTimeout: 0),
            LeaseTerms(source: "/vms/base", timeToLive: 60, sharedDirectoryIsReadOnly: true),
        ]
        for terms in invalid {
            #expect(throws: PoolError.self) {
                try terms.validate()
            }
        }
    }

    /// Exchanges lines in both directions and reports the end of the connection.
    @Test func exchangesLinesOverUnixSocket() async throws {
        let directory = try ShortDirectory()
        let socket = directory.url.appending(path: "test.sock")
        let listener = try await SocketListener(socket: socket)
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: socket)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        try client.send(PoolRequest.status)
        try client.send(PoolRequest.release(#require(LeaseID("0a1b2c3d"))))
        #expect(try await server.receive(PoolRequest.self) == .status)
        #expect(try await server.receive(PoolRequest.self) == .release(#require(LeaseID("0a1b2c3d"))))
        try server.send(PoolReply.queued(position: 1))
        #expect(try await client.receive(PoolReply.self) == .queued(position: 1))

        await client.finish()
        #expect(try await server.receive(PoolRequest.self) == nil)
        server.close()
    }

    /// Waits for queued messages until the peer reads them.
    @Test func waitsUntilQueuedMessagesLeave() async throws {
        let directory = try ShortDirectory()
        let socket = directory.url.appending(path: "test.sock")
        let listener = try await SocketListener(socket: socket)
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: socket)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        #expect(await finishes(within: .seconds(10)) { await server.delivered() })
        // The socket's buffers hold far less than the four messages.
        let text = String(repeating: "a", count: 256 << 10)
        for _ in 0 ..< 4 {
            try server.send(text)
        }
        #expect(await !finishes(within: .milliseconds(500)) { await server.delivered() })
        for _ in 0 ..< 4 {
            #expect(try await client.receive(String.self) == text)
        }
        #expect(await finishes(within: .seconds(10)) { await server.delivered() })
        client.close()
        server.close()
    }

    /// Waits only for the messages sent before the wait began.
    @Test func waitsOnlyForEarlierMessages() async throws {
        let directory = try ShortDirectory()
        let socket = directory.url.appending(path: "test.sock")
        let listener = try await SocketListener(socket: socket)
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: socket)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        let text = String(repeating: "a", count: 256 << 10)
        for _ in 0 ..< 4 {
            try server.send(text)
        }
        let earlier = Task { await server.delivered() }
        #expect(await !finishes(within: .milliseconds(300)) { await earlier.value })
        for _ in 0 ..< 4 {
            try server.send(text)
        }
        for _ in 0 ..< 4 {
            #expect(try await client.receive(String.self) == text)
        }
        #expect(await finishes(within: .seconds(10)) { await earlier.value })
        #expect(await !finishes(within: .milliseconds(300)) { await server.delivered() })
        client.close()
        server.close()
    }

    /// Closes the connection instead of queueing more than 4 MiB for a peer that stops reading,
    /// and drops the requests that arrived before.
    @Test func closesWhenThePeerStopsReading() async throws {
        let directory = try ShortDirectory()
        let socket = directory.url.appending(path: "test.sock")
        let listener = try await SocketListener(socket: socket)
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: socket)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())
        // One write carries both lines, so the second waits in the server's buffer.
        let requests = try client.takeStream()
        try await requests.send(Data("{\"request\":\"status\"}\n{\"request\":\"status\"}\n".utf8))
        #expect(try await server.receive(PoolRequest.self) == .status)

        let text = String(repeating: "a", count: 512 << 10)
        let count = MessageChannel.maximumQueuedBytes / text.utf8.count + 2
        for _ in 0 ..< count {
            try server.send(text)
        }
        #expect(await finishes(within: .seconds(10)) { await server.delivered() })
        #expect(try await server.receive(PoolRequest.self) == nil)
        var received = 0
        while let chunk = await requests.receive() {
            received += chunk.count { $0 == UInt8(ascii: "\n") }
        }
        #expect(received < count)
        requests.close()
        server.close()
    }

    /// Leaves the connection to a finish that began, so a close during the finish loses no
    /// message.
    @Test func closeKeepsARunningFinish() async throws {
        let directory = try ShortDirectory()
        let socket = directory.url.appending(path: "test.sock")
        let listener = try await SocketListener(socket: socket)
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: socket)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        // The socket's buffers hold less than one message, so the finish waits until the client
        // reads.
        let text = String(repeating: "a", count: 256 << 10)
        for _ in 0 ..< 4 {
            try server.send(text)
        }
        let finishing = Task { await server.finish(within: .seconds(30)) }
        try await waitUntilFinishBegins(on: server, peer: client)
        server.close()
        server.close()
        for _ in 0 ..< 4 {
            #expect(try await client.receive(String.self) == text)
        }
        #expect(try await client.receive(String.self) == nil)
        await finishing.value
    }

    /// Closes the connection when the time limit of a finish passes, although a close came
    /// during the finish and the peer never reads.
    @Test func finishClosesAtItsTimeLimit() async throws {
        let directory = try ShortDirectory()
        let socket = directory.url.appending(path: "test.sock")
        let listener = try await SocketListener(socket: socket)
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: socket)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        let text = String(repeating: "a", count: 256 << 10)
        for _ in 0 ..< 4 {
            try server.send(text)
        }
        let finishing = Task { await server.finish(within: .milliseconds(200)) }
        try await waitUntilFinishBegins(on: server, peer: client)
        server.close()
        await finishing.value
        // The client read nothing before the limit, so the connection ends before the first
        // message is complete.
        #expect(try await client.receive(String.self) == nil)
    }

    /// Closes the connection at once when no finish began, and a second close changes nothing.
    @Test func closeWithoutFinishDropsQueuedMessages() async throws {
        let directory = try ShortDirectory()
        let socket = directory.url.appending(path: "test.sock")
        let listener = try await SocketListener(socket: socket)
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: socket)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())

        let text = String(repeating: "a", count: 256 << 10)
        for _ in 0 ..< 4 {
            try server.send(text)
        }
        server.close()
        server.close()
        #expect(try await client.receive(String.self) == nil)
        await server.finish()
    }

    /// Returns once a finish of the server began.
    ///
    /// The server reads one request of the peer at a time. Its receive returns `nil` once the
    /// finish began, which tells the test without waiting for a fixed time.
    ///
    /// - Parameters:
    ///   - server: The channel whose finish the test waits for.
    ///   - peer: The other end, which sends the requests.
    /// - Throws: An error when a request cannot be sent or read.
    private func waitUntilFinishBegins(on server: MessageChannel, peer: MessageChannel) async throws {
        repeat {
            try peer.send(PoolRequest.status)
        } while try await server.receive(PoolRequest.self) != nil
    }

    /// Fails at once for a missing socket and for a path that no socket can have.
    @Test func refusesMissingAndOverlongSockets() async throws {
        let directory = try ShortDirectory()
        await #expect {
            try await MessageChannel.connect(to: directory.url.appending(path: "missing.sock"), timeout: .seconds(5))
        } throws: { error in
            if case .connection = error as? PoolError {
                true
            } else {
                false
            }
        }
        let long = directory.url.appending(path: String(repeating: "x", count: 120))
        let path = long.path(percentEncoded: false)
        await #expect(throws: PoolError.socketPathTooLong(path: path, length: path.utf8.count)) {
            try await MessageChannel.connect(to: long, timeout: .seconds(5), aliasDirectory: nil)
        }
    }

    /// Rejects a malformed line.
    @Test func rejectsMalformedLines() async throws {
        let directory = try ShortDirectory()
        let socket = directory.url.appending(path: "test.sock")
        let listener = try await SocketListener(socket: socket)
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: socket)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())
        try client.send(["request": "unknown"])
        await #expect {
            try await server.receive(PoolRequest.self)
        } throws: { error in
            if case .malformedMessage = error as? PoolError {
                true
            } else {
                false
            }
        }
        client.close()
        server.close()
    }

    /// Sends the current status to each new connection and forwards stop commands.
    @Test func servesSupervisorStatus() async throws {
        let directory = try ShortDirectory()
        let socket = directory.url.appending(path: "s.sock")
        let stops = StopRecorder()
        let server = try await SupervisorServer(
            socket: socket,
            status: SupervisorStatus(phase: .booting),
            onStop: { stops.record() },
        )
        let early = try await MessageChannel.connect(to: socket)
        #expect(try await early.receive(SupervisorStatus.self) == SupervisorStatus(phase: .booting))
        server.publish(SupervisorStatus(phase: .ready, address: "192.168.64.5"))
        #expect(try await early.receive(SupervisorStatus.self)?.address == "192.168.64.5")
        let late = try await MessageChannel.connect(to: socket)
        #expect(try await late.receive(SupervisorStatus.self)?.phase == .ready)

        try late.send(SupervisorCommand(.stop))
        while !stops.wasStopped {
            try await Task.sleep(for: .milliseconds(10))
        }
        server.publish(SupervisorStatus(phase: .exited, outcome: .requested))
        await server.close()
        #expect(try await early.receive(SupervisorStatus.self)?.outcome == .requested)
        #expect(try await early.receive(SupervisorStatus.self) == nil)
        #expect(!FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)))
        early.close()
        late.close()
    }
}

/// A record of stop commands that any thread can update.
final class StopRecorder: Sendable {
    /// Whether a stop command arrived.
    private let stopped = Mutex(false)

    /// Records a stop command.
    func record() {
        stopped.withLock { $0 = true }
    }

    /// Whether a stop command arrived.
    var wasStopped: Bool {
        stopped.withLock { $0 }
    }
}
