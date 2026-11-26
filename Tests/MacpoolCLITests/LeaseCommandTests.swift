import ArgumentParser
import Foundation
@testable import MacpoolCLI
@testable import MacpoolPool
import Network
import Synchronization
import Testing

/// Tests of how `macpool lease` attaches to a lease again and releases it.
@Suite(.timeLimit(.minutes(1)))
struct LeaseCommandTests {
    /// Keeps attaching to a ready lease while its paired host sleeps for five minutes, and attaches
    /// within the host's 60-second grace after it wakes.
    @Test func keepsReattachingWhileThePairedHostSleeps() async throws {
        let clock = ReattachClock()
        let expiry = clock.start.addingTimeInterval(3600)
        let wake = clock.start.addingTimeInterval(300)
        let deadline = ReattachSchedule.deadline(expiry: expiry, pairedHost: true, now: clock.start)
        #expect(deadline == expiry)

        let attached = try await clock.schedule(until: deadline).run { () throws(CommandError) in
            try clock.attempt(failingBefore: wake)
        }
        let time = try #require(attached)
        #expect(time >= wake)
        #expect(time.timeIntervalSince(wake) < 60)
        #expect(Array(clock.pauses.prefix(6)) == [1, 2, 4, 8, 15, 15].map { Duration.seconds($0) })
        #expect(clock.pauses.allSatisfy { $0 <= ReattachSchedule.longestPause })
    }

