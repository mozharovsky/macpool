public import Foundation
public import Logging
import MacpoolVM
import Subprocess
import System

/// The daemon that owns a host's VM slots, its lease queue, and the supervisors of leased VMs.
///
/// Clients connect to the socket at ``PoolDirectory/daemonSocket`` and exchange ``PoolRequest``
/// and ``PoolReply`` lines. A lease request waits in the queue until a slot is free. The daemon
/// then clones the request's source into the data directory and starts a supervisor process that
/// boots the clone. Once the supervisor reports the VM ready, the client receives the lease's
/// identifier, clone, and address.
///
/// The daemon writes every change of its leases to ``PoolDirectory/stateFile``. Supervisors run in
/// their own sessions and keep their VMs while the daemon is away. A new daemon reads the state,
/// reconnects to the supervisors, and resumes the leases. Supervisors that ended meanwhile count as
/// stopped VMs under each lease's restart policy, and clients of attached leases get a grace period
/// to reattach.
///
/// A lease ends on release, on expiry, when its attached client disconnects, or when its VM stops
/// and the restart policy does not boot it again. The daemon then stops the VM, deletes the clone,
/// and grants the slot to the next request.
public actor PoolDaemon {
    /// The daemon's settings and collaborators.
    public struct Configuration: Sendable {
        /// The data directory.
        public var directory: PoolDirectory

        /// The limits and timings.
        public var policy: PoolPolicy

        /// The launcher that starts supervisor processes.
        public var launcher: any SupervisorLauncher

        /// The source of the current time.
        public var now: @Sendable () -> Date

        /// The interval between checks of expiries and restart times, or `nil` when only explicit
        /// calls to ``PoolDaemon/tick()`` check them.
        public var tickInterval: Duration?

        /// The longest wait for a new supervisor's socket.
        public var supervisorConnectTimeout: Duration

        /// The longest wait for a stopped VM's supervisor to release the clone.
        public var releaseTimeout: Duration

        /// The logger for lease events.
        public var logger: Logger

        /// Creates a configuration.
        ///
        /// - Parameters:
        ///   - directory: The data directory.
        ///   - policy: The limits and timings.
        ///   - launcher: The launcher that starts supervisor processes.
        ///   - now: The source of the current time.
        ///   - tickInterval: The interval between checks of expiries and restart times, or `nil`.
        ///   - supervisorConnectTimeout: The longest wait for a new supervisor's socket.
        ///   - releaseTimeout: The longest wait for a supervisor to release a stopped clone.
        ///   - logger: The logger for lease events.
        public init(
            directory: PoolDirectory,
            policy: PoolPolicy = PoolPolicy(),
            launcher: any SupervisorLauncher,
            now: @escaping @Sendable () -> Date = { Date() },
            tickInterval: Duration? = .seconds(1),
            supervisorConnectTimeout: Duration = .seconds(30),
            releaseTimeout: Duration = .seconds(120),
            logger: Logger = Logger(label: "macpool.daemon"),
        ) {
            self.directory = directory
            self.policy = policy
            self.launcher = launcher
            self.now = now
            self.tickInterval = tickInterval
            self.supervisorConnectTimeout = supervisorConnectTimeout
            self.releaseTimeout = releaseTimeout
            self.logger = logger
        }
    }

    /// The daemon's connection to one supervisor.
    private struct Link {
        /// The connection.
        let channel: MessageChannel
        /// The number that tells this connection from earlier ones of the same lease.
        let token: UInt64
        /// The time at which the daemon asked the supervisor to stop, if it did.
        var stopSentAt: Date?
    }

    /// The settings and collaborators.
    private let configuration: Configuration

    /// The data directory's lock, held until ``shutdown()``.
    private var lock: DaemonLock?

    /// The state file.
    private let store: PoolStore

    /// The leases and the queue.
    private var ledger: LeaseLedger

    /// The client socket while the daemon listens.
    private var listener: SocketListener?

    /// The connected clients.
    private var clients: [ClientID: MessageChannel] = [:]

    /// The number of the next client.
    private var nextClient: UInt64 = 0

    /// The open supervisor connections.
    private var links: [LeaseID: Link] = [:]

    /// The token of the next supervisor connection.
    private var nextToken: UInt64 = 0

    /// The leases whose supervisor the daemon starts or reconnects to.
    private var connecting: Set<LeaseID> = []

    /// The leases whose clone the daemon deletes.
    private var discarding: Set<LeaseID> = []

    /// The background tasks that accept clients and tick.
    private var loops: [Task<Void, Never>] = []

    /// Whether ``shutdown()`` ran, after which the daemon ignores events.
    private var isShutDown = false

    /// The phase of each lease when the daemon last logged it.
    ///
    /// Clients receive only the changes of their own leases, so the log follows the ledger
    /// instead and also covers detached leases.
    private var loggedPhases: [LeaseID: LeasePhase] = [:]

    /// The wait between checks of a clone's lock and between connection attempts.
    private static let pollInterval = Duration.milliseconds(100)

    /// The time after a stop request at which the daemon ends an unresponsive supervisor.
    private static let stopGrace: TimeInterval = 120

    /// Takes the data directory's lock and reads the stored leases.
    ///
    /// - Parameter configuration: The settings and collaborators.
    /// - Throws: ``PoolError/daemonRunning(path:)`` when another daemon serves the directory,
    ///   ``PoolError/invalidRequest(reason:)`` when the policy's slot count is out of range, or
    ///   another ``PoolError`` when the directory or the state file is unusable.
    public init(configuration: Configuration) throws(PoolError) {
        guard (1 ... PoolPolicy.maximumSlots).contains(configuration.policy.slots) else {
            throw .invalidRequest(reason: "the daemon takes 1 to \(PoolPolicy.maximumSlots) slots")
        }
        try configuration.directory.prepare()
        lock = try DaemonLock(directory: configuration.directory)
        store = PoolStore(file: configuration.directory.stateFile)
        ledger = try LeaseLedger(
            policy: configuration.policy,
            directory: configuration.directory,
            state: store.load(),
        )
        self.configuration = configuration
        loggedPhases = ledger.leases.mapValues(\.phase)
    }

    /// Resumes the stored leases and starts accepting clients.
    ///
    /// - Throws: ``PoolError`` when the client socket cannot listen.
    public func start() async throws(PoolError) {
        removeOrphans()
        perform(ledger.recover(now: configuration.now()))
        let listener = try await SocketListener(socket: configuration.directory.daemonSocket)
        self.listener = listener
        configuration.logger.info("Listening", metadata: [
            "socket": "\(configuration.directory.daemonSocket.path(percentEncoded: false))",
            "slots": "\(configuration.policy.slots)",
            "leases": "\(ledger.leases.count)",
        ])
        loops.append(Task { [weak self] in
            for await channel in listener.connections {
                await self?.accept(channel)
            }
        })
        if let interval = configuration.tickInterval {
            loops.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    await self?.tick()
                }
            })
        }
    }

    /// Stops accepting clients and closes every connection, but leaves the supervisors and their
    /// VMs running.
    ///
    /// The stored state stays as it is, so a new daemon resumes the leases. The call releases the
    /// data directory's lock.
    public func shutdown() {
        isShutDown = true
        for loop in loops {
            loop.cancel()
        }
        loops = []
        listener?.close()
        listener = nil
        for channel in clients.values {
            channel.close()
        }
        for link in links.values {
            link.channel.close()
        }
        clients = [:]
        links = [:]
        lock = nil
        configuration.logger.info("Stopped listening. Supervisors keep running.")
    }

    /// Applies expiries, restart times, and the reattach grace, and retries unfinished clean-ups.
    public func tick() {
        guard !isShutDown else {
            return
        }
        let now = configuration.now()
        perform(ledger.tick(now: now))
        for (id, record) in ledger.leases where record.phase == .stopping {
            if var link = links[id] {
                if let sent = link.stopSentAt, now.timeIntervalSince(sent) > Self.stopGrace {
                    link.stopSentAt = now
                    links[id] = link
                    terminateSupervisor(of: id, processID: record.supervisorProcessID)
                }
            } else if !connecting.contains(id), !discarding.contains(id) {
                startDiscard(id)
            }
        }
    }

    /// Describes the pool.
    ///
    /// - Returns: The slots, leases, and queue.
    public func summary() -> PoolSummary {
        ledger.summary()
    }

    // MARK: Clients

    /// Registers a new client and serves its requests.
    ///
    /// - Parameter channel: The client's connection.
    private func accept(_ channel: MessageChannel) {
        guard !isShutDown else {
            channel.close()
            return
        }
        let client = ClientID(value: nextClient)
        nextClient += 1
        clients[client] = channel
        Task { await self.serve(client, on: channel) }
    }

    /// Reads a client's requests until it disconnects.
    ///
    /// - Parameters:
    ///   - client: The client.
    ///   - channel: The client's connection.
    private func serve(_ client: ClientID, on channel: MessageChannel) async {
        while true {
            let request: PoolRequest?
            do {
                request = try await channel.receive(PoolRequest.self)
            } catch {
                try? channel.send(PoolReply.failure(error.description))
                break
            }
            guard let request, !isShutDown else {
                break
            }
            handle(request, from: client)
        }
        channel.close()
        guard !isShutDown, clients.removeValue(forKey: client) != nil else {
            return
        }
        perform(ledger.clientDisconnected(client, now: configuration.now()))
    }

    /// Answers one request.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - client: The client that sent it.
    private func handle(_ request: PoolRequest, from client: ClientID) {
        do throws(PoolError) {
            switch request {
            case let .lease(terms):
                try terms.validate()
                try Self.checkSource(terms.source)
                configuration.logger.info("Queued a lease request", metadata: ["source": "\(terms.source)"])
                perform(ledger.request(terms, from: client, now: configuration.now()))
            case let .attach(id):
                try perform(ledger.attach(id, client: client))
            case let .release(id):
                try perform(ledger.release(id, reason: "released by a client"))
                reply(.released(id), to: client)
            case let .renew(id):
                let summary = try ledger.renew(id, now: configuration.now())
                perform([])
                reply(.renewed(summary), to: client)
            case .status:
                reply(.status(ledger.summary()), to: client)
            }
        } catch {
            reply(.failure(error.description), to: client)
        }
    }

    /// Sends a reply to a client that is still connected.
    ///
    /// - Parameters:
    ///   - reply: The reply.
    ///   - client: The receiving client.
    private func reply(_ reply: PoolReply, to client: ClientID) {
        try? clients[client]?.send(reply)
    }

    /// Checks that a source is a bundle that a clone can start from.
    ///
    /// - Parameter source: The source bundle's path.
    /// - Throws: ``PoolError/library(_:)`` when the settings cannot be read or the source's own
    ///   credential rotation did not finish.
    private static func checkSource(_ source: String) throws(PoolError) {
        let bundle = VMBundle(root: URL(filePath: source))
        let settings: BundleSettings
        do {
            settings = try bundle.settings()
        } catch {
            throw .library(error)
        }
        guard settings.credentialRotation != .started else {
            throw .library(.credentialRotationIncomplete(path: source))
        }
    }

    // MARK: Ledger actions

    /// Stores the ledger and performs the actions of a change.
    ///
    /// - Parameter actions: The actions that the change returned.
    private func perform(_ actions: [LedgerAction]) {
        // A daemon that shut down leaves the state to its successor.
        guard !isShutDown else {
            return
        }
        do {
            try store.save(ledger.state)
        } catch {
            configuration.logger.error("The pool state could not be saved", metadata: ["error": "\(error)"])
        }
        logChanges()
        for action in actions {
            switch action {
            case let .notify(client, reply):
                self.reply(reply, to: client)
            case let .launch(id):
                startLaunch(id)
            case let .stop(id):
                stopMachine(id)
            case let .discard(id):
                startDiscard(id)
            case let .reconnect(id):
                startReconnect(id)
            }
        }
    }

    /// Logs the leases whose phase changed since the last call and the leases that left the pool.
    private func logChanges() {
        let logger = configuration.logger
        for (id, record) in ledger.leases.sorted(by: { $0.key < $1.key }) where loggedPhases[id] != record.phase {
            loggedPhases[id] = record.phase
            switch record.phase {
            case .starting:
                logger.info("Booting a lease", metadata: [
                    "lease": "\(id)",
                    "source": "\(record.terms.source)",
                    "restarts": "\(record.restarts)",
                ])
            case .ready:
                logger.info("A lease is ready", metadata: ["lease": "\(id)", "address": "\(record.address ?? "")"])
            case .restarting:
                logger.notice("A lease's VM stopped and boots again", metadata: [
                    "lease": "\(id)",
                    "restarts": "\(record.restarts)",
                ])
            case .stopping:
                logger.info("A lease ended", metadata: ["lease": "\(id)", "reason": "\(record.endReason ?? "")"])
            }
        }
        for id in loggedPhases.keys.sorted() where ledger.leases[id] == nil {
            loggedPhases[id] = nil
            logger.info("Deleted a lease's clone", metadata: ["lease": "\(id)"])
        }
    }

    // MARK: Supervisors

    /// Starts a boot of a lease unless one is under way.
    ///
    /// - Parameter id: The lease.
    private func startLaunch(_ id: LeaseID) {
        guard let record = ledger.leases[id], !connecting.contains(id), links[id] == nil else {
            return
        }
        connecting.insert(id)
        Task { await self.launch(id, terms: record.terms) }
    }

    /// Prepares the clone, starts the supervisor, and connects to it.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - terms: The lease's terms.
    private func launch(_ id: LeaseID, terms: LeaseTerms) async {
        let directory = configuration.directory
        var processID: Int32?
        do throws(PoolError) {
            let clone = directory.bundle(for: id)
            // A record that remains from an earlier boot would otherwise describe this one.
            try? FileManager.default.removeItem(at: directory.exitRecord(for: id))
            // An earlier supervisor of the same clone may still be exiting.
            guard await waitForRelease(of: clone) else {
                throw .supervisorLaunch(reason: "another process still holds \(clone.root.path(percentEncoded: false))")
            }
            try prepareClone(id, terms: terms)
            try? FileManager.default.removeItem(at: directory.supervisorSocket(for: id))
            let launched = try await configuration.launcher.launch(SupervisorLaunch(
                lease: id,
                directory: directory,
                sharedDirectory: terms.sharedDirectory,
                bootTimeout: terms.bootTimeout,
            ))
            processID = launched
            ledger.supervisorLaunched(id, processID: launched)
            perform([])
            let channel = try await connectToSupervisor(of: id)
            connecting.remove(id)
            attach(channel, to: id)
        } catch {
            connecting.remove(id)
            if let processID {
                terminateSupervisor(of: id, processID: processID)
            }
            let outcome = directory.readExitRecord(for: id) ?? .failed(error.description)
            perform(ledger.machineExited(id, outcome, now: configuration.now()))
        }
    }

    /// Creates the lease's clone unless a usable one exists.
    ///
    /// A clone whose credential rotation began and did not finish holds credentials that nothing
    /// can use, so the boot starts from a fresh clone instead. A clone from an earlier boot keeps
    /// the guest's disk otherwise.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - terms: The lease's terms.
    /// - Throws: ``PoolError`` when the old clone cannot be removed, or the source is in use or
    ///   cannot be cloned.
    private func prepareClone(_ id: LeaseID, terms: LeaseTerms) throws(PoolError) {
        let clone = configuration.directory.bundle(for: id)
        let path = clone.root.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path) {
            if let settings = try? clone.settings(), settings.credentialRotation != .started {
                return
            }
            do {
                try FileManager.default.removeItem(at: clone.root)
            } catch {
                throw .fileSystem("removing the unusable clone", clone.root, error)
            }
        }
        let source = VMBundle(root: URL(filePath: terms.source))
        do throws(MacpoolError) {
            let sourceLock = try BundleLock(bundle: source)
            defer { withExtendedLifetime(sourceLock) {} }
            let cloned = try source.clone(to: clone.root)
            do {
                try cloned.assignIdentity()
            } catch {
                try? FileManager.default.removeItem(at: clone.root)
                throw error
            }
        } catch {
            throw .library(error)
        }
    }

    /// Connects to a new supervisor's socket, retrying until it listens.
    ///
    /// - Parameter id: The lease.
    /// - Returns: The connection.
    /// - Throws: ``PoolError/supervisorLaunch(reason:)`` when the socket does not answer within the
    ///   configured timeout.
    private func connectToSupervisor(of id: LeaseID) async throws(PoolError) -> MessageChannel {
        let socket = configuration.directory.supervisorSocket(for: id)
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.supervisorConnectTimeout
        while true {
            if let channel = try? await MessageChannel.connect(to: socket, timeout: .seconds(2)) {
                return channel
            }
            // A supervisor that already exited leaves its record, and waiting longer cannot help.
            if FileManager.default
                .fileExists(atPath: configuration.directory.exitRecord(for: id).path(percentEncoded: false)) {
                throw .supervisorLaunch(reason: "the supervisor exited before it listened")
            }
            guard clock.now < deadline else {
                throw .supervisorLaunch(
                    reason: "the supervisor did not listen within \(configuration.supervisorConnectTimeout)",
                )
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Reconnects to the supervisor that a lease had before the daemon started.
    ///
    /// - Parameter id: The lease.
    private func startReconnect(_ id: LeaseID) {
        guard !connecting.contains(id), links[id] == nil else {
            return
        }
        connecting.insert(id)
        Task {
            let socket = configuration.directory.supervisorSocket(for: id)
            let channel = try? await MessageChannel.connect(to: socket, timeout: .seconds(2))
            self.reconnected(id, channel: channel)
        }
    }

    /// Resumes a lease with its reconnected supervisor, or reports the supervisor as gone.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - channel: The connection, or `nil` when the supervisor did not answer.
    private func reconnected(_ id: LeaseID, channel: MessageChannel?) {
        connecting.remove(id)
        guard !isShutDown else {
            channel?.close()
            return
        }
        if let channel {
            configuration.logger.info("Reconnected to a supervisor", metadata: ["lease": "\(id)"])
            attach(channel, to: id)
            return
        }
        let outcome = configuration.directory.readExitRecord(for: id) ?? .lost
        if outcome == .lost {
            terminateSupervisor(of: id, processID: ledger.leases[id]?.supervisorProcessID)
        }
        perform(ledger.machineExited(id, outcome, now: configuration.now()))
    }

    /// Follows a supervisor connection and sends a stop when the lease already ended.
    ///
    /// - Parameters:
    ///   - channel: The supervisor connection.
    ///   - id: The lease.
    private func attach(_ channel: MessageChannel, to id: LeaseID) {
        guard !isShutDown, ledger.leases[id] != nil else {
            channel.close()
            return
        }
        nextToken += 1
        let token = nextToken
        links[id] = Link(channel: channel, token: token)
        if ledger.leases[id]?.phase == .stopping {
            stopMachine(id)
        }
        Task { await self.follow(channel, of: id, token: token) }
    }

    /// Applies a supervisor's statuses until its connection ends.
    ///
    /// - Parameters:
    ///   - channel: The supervisor connection.
    ///   - id: The lease.
    ///   - token: The connection's token.
    private func follow(_ channel: MessageChannel, of id: LeaseID, token: UInt64) async {
        var exited = false
        while let status = try? await channel.receive(SupervisorStatus.self) {
            guard !isShutDown, links[id]?.token == token else {
                return
            }
            if status.phase == .exited {
                exited = true
                links[id] = nil
                configuration.logger.info("A supervisor reported the end of its VM", metadata: [
                    "lease": "\(id)",
                    "outcome": "\(status.outcome.map(String.init(describing:)) ?? "")",
                ])
            }
            perform(ledger.supervisorReported(id, status, now: configuration.now()))
            if exited {
                break
            }
        }
        channel.close()
        guard !exited, !isShutDown, links[id]?.token == token else {
            return
        }
        links[id] = nil
        // A supervisor that writes its record and then loses the connection still says how it
        // ended.
        let outcome = configuration.directory.readExitRecord(for: id) ?? .lost
        configuration.logger.warning("A supervisor connection ended", metadata: [
            "lease": "\(id)",
            "outcome": "\(outcome)",
        ])
        perform(ledger.machineExited(id, outcome, now: configuration.now()))
    }

    /// Asks a lease's supervisor to stop the VM.
    ///
    /// A lease without a connection either connects soon, and the connection then sends the stop,
    /// or has no supervisor, and its clone goes at once.
    ///
    /// - Parameter id: The lease.
    private func stopMachine(_ id: LeaseID) {
        if var link = links[id] {
            try? link.channel.send(SupervisorCommand(.stop))
            link.stopSentAt = configuration.now()
            links[id] = link
        } else if !connecting.contains(id) {
            perform(ledger.machineExited(id, .lost, now: configuration.now()))
        }
    }

    /// Ends a supervisor process that no longer answers on its socket.
    ///
    /// The call sends `SIGTERM` only when the process's command line shows that it is this lease's
    /// supervisor, because a stored process identifier can belong to another process after a host
    /// restart. The supervisor answers the signal by stopping its VM.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - processID: The stored process identifier, or `nil` when none is known.
    private func terminateSupervisor(of id: LeaseID, processID: Int32?) {
        guard let processID, processID > 0 else {
            return
        }
        let directory = configuration.directory.root.path(percentEncoded: false)
        let logger = configuration.logger
        Task.detached {
            let result = try? await run(
                .path("/bin/ps"),
                arguments: ["-o", "command=", "-p", String(processID)],
                output: .string(limit: 1 << 16),
            )
            guard let command = result?.standardOutput, command.contains(" supervise "),
                  command.contains(directory), command.contains("--lease \(id.rawValue)")
            else {
                return
            }
            logger.warning("Ending an unresponsive supervisor", metadata: ["lease": "\(id)", "pid": "\(processID)"])
            kill(processID, SIGTERM)
        }
    }

    // MARK: Clean-up

    /// Starts deleting a lease's clone unless that is under way.
    ///
    /// - Parameter id: The lease.
    private func startDiscard(_ id: LeaseID) {
        guard !discarding.contains(id) else {
            return
        }
        discarding.insert(id)
        Task { await self.discard(id) }
    }

    /// Deletes a lease's clone, socket, and exit record once no process holds the clone, and frees
    /// the slot.
    ///
    /// When a process still holds the clone after the release timeout, the lease stays stopping
    /// and a later tick tries again.
    ///
    /// - Parameter id: The lease.
    private func discard(_ id: LeaseID) async {
        let directory = configuration.directory
        let clone = directory.bundle(for: id)
        guard await waitForRelease(of: clone) else {
            discarding.remove(id)
            configuration.logger.error("A stopped lease's clone is still in use", metadata: ["lease": "\(id)"])
            terminateSupervisor(of: id, processID: ledger.leases[id]?.supervisorProcessID)
            return
        }
        do {
            if FileManager.default.fileExists(atPath: clone.root.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: clone.root)
            }
        } catch {
            discarding.remove(id)
            configuration.logger.error("A stopped lease's clone could not be deleted", metadata: [
                "lease": "\(id)",
                "error": "\(error.localizedDescription)",
            ])
            return
        }
        try? FileManager.default.removeItem(at: directory.supervisorSocket(for: id))
        try? FileManager.default.removeItem(at: directory.exitRecord(for: id))
        discarding.remove(id)
        links[id] = nil
        guard !isShutDown else {
            return
        }
        perform(ledger.discarded(id, now: configuration.now()))
    }

    /// Waits until no process holds a bundle's lock.
    ///
    /// - Parameter bundle: The bundle.
    /// - Returns: `false` when a process still holds the lock after the release timeout.
    private func waitForRelease(of bundle: VMBundle) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.releaseTimeout
        while BundleLock.isHeld(on: bundle) {
            guard clock.now < deadline else {
                return false
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return true
    }

    /// Removes clones, sockets, and exit records that belong to no stored lease.
    ///
    /// They remain when the daemon stopped between writing them and recording the lease. A
    /// supervisor that still listens on an unknown socket receives a stop, and its clone goes on a
    /// later start. Entries whose names are not lease identifiers stay untouched.
    private func removeOrphans() {
        let directory = configuration.directory
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: directory.leasesDirectory.path(percentEncoded: false))) ??
            [] {
            guard let id = LeaseID(name), ledger.leases[id] == nil else {
                continue
            }
            let clone = directory.bundle(for: id)
            if !BundleLock.isHeld(on: clone) {
                configuration.logger.notice("Removing a clone without a lease", metadata: ["lease": "\(id)"])
                try? manager.removeItem(at: clone.root)
            }
        }
        for name in (try? manager.contentsOfDirectory(atPath: directory.runDirectory.path(percentEncoded: false))) ??
            [] {
            let stem = name.split(separator: ".").first.map(String.init) ?? ""
            guard let id = LeaseID(stem), ledger.leases[id] == nil else {
                continue
            }
            let file = directory.runDirectory.appending(path: name)
            if name.hasSuffix(".sock") {
                Task.detached {
                    if let channel = try? await MessageChannel.connect(to: file, timeout: .seconds(2)) {
                        try? channel.send(SupervisorCommand(.stop))
                        channel.close()
                    } else {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            } else {
                try? manager.removeItem(at: file)
            }
        }
    }
}
