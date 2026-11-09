import Foundation
import Logging
@testable import MacpoolPool
import MacpoolVM
import Synchronization
import Testing

/// A data directory, a source bundle, a clock, and a launcher for daemon tests.
///
/// The source bundle holds only its settings, which is enough to clone it. The launcher serves
/// supervisor sockets inside the test process, so no VM boots.
final class PoolFixture {
    /// The directory that holds the data directory and the source bundle.
    let root: ShortDirectory

    /// The daemon's data directory.
    let directory: PoolDirectory

    /// The source bundle's path.
    let source: String

    /// The source bundle's MAC address, which clones must not share.
    static let sourceMACAddress = "02:00:00:00:00:01"

    /// The launcher of every daemon in the test.
    let launcher = FakeLauncher()

    /// The time that the daemons see.
    let clock = TestClock()

    /// Creates the data directory's parent and the source bundle.
    ///
    /// - Throws: An error when the directories or the settings cannot be written.
    init() throws {
        root = try ShortDirectory()
        directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        let bundle = VMBundle(root: root.url.appending(path: "base", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: bundle.root, withIntermediateDirectories: false)
        try bundle.writeSettings(BundleSettings(
            cpuCount: 2,
            memoryByteCount: 4 << 30,
            macAddress: Self.sourceMACAddress,
            build: "25A1",
            hasBooted: true,
        ))
        source = bundle.root.path(percentEncoded: false)
    }

    /// Creates a daemon for the data directory without starting it.
    ///
    /// - Parameter slots: The number of slots.
    /// - Returns: The daemon.
    /// - Throws: ``PoolError`` when the daemon cannot take the directory.
    func daemon(slots: Int = 2) throws(PoolError) -> PoolDaemon {
        let clock = clock
        return try PoolDaemon(configuration: PoolDaemon.Configuration(
            directory: directory,
            policy: PoolPolicy(slots: slots),
            launcher: launcher,
            now: { clock.now },
            tickInterval: nil,
            supervisorConnectTimeout: .seconds(10),
            releaseTimeout: .seconds(10),
            logger: Logger(label: "macpool.tests") { _ in SwiftLogNoOpLogHandler() },
        ))
    }

    /// Creates and starts a daemon for the data directory.
    ///
    /// - Parameter slots: The number of slots.
    /// - Returns: The listening daemon.
    /// - Throws: ``PoolError`` when the daemon cannot take the directory or listen.
    func start(slots: Int = 2) async throws(PoolError) -> PoolDaemon {
        let daemon = try daemon(slots: slots)
        try await daemon.start()
        return daemon
    }

    /// Creates lease terms for the source bundle.
    ///
    /// - Parameters:
    ///   - timeToLive: The time to live in seconds.
    ///   - priority: The queue priority.
    ///   - detached: Whether the lease outlives its client once it is ready.
    /// - Returns: The terms.
    func terms(timeToLive: Int = 3600, priority: Int = 0, detached: Bool = false) -> LeaseTerms {
        LeaseTerms(source: source, timeToLive: timeToLive, priority: priority, detached: detached)
    }

    /// Connects a client to the daemon and sends a lease request.
    ///
    /// - Parameter terms: The requested terms.
    /// - Returns: The client's connection.
    /// - Throws: ``PoolError`` when the daemon does not answer.
    func requestLease(_ terms: LeaseTerms) async throws(PoolError) -> MessageChannel {
        let client = try await PoolClient.connect(to: directory)
        try client.send(PoolRequest.lease(terms))
        return client
    }

    /// Requests a lease and waits until it is ready.
    ///
    /// - Parameter terms: The requested terms.
    /// - Returns: The client's connection and the ready lease.
    /// - Throws: An error when the daemon does not answer with a starting and a ready lease.
    func readyLease(_ terms: LeaseTerms) async throws -> ReadyLease {
        let client = try await requestLease(terms)
        let starting = try await next(client)
        #expect(starting.lease?.phase == .starting)
        let reply = try await next(client)
        let ready = try #require(reply.lease)
        #expect(ready.phase == .ready, "\(reply)")
        #expect(ready.id == starting.lease?.id)
        return ReadyLease(client: client, lease: ready)
    }
}

/// A client connection with its ready lease.
struct ReadyLease {
    /// The client's connection.
    let client: MessageChannel

    /// The lease as the ready reply described it.
    let lease: LeaseSummary
}

/// A clock that moves only when a test advances it.
final class TestClock: Sendable {
    /// The current time.
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    /// The current time.
    var now: Date {
        current.withLock { $0 }
    }