    /// Tries for a minute when the daemon runs on this Mac or the paired host reported no expiry,
    /// so a host that sleeps longer ends the attempts.
    @Test func reattachesForAMinuteWithoutTheExpiryOfAPairedHost() async throws {
        let clock = ReattachClock()
        let minute = clock.start.addingTimeInterval(60)
        #expect(ReattachSchedule.deadline(expiry: nil, pairedHost: true, now: clock.start) == minute)
        let expiry = clock.start.addingTimeInterval(3600)
        #expect(ReattachSchedule.deadline(expiry: expiry, pairedHost: false, now: clock.start) == minute)

        await #expect(throws: ReattachClock.failure) {
            try await clock.schedule(until: minute).run { () throws(CommandError) in
                try clock.attempt(failingBefore: clock.start.addingTimeInterval(300))
            }
        }
        #expect(clock.attempts.allSatisfy { $0 <= minute })
    }

    /// Starts the last attempt at the lease's expiry when the host never answers.
    @Test func stopsReattachingAtTheExpiry() async throws {
        let clock = ReattachClock()
        let expiry = clock.start.addingTimeInterval(120)

        await #expect(throws: ReattachClock.failure) {
            try await clock.schedule(until: expiry).run { () throws(CommandError) in
                try clock.attempt(failingBefore: .distantFuture)
            }
        }
        #expect(try #require(clock.attempts.last) == expiry)
        #expect(clock.attempts.allSatisfy { $0 <= expiry })
    }

    /// Stops at once when another attempt cannot change the failure. A host presents a new key
    /// after `macpool host new-key`.
    @Test(arguments: [
        CommandError.pool(.invalidRequest(reason: "no paired host has the name or key lab")),
        CommandError.pool(.hostKeyMismatch(path: "192.0.2.10:7480", presented: "b", expected: "a")),
        CommandError.pool(.protocolMismatch(path: "192.0.2.10:7480", version: 2, role: "host")),
    ])
    func stopsReattachingOnALastingFailure(failure: CommandError) async {
        let clock = ReattachClock()

        await #expect(throws: failure) {
            try await clock.schedule(until: clock.start.addingTimeInterval(3600)).run { () throws(CommandError) in
                throw failure
            }
        }
        #expect(clock.pauses.isEmpty)
    }

    /// Stops when an awake host refuses every attempt for 120 seconds instead of trying until the
    /// lease expires. A host refuses this way after it revokes this Mac.
    @Test func stopsReattachingWhenAnAwakeHostRefusesFor120Seconds() async throws {
        let clock = ReattachClock()

        await #expect(throws: CommandError.reattachRefused(
            seconds: 120,
            reason: ReattachClock.refusal.description,
        )) {
            try await clock.schedule(until: clock.start.addingTimeInterval(3600)).run { () throws(CommandError) in
                try clock.attempt(cost: 0) { _ in ReattachClock.refusal }
            }
        }
        let stopped = clock.now.timeIntervalSince(clock.start)
        #expect(stopped >= 120)
        #expect(stopped < 120 + ReattachSchedule.longestPause / .seconds(1))
    }

    /// Counts only the time that this Mac stays awake between refusals, because the host keeps the
    /// lease for 120 seconds of its own awake time.
    @Test func ignoresASleepOfThisMacBetweenRefusals() async throws {
        let clock = ReattachClock()

        await #expect(throws: CommandError.reattachRefused(
            seconds: 120,
            reason: ReattachClock.refusal.description,
        )) {
            try await clock.schedule(until: clock.start.addingTimeInterval(3600)).run { () throws(CommandError) in
                if clock.attempts.count == 3 {
                    clock.sleep(for: 600)
                }
                return try clock.attempt(cost: 0) { _ in ReattachClock.refusal }
            }
        }
        let stopped = clock.now.timeIntervalSince(clock.start)
        #expect(stopped >= 600 + 120)
        #expect(stopped < 600 + 120 + ReattachSchedule.longestPause / .seconds(1))
    }

    /// Keeps trying through refusals shorter than 120 seconds. A failure that does not reach the
    /// host, such as a sleep of the host, starts the count again.
    @Test func keepsReattachingThroughShortRefusals() async throws {
        let clock = ReattachClock()

        let attached = try await clock.schedule(until: clock.start.addingTimeInterval(3600)).run {
            () throws(CommandError) in
            try clock.attempt(cost: 0) { elapsed in
                switch elapsed {
                case ..<100: ReattachClock.refusal
                case ..<400: ReattachClock.failure
                case ..<500: ReattachClock.refusal
                default: nil
                }
            }
        }
        #expect(try #require(attached).timeIntervalSince(clock.start) >= 500)
    }

    /// Ends the attempts at the expiry of the last `ready` reply, or of a later renewal of the
    /// lease by another client.
    @Test func followsTheExpiryOfARenewal() throws {
        let id = try #require(LeaseID("0a1b2c3d"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let ready = Self.lease(id, expiringAt: start.addingTimeInterval(3600))
        var expiry = LeaseCommand.expiry(after: .ready(ready), of: id, from: nil)
        #expect(expiry == start.addingTimeInterval(3600))

        let other = try Self.lease(#require(LeaseID("4e5f6a7b")), expiringAt: start.addingTimeInterval(9000))
        expiry = LeaseCommand.expiry(after: .renewed(other), of: id, from: expiry)
        #expect(expiry == start.addingTimeInterval(3600))
        let renewed = Self.lease(id, expiringAt: start.addingTimeInterval(7100))
        expiry = LeaseCommand.expiry(after: .renewed(renewed), of: id, from: expiry)
        expiry = LeaseCommand.expiry(after: .released(id), of: id, from: expiry)
        let deadline = ReattachSchedule.deadline(expiry: expiry, pairedHost: true, now: start.addingTimeInterval(3590))
        #expect(deadline == start.addingTimeInterval(7100))
    }

    /// Fails within a few seconds when a paired host does not answer a release, and says that the
    /// host ends the lease by itself.
    @Test func reportsAReleaseThatAPairedHostDoesNotConfirm() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mp-lease-" + UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pool = PoolDirectory(root: directory.appending(path: "pool", directoryHint: .isDirectory))
        let host = try await SilentListener()
        defer { host.stop() }
        _ = try MacIdentity.loadOrCreate(in: pool)
        var list = TrustList<TrustedHost>()
        let key = try #require(KeyFingerprint(String(repeating: "a", count: 64)))
        list.insert(TrustedHost(key: key, name: "lab", address: "127.0.0.1", port: host.port, pairedAt: Date()))
        try list.save(to: pool)
        let command = try #require(
            try Macpool.parseAsRoot(["lease", "--pool", "lab", "--from", "base"]) as? LeaseCommand,
        )
        let lease = try #require(LeaseID("0a1b2c3d"))

        let started = ContinuousClock.now
        let error = await #expect(throws: CommandError.self) {
            try await LeaseCommand.release(lease, through: command.selection, in: pool)
        }
        #expect(ContinuousClock.now - started < .seconds(9))
        guard case let .releaseUnconfirmed(id, _)? = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(id == "0a1b2c3d")
        #expect(error?.description.contains("The host ends the lease 60 seconds after") == true)
    }

    /// Sends the release on the connection that holds the lease after the command ends, and opens
    /// no second connection. A paired host may refuse a new connection when the Mac has its limit.
    @Test func releasesOnTheConnectionThatHoldsTheLease() async throws {
        let daemon = try await LeaseDaemon()
        let command = try daemon.command()
        let run = Task { try await command.run() }
        let holder = try await daemon.grant(command)
        #expect(try await holder.receive(PoolRequest.self) == .release(daemon.id))
        try holder.send(PoolReply.ended(daemon.id, reason: "released by a client"))
        try holder.send(PoolReply.released(daemon.id))
        try await run.value
        #expect(await daemon.otherConnections() == 0)
    }

    /// Exits with the command's status when the daemon on this Mac does not confirm the release,
    /// because the daemon ends the lease once the connection closes.
    @Test func exitsWhenTheDaemonDoesNotConfirmTheRelease() async throws {
        let daemon = try await LeaseDaemon()
        let command = try daemon.command()
        let started = ContinuousClock.now
        let run = Task { try await command.run() }
        let holder = try await daemon.grant(command)
        #expect(try await holder.receive(PoolRequest.self) == .release(daemon.id))
        try await run.value
        #expect(ContinuousClock.now - started < .seconds(9))
        #expect(await daemon.otherConnections() == 0)
    }

    /// Creates a ready lease as a paired host shows it.
    ///
    /// - Parameters:
    ///   - id: The lease's identifier.
    ///   - expiry: The lease's expiry.
    /// - Returns: The lease.
    private static func lease(_ id: LeaseID, expiringAt expiry: Date) -> LeaseSummary {
        LeaseSummary(
            id: id,
            source: "base",
            bundle: nil,
            phase: .ready,
            address: nil,
            expiresAt: expiry,
            restarts: 0,
            detached: false,
            priority: 0,
        )
    }
}

