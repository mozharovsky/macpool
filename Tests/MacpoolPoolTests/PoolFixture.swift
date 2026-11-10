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

    /// The messages that the daemons log.
    let logs = LogRecorder()

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
    /// - Parameters:
    ///   - slots: The number of slots.
    ///   - offeredSources: The source paths that paired clients may lease, keyed by name.
    /// - Returns: The daemon.
    /// - Throws: ``PoolError`` when the daemon cannot take the directory.
    func daemon(slots: Int = 2, offeredSources: [String: String] = [:]) throws(PoolError) -> PoolDaemon {
        let clock = clock
        let logs = logs
        return try PoolDaemon(configuration: PoolDaemon.Configuration(
            directory: directory,
            policy: PoolPolicy(slots: slots),
            launcher: launcher,
            offeredSources: offeredSources,
            now: { clock.now },
            tickInterval: nil,
            supervisorConnectTimeout: .seconds(10),
            reconnectWindow: .seconds(1),
            signalGrace: .milliseconds(500),
            releaseTimeout: .seconds(2),
            logger: Logger(label: "macpool.tests") { _ in RecordingLogHandler(recorder: logs) },
        ))
    }

    /// Creates and starts a daemon for the data directory.
    ///
    /// - Parameters:
    ///   - slots: The number of slots.
    ///   - offeredSources: The source paths that paired clients may lease, keyed by name.
    /// - Returns: The listening daemon.
    /// - Throws: ``PoolError`` when the daemon cannot take the directory or listen.
    func start(slots: Int = 2, offeredSources: [String: String] = [:]) async throws(PoolError) -> PoolDaemon {
        let daemon = try daemon(slots: slots, offeredSources: offeredSources)
        try await daemon.start()
        return daemon
    }

    /// Connects a client that the daemon serves for a paired Mac.
    ///
    /// The test's own socket stands in for the network listener. The daemon receives the
    /// accepted connection with the owner that a handshake would establish.
    ///
    /// - Parameters:
    ///   - daemon: The daemon.
    ///   - owner: Who the client acts for.
    /// - Returns: The client's end of the connection.
    /// - Throws: An error when the socket cannot listen or the connection fails.
    func pairedClient(of daemon: PoolDaemon, owner: LeaseOwner) async throws -> MessageChannel {
        let socket = root.url.appending(path: "paired.sock")
        let listener = try await SocketListener(socket: socket)
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: socket)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())
        await daemon.accept(server, owner: owner)
        return client
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

/// How a fake supervisor behaves.
struct FakeBehavior: Sendable {
    /// The wait between the launch and the socket's first listen, like a real process's start-up.
    var listenDelay: Duration = .zero

    /// Whether the supervisor ignores stop commands, like one that hangs in a VM call.
    var ignoresStop = false

    /// Whether the supervisor survives `SIGTERM`.
    var ignoresTerminate = false

    /// How long the check of the supervisor's process takes before a signal.
    var identifyDelay: Duration = .zero

    /// Why the check of the supervisor's process fails, or `nil` when it succeeds.
    var mismatch: SupervisorMismatch?

    /// How long the supervisor keeps its locks after it closed its socket at the end of a run.
    var lingerAfterExit: Duration = .zero

    /// The protocol version that the supervisor reports.
    var protocolVersion = SupervisorStatus.currentProtocol
}

/// A signal that the fake launcher received.
struct ReceivedSignal: Sendable, Equatable {
    /// The lease whose supervisor the daemon signaled.
    let lease: LeaseID

    /// The signal.
    let signal: SupervisorSignal

    /// The process identifier that the daemon passed.
    let processID: Int32
}

/// A launcher that runs supervisors in the test process instead of booting VMs.
///
/// A fake supervisor holds the lease's ``SupervisorLock`` with a fake process identifier and the
/// clone's ``BundleLock``, serves the lease's socket, and reports the VM ready at once with its own
/// address. A stop command and `SIGTERM` end it the way a real supervisor ends after a requested
/// stop, and `SIGKILL` ends it like ``crash(_:)``. A signal reaches a supervisor only when the
/// daemon passes the identifier from its lock. ``FakeBehavior`` values from ``plan(_:)`` change
/// how the next launches behave.
final class FakeLauncher: SupervisorLauncher {
    /// One fake supervisor process.
    private struct Supervisor {
        /// The fake process identifier, which the supervisor records in its lock.
        let processID: Int32
        /// How the supervisor behaves.
        let behavior: FakeBehavior
        /// The lease's supervisor lock.
        let lock: SupervisorLock
        /// The clone's lock, held while the VM runs.
        var cloneLock: BundleLock?
        /// The socket while the supervisor listens.
        var server: SupervisorServer?
        /// The status that the supervisor reports to new connections.
        var status: SupervisorStatus
        /// Whether the run ended and the supervisor only waits to exit.
        var hasExited = false
    }

