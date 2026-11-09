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
        let requests: [PoolRequest] = [.lease(terms), .attach(id), .release(id), .renew(id), .status]
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
        ]
        for reply in replies {
            let data = try MessageCoding.encoder.encode(reply)
            #expect(try MessageCoding.decoder.decode(PoolReply.self, from: data) == reply)
        }
        let text = try String(decoding: MessageCoding.encoder.encode(PoolRequest.lease(terms)), as: UTF8.self)
        #expect(text.hasPrefix(#"{"request":"lease","terms":{"#))
        #expect(text.contains(#""restart":"on-failure""#))
        let outcomes: [MachineOutcome] = [.requested, .guestShutdown, .failed("x"), .lost]
        for outcome in outcomes {
            let data = try MessageCoding.encoder.encode(SupervisorStatus(phase: .exited, outcome: outcome))
            #expect(try MessageCoding.decoder.decode(SupervisorStatus.self, from: data).outcome == outcome)
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
        await #expect(throws: PoolError.socketPathTooLong(path: long.path(percentEncoded: false))) {
            try await MessageChannel.connect(to: long)
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