/// A daemon socket in the test process that grants one lease and follows a script.
private final class LeaseDaemon {
    /// The temporary directory that holds the data directory.
    private let parent: URL

    /// The data directory, whose daemon socket the test serves.
    let directory: PoolDirectory

    /// The socket.
    private let listener: SocketListener

    /// The lease that the daemon grants.
    let id = LeaseID("0a1b2c3d") ?? LeaseID.random()

    /// Listens on the data directory's daemon socket.
    ///
    /// - Throws: An error when the directory cannot be prepared or the socket cannot listen.
    init() async throws {
        parent = FileManager.default.temporaryDirectory
            .appending(path: "mp-lease-" + UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
        directory = PoolDirectory(root: parent.appending(path: "pool", directoryHint: .isDirectory))
        try directory.prepare()
        listener = try await SocketListener(socket: directory.daemonSocket)
    }

    /// Stops listening and removes the data directory.
    deinit {
        listener.close()
        try? FileManager.default.removeItem(at: parent)
    }

    /// Parses a `macpool lease` that runs `/usr/bin/true` with this data directory.
    ///
    /// - Returns: The command.
    /// - Throws: An error when the options do not parse.
    func command() throws -> LeaseCommand {
        let path = directory.root.path(percentEncoded: false)
        return try #require(
            try Macpool.parseAsRoot(["lease", "--data-dir", path, "--from", "/base", "--", "/usr/bin/true"])
                as? LeaseCommand,
        )
    }

    /// Accepts the command's connection, reads its request, and reports the lease ready.
    ///
    /// - Parameter command: The running command.
    /// - Returns: The connection that holds the lease.
    /// - Throws: An error when no connection or no lease request arrives.
    func grant(_ command: LeaseCommand) async throws -> MessageChannel {
        var connections = listener.connections.makeAsyncIterator()
        let holder = try #require(await connections.next())
        #expect(try await holder.receive(PoolRequest.self) == .lease(command.terms))
        try holder.send(PoolReply.starting(lease(in: .starting)))
        try holder.send(PoolReply.ready(lease(in: .ready)))
        return holder
    }

    /// Stops listening and counts the connections after the first.
    ///
    /// - Returns: The number of connections that the daemon did not accept with ``grant(_:)``.
    func otherConnections() async -> Int {
        listener.close()
        var count = 0
        for await _ in listener.connections {
            count += 1
        }
        return count
    }

    /// Creates the lease as the daemon shows it.
    ///
    /// - Parameter phase: The lease's phase.
    /// - Returns: The lease.
    private func lease(in phase: LeasePhase) -> LeaseSummary {
        LeaseSummary(
            id: id,
            source: "/base",
            bundle: "/clone",
            phase: phase,
            address: phase == .ready ? "192.168.64.2" : nil,
            expiresAt: phase == .ready ? Date().addingTimeInterval(3600) : nil,
            restarts: 0,
            detached: false,
            priority: 0,
        )
    }
}

/// A clock for the attempts to attach again.
///
/// The clock moves only when an attempt fails, the schedule pauses, or the test calls
/// ``sleep(for:)``.
private final class ReattachClock: Sendable {
    /// The readings and the records of the attempts.
    private struct State {
        /// The current time.
        var now: Date

        /// The time this Mac stayed awake since the clock started.
        var awake: Duration = .zero

        /// The pauses in the order the schedule asked for them.
        var pauses: [Duration] = []