    /// The running supervisors and the launch history.
    private struct State {
        /// The supervisors that hold their locks.
        var supervisors: [LeaseID: Supervisor] = [:]
        /// The number of launches per lease.
        var launches: [LeaseID: Int] = [:]
        /// The number of launches in all, which numbers the addresses and process identifiers.
        var total = 0
        /// The behaviors of the next launches, in launch order.
        var plans: [FakeBehavior] = []
        /// The signals that the daemon sent, in order.
        var signals: [ReceivedSignal] = []
        /// The number of process checks that the daemon started.
        var identifications = 0
        /// The start times that the daemon passed to the process checks, in order.
        var startTimes: [RecordedStartTime] = []
    }

    /// The launcher's state.
    private let state = Mutex(State())

    /// Sets how the next launches behave.
    ///
    /// - Parameter behaviors: One behavior per launch. Later launches behave as the default.
    func plan(_ behaviors: FakeBehavior...) {
        state.withLock { $0.plans += behaviors }
    }

    /// Takes the lease's locks and serves its socket, at once or after the planned delay.
    ///
    /// - Parameter launch: What to boot.
    /// - Returns: The fake process identifier, which is 10000 plus the launch's number. The lock
    ///   records ``startTime(of:)`` of that identifier.
    /// - Throws: ``PoolError`` when another supervisor of the lease holds its lock or the socket
    ///   cannot listen.
    func launch(_ launch: SupervisorLaunch) async throws(PoolError) -> Int32 {
        let id = launch.lease
        let directory = launch.directory
        let (number, behavior) = state.withLock { state in
            state.total += 1
            return (state.total, state.plans.isEmpty ? FakeBehavior() : state.plans.removeFirst())
        }
        let processID = Int32(10000 + number)
        let lock = try SupervisorLock(
            of: id,
            in: directory,
            processID: processID,
            startTime: Self.startTime(of: processID),
            timeout: 1,
        )
        let cloneLock: BundleLock
        do {
            cloneLock = try BundleLock(bundle: directory.bundle(for: id))
        } catch {
            throw .library(error)
        }
        let status = SupervisorStatus(
            phase: .ready,
            address: "192.168.64.\(number + 1)",
            protocolVersion: behavior.protocolVersion,
        )
        state.withLock { state in
            state.supervisors[id] = Supervisor(
                processID: processID,
                behavior: behavior,
                lock: lock,
                cloneLock: cloneLock,
                status: status,
            )
            state.launches[id, default: 0] += 1
        }
        if behavior.listenDelay == .zero {
            try await listen(id, directory: directory, processID: processID)
        } else {
            Task {
                try? await Task.sleep(for: behavior.listenDelay)
                try? await self.listen(id, directory: directory, processID: processID)
            }
        }
        return processID
    }

    /// Accepts every process identifier after the supervisor's planned delay unless its behavior
    /// plans a mismatch, so that ``signals()`` records each signal the daemon sends.
    ///
    /// - Parameters:
    ///   - processID: The identifier that the daemon read.
    ///   - startTime: The start time that the daemon read, which ``startTimes()`` records.
    ///   - id: The lease.
    ///   - directory: The data directory.
    /// - Throws: The supervisor's planned ``FakeBehavior/mismatch``.
    func identify(
        processID _: Int32,
        startTime: RecordedStartTime,
        of id: LeaseID,
        in _: PoolDirectory,
    ) async throws(SupervisorMismatch) {
        let behavior = state.withLock { state in
            state.identifications += 1
            state.startTimes.append(startTime)
            return state.supervisors[id]?.behavior ?? FakeBehavior()
        }
        try? await Task.sleep(for: behavior.identifyDelay)
        if let mismatch = behavior.mismatch {
            throw mismatch
        }
    }