    /// Moves the clock forward.
    ///
    /// - Parameter seconds: The step in seconds.
    func advance(by seconds: TimeInterval) {
        current.withLock { $0 += seconds }
    }
}

/// A launcher that serves supervisor sockets in the test process instead of booting VMs.
///
/// Each launch reports the VM ready at once with its own address. A stop command ends the
/// supervisor the way a real one ends after a requested stop. ``crash(_:)`` ends one without a
/// report.
final class FakeLauncher: SupervisorLauncher {
    /// The running supervisors and the number of launches per lease.
    private struct State {
        /// The supervisors that serve their sockets.
        var servers: [LeaseID: SupervisorServer] = [:]
        /// The number of launches per lease.
        var launches: [LeaseID: Int] = [:]
        /// The number of launches in all, which numbers the addresses.
        var total = 0
    }

    /// The launcher's state.
    private let state = Mutex(State())

    /// Serves a lease's supervisor socket and reports the VM ready.
    ///
    /// - Parameter launch: What to boot.
    /// - Returns: Zero, which the daemon treats as no process to signal.
    /// - Throws: ``PoolError`` when the socket cannot listen.
    func launch(_ launch: SupervisorLaunch) async throws(PoolError) -> Int32 {
        let id = launch.lease
        let directory = launch.directory
        let server = try await SupervisorServer(
            socket: directory.supervisorSocket(for: id),
            status: SupervisorStatus(phase: .booting),
            onStop: { [weak self] in self?.stop(id, directory: directory) },
        )
        let number = state.withLock { state in
            state.servers[id] = server
            state.launches[id, default: 0] += 1
            state.total += 1
            return state.total
        }
        server.publish(SupervisorStatus(phase: .ready, address: "192.168.64.\(number + 1)"))
        return 0
    }

    /// Counts the launches of a lease.
    ///
    /// - Parameter id: The lease.
    /// - Returns: The number of launches.
    func launches(of id: LeaseID) -> Int {
        state.withLock { $0.launches[id] ?? 0 }
    }

    /// Tells whether a lease's supervisor serves its socket.
    ///
    /// - Parameter id: The lease.
    /// - Returns: Whether the supervisor runs.
    func isRunning(_ id: LeaseID) -> Bool {
        state.withLock { $0.servers[id] != nil }
    }

    /// Ends a supervisor without a report, as a crash does.
    ///
    /// - Parameter id: The lease.
    func crash(_ id: LeaseID) async {
        guard let server = state.withLock({ $0.servers.removeValue(forKey: id) }) else {
            return
        }
        await server.close()
    }

    /// Ends a supervisor after a stop command with its record and final status.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - directory: The data directory.
    private func stop(_ id: LeaseID, directory: PoolDirectory) {
        guard let server = state.withLock({ $0.servers.removeValue(forKey: id) }) else {
            return
        }
        try? directory.writeExitRecord(.requested, for: id)
        server.publish(SupervisorStatus(phase: .exited, outcome: .requested))
        Task { await server.close() }
    }
}

/// Access to the lease that a reply carries.
extension PoolReply {
    /// The lease that a starting, ready, restarting, or renewed reply describes.
    var lease: LeaseSummary? {
        switch self {
        case let .starting(lease), let .ready(lease), let .restarting(lease, _), let .renewed(lease):
            lease
        case .queued, .ended, .released, .status, .failure:
            nil
        }
    }
}

/// Receives the next reply on a client connection.
///
/// A receive does not end on task cancellation, so the call closes the connection when no reply
/// arrives in time. The test then fails instead of hanging.
///
/// - Parameters:
///   - client: The client's connection.
///   - timeout: The longest wait for the reply.
/// - Returns: The reply.
/// - Throws: An error when the connection ends first, no reply arrives in time, or a line is
///   malformed.
func next(_ client: MessageChannel, within timeout: Duration = .seconds(10)) async throws -> PoolReply {
    let watchdog = Task {
        try? await Task.sleep(for: timeout)
        if !Task.isCancelled {
            client.close()
        }
    }
    defer { watchdog.cancel() }
    return try #require(await client.receive(PoolReply.self), "no reply within \(timeout)")
}

/// Waits until a condition holds.
///
/// - Parameters:
///   - timeout: The longest wait.
///   - condition: The condition to poll.
/// - Returns: Whether the condition held within the timeout.
func eventually(within timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
