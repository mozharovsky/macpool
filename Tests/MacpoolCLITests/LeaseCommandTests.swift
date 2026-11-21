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
}

/// A clock for the attempts to attach again, which moves only when an attempt or a pause moves
/// it.
private final class ReattachClock: Sendable {
    /// The readings and the records of the attempts.
    private struct State {
        /// The current time.
        var now: Date

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
        ReattachSchedule(deadline: deadline, now: { self.now }) { duration in
            self.state.withLock {
                $0.pauses.append(duration)
                $0.now += duration / .seconds(1)
            }
        }
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