    /// The start time that a fake supervisor records in its lock.
    ///
    /// - Parameter processID: The fake process identifier.
    /// - Returns: A start time in microseconds that differs for each identifier.
    static func startTime(of processID: Int32) -> UInt64 {
        1_800_000_000_000_000 + UInt64(processID)
    }

    /// Lists the start times that the daemon passed to the process checks.
    ///
    /// - Returns: The start times in order.
    func startTimes() -> [RecordedStartTime] {
        state.withLock { $0.startTimes }
    }

    /// Counts the process checks that the daemon started.
    ///
    /// - Returns: The number of checks.
    func identifications() -> Int {
        state.withLock { $0.identifications }
    }

    /// Applies a signal to the supervisor whose identifier the daemon passed.
    ///
    /// - Parameters:
    ///   - signal: The signal.
    ///   - processID: The identifier that the daemon read.
    ///   - id: The lease.
    ///   - directory: The data directory.
    func send(_ signal: SupervisorSignal, to processID: Int32, of id: LeaseID, in directory: PoolDirectory) {
        // A copy of the supervisor would hold its lock, so only the facts leave the state.
        let target = state.withLock { state -> (ignoresTerminate: Bool, hasExited: Bool)? in
            state.signals.append(ReceivedSignal(lease: id, signal: signal, processID: processID))
            guard let supervisor = state.supervisors[id], supervisor.processID == processID else {
                return nil
            }
            return (supervisor.behavior.ignoresTerminate, supervisor.hasExited)
        }
        guard let target else {
            return
        }
        switch signal {
        case .terminate where target.ignoresTerminate:
            return
        case .terminate where !target.hasExited:
            exit(id, .requested, directory: directory)
        case .terminate, .kill:
            Task { await self.crash(id) }
        }
    }

    /// Counts the launches of a lease.
    ///
    /// - Parameter id: The lease.
    /// - Returns: The number of launches.
    func launches(of id: LeaseID) -> Int {
        state.withLock { $0.launches[id] ?? 0 }
    }

    /// Lists the signals that the daemon sent.
    ///
    /// - Returns: The signals in the order they arrived.
    func signals() -> [ReceivedSignal] {
        state.withLock { $0.signals }
    }

    /// Tells whether a lease's supervisor still holds its lock.
    ///
    /// - Parameter id: The lease.
    /// - Returns: Whether the supervisor runs.
    func isRunning(_ id: LeaseID) -> Bool {
        state.withLock { $0.supervisors[id] != nil }
    }

    /// Reports a status on a supervisor's socket without changing its run.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - status: The status.
    func report(_ id: LeaseID, _ status: SupervisorStatus) {
        state.withLock { $0.supervisors[id]?.server }?.publish(status)
    }

    /// Ends a supervisor without a report, as a crash or `SIGKILL` does.
    ///
    /// - Parameter id: The lease.
    func crash(_ id: LeaseID) async {
        guard let supervisor = state.withLock({ $0.supervisors.removeValue(forKey: id) }) else {
            return
        }
        await supervisor.server?.close()
        withExtendedLifetime(supervisor) {}
    }

    /// Closes a supervisor's socket and every connection while the supervisor keeps running.
    ///
    /// - Parameter id: The lease.
    func dropConnections(_ id: LeaseID) async {
        let server = state.withLock { state -> SupervisorServer? in
            let server = state.supervisors[id]?.server
            state.supervisors[id]?.server = nil
            return server
        }
        await server?.close()
    }

    /// Serves a supervisor's socket again after ``dropConnections(_:)``.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - directory: The data directory.
    /// - Throws: ``PoolError`` when the socket cannot listen.
    func relisten(_ id: LeaseID, directory: PoolDirectory) async throws(PoolError) {
        guard let processID = state.withLock({ $0.supervisors[id]?.processID }) else {
            return
        }
        try await listen(id, directory: directory, processID: processID)
    }