        /// The times at which attempts started.
        var attempts: [Date] = []
    }

    /// The error of an attempt that does not reach the host.
    static let failure = CommandError.pool(.connection(path: "192.0.2.10:7480", reason: "no answer within 10 seconds"))

    /// The error of an attempt that an awake host refuses after the handshake.
    static let refusal = CommandError.pool(.greetingFailed(
        path: "192.0.2.10:7480",
        reason: "the host closed the connection, so it does not accept this Mac's key",
    ))

    /// The time at which every clock starts.
    private static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    /// The awake time at which the clock started.
    private let awakeStart = SuspendingClock().now

    /// The current readings and records.
    private let state = Mutex(State(now: ReattachClock.origin))

    /// The time at which the clock started.
    var start: Date {
        Self.origin
    }

    /// The current time.
    var now: Date {
        state.withLock { $0.now }
    }

    /// The current time on a clock that stops while this Mac sleeps.
    var awakeTime: SuspendingClock.Instant {
        awakeStart.advanced(by: state.withLock { $0.awake })
    }

    /// The pauses in the order the schedule asked for them.
    var pauses: [Duration] {
        state.withLock { $0.pauses }
    }

    /// The times at which attempts started.
    var attempts: [Date] {
        state.withLock { $0.attempts }
    }

    /// Returns a schedule that reads this clock and moves it by each pause.
    ///
    /// - Parameter deadline: The time after which no attempt starts.
    /// - Returns: The schedule.
    func schedule(until deadline: Date) -> ReattachSchedule {
        ReattachSchedule(deadline: deadline, now: { self.now }, awakeTime: { self.awakeTime }) { duration in
            self.state.withLock {
                $0.pauses.append(duration)
                $0.now += duration / .seconds(1)
                $0.awake += duration
            }
        }
    }

    /// Moves only the current time, as a sleep of this Mac does.
    ///
    /// - Parameter seconds: The length of the sleep.
    func sleep(for seconds: TimeInterval) {
        state.withLock { $0.now += seconds }
    }

    /// Records an attempt that fails like a handshake with a host that does not answer.
    ///
    /// A failed attempt moves the clock by 10 seconds, the timeout of a handshake.
    ///
    /// - Parameter wake: The time from which the host answers.
    /// - Returns: The time at which the attempt succeeded.
    /// - Throws: ``failure`` when the attempt starts before `wake`.
    func attempt(failingBefore wake: Date) throws(CommandError) -> Date {
        let awake = wake.timeIntervalSince(start)
        return try attempt { $0 < awake ? Self.failure : nil }
    }

    /// Records an attempt whose outcome depends on its start.
    ///
    /// - Parameters:
    ///   - cost: How far a failed attempt moves the clock, in seconds.
    ///   - outcome: Returns the error of an attempt that starts the given number of seconds after
    ///     ``start``, or `nil` for an attempt that succeeds.
    /// - Returns: The time at which the attempt succeeded.
    /// - Throws: The error that `outcome` returns.
    func attempt(cost: TimeInterval = 10, _ outcome: (TimeInterval) -> CommandError?) throws(CommandError) -> Date {
        let (started, failure) = state.withLock { state in
            let started = state.now
            state.attempts.append(started)
            let failure = outcome(started.timeIntervalSince(Self.origin))
            if failure != nil {
                state.now += cost
                state.awake += .seconds(cost)
            }
            return (started, failure)
        }
        if let failure {
            throw failure
        }
        return started
    }
}

/// A TCP listener on the loopback interface that accepts connections and never answers, like a
/// host that stopped responding during the TLS handshake.
private final class SilentListener: Sendable {
    /// The listener's port.
    let port: UInt16

    /// The listener.
    private let listener: NWListener

    /// The accepted connections. The stream's buffer keeps them open while the listener lives.
    private let accepted: AsyncStream<MessageChannel>

    /// Starts the listener.
    ///
    /// - Throws: An error when the listener cannot start.
    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let (accepted, continuation) = AsyncStream.makeStream(of: MessageChannel.self)
        listener.newConnectionHandler = { connection in
            continuation.yield(MessageChannel(connection: connection, peer: "silent host", start: true))
        }
        let ready: Bool = await withCheckedContinuation { ready in
            let once = ResumeOnce(ready)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: true)
                case .failed, .waiting:
                    once.resume(returning: false)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "macpool.test.silent"))
        }
        self.listener = listener
        self.accepted = accepted
        port = try #require(ready ? listener.port?.rawValue : nil, "the listener did not start")
    }

    /// Stops the listener.
    func stop() {
        listener.cancel()
    }
}