    /// Ends a supervisor's run the way a real supervisor does.
    ///
    /// The supervisor releases the clone, writes its exit record, reports the outcome, and closes
    /// its socket. It releases its lock last, after its planned linger.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - outcome: How the run ended.
    ///   - directory: The data directory.
    func exit(_ id: LeaseID, _ outcome: MachineOutcome, directory: PoolDirectory) {
        // The task below must not hold a copy of the supervisor, which would keep its lock.
        let ended = state.withLock { state -> (server: SupervisorServer?, linger: Duration, processID: Int32)? in
            guard var supervisor = state.supervisors[id], !supervisor.hasExited else {
                return nil
            }
            supervisor.hasExited = true
            supervisor.cloneLock = nil
            supervisor.status = SupervisorStatus(
                phase: .exited,
                outcome: outcome,
                protocolVersion: supervisor.behavior.protocolVersion,
            )
            state.supervisors[id] = supervisor
            return (supervisor.server, supervisor.behavior.lingerAfterExit, supervisor.processID)
        }
        guard let ended else {
            return
        }
        try? directory.writeExitRecord(outcome, for: id)
        ended.server?.publish(SupervisorStatus(phase: .exited, outcome: outcome))
        Task {
            await ended.server?.close()
            try? await Task.sleep(for: ended.linger)
            self.state.withLock { state in
                if state.supervisors[id]?.processID == ended.processID {
                    state.supervisors[id] = nil
                }
            }
        }
    }

    /// Serves a supervisor's socket with its current status.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - directory: The data directory.
    ///   - processID: The supervisor that listens, which must still run.
    /// - Throws: ``PoolError`` when the socket cannot listen.
    private func listen(_ id: LeaseID, directory: PoolDirectory, processID: Int32) async throws(PoolError) {
        guard let status = state.withLock({ $0.supervisors[id]?.status }) else {
            return
        }
        let server = try await SupervisorServer(
            socket: directory.supervisorSocket(for: id),
            status: status,
            onStop: { [weak self] in self?.stopRequested(id, directory: directory) },
        )
        let kept = state.withLock { state in
            guard state.supervisors[id]?.processID == processID, !(state.supervisors[id]?.hasExited ?? true) else {
                return false
            }
            state.supervisors[id]?.server = server
            return true
        }
        if !kept {
            await server.close()
        }
    }

    /// Ends a supervisor after a stop command unless it ignores stops.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - directory: The data directory.
    private func stopRequested(_ id: LeaseID, directory: PoolDirectory) {
        guard state.withLock({ $0.supervisors[id]?.behavior.ignoresStop == false }) else {
            return
        }
        exit(id, .requested, directory: directory)
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

/// Runs an operation and reports whether it finished in time.
///
/// If the operation runs longer, it keeps running in its own task after the call returns.
///
/// - Parameters:
///   - timeout: The longest wait.
///   - operation: The work to run in its own task.
/// - Returns: Whether the operation finished within the timeout.
func finishes(within timeout: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    await withCheckedContinuation { continuation in
        let once = ResumeOnce(continuation)
        Task {
            await operation()
            once.resume(returning: true)
        }
        Task {
            try? await Task.sleep(for: timeout)
            once.resume(returning: false)
        }
    }
}

/// A log message with its metadata.
struct LogEntry: Sendable {
    /// The message.
    let message: String

    /// The metadata of the message, merged with the logger's metadata, as text.
    let metadata: [String: String]
}

/// The messages that a test's loggers wrote.
final class LogRecorder: Sendable {
    /// The messages in the order of logging.
    private let entries = Mutex<[LogEntry]>([])

    /// Adds a message.
    ///
    /// - Parameter entry: The message.
    func record(_ entry: LogEntry) {
        entries.withLock { $0.append(entry) }
    }

    /// Returns the messages with a text.
    ///
    /// - Parameter message: The text of the messages.
    /// - Returns: The messages in the order of logging.
    func entries(_ message: String) -> [LogEntry] {
        entries.withLock { $0.filter { $0.message == message } }
    }
}

/// A log handler that keeps every message in a ``LogRecorder``.
struct RecordingLogHandler: LogHandler {
    /// The recorder that keeps the messages.
    let recorder: LogRecorder

    /// The metadata that every message carries.
    var metadata: Logger.Metadata = [:]

    /// The lowest level that reaches the recorder.
    var logLevel: Logger.Level = .trace

    /// The provider of extra metadata, which the tests do not use.
    var metadataProvider: Logger.MetadataProvider?

    /// The logger's value for a metadata key.
    ///
    /// - Parameter key: The metadata key.
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// Records a message.
    ///
    /// - Parameter event: The message with its level and metadata.
    func log(event: LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { $1 }
        recorder.record(LogEntry(message: event.message.description, metadata: merged.mapValues(\.description)))
    }
}
