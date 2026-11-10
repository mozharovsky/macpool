public import Foundation
public import Logging
import MacpoolVM

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
/// reconnects to the supervisors, and resumes the leases. Clients of attached leases get a grace
/// period to reattach.
///
/// The daemon treats a supervisor as gone only once its ``SupervisorLock`` is free. A supervisor
/// whose connection ends while it holds the lock gets reconnected. One that does not answer within
/// the reconnect window, ignores a stop, or speaks another protocol version gets `SIGTERM` and then
/// `SIGKILL`. A lease that was ending then deletes its clone. For any other lease, a run that the
/// daemon ended this way counts as a failure under the restart policy.
///
/// A lease ends on release, on expiry, when its attached client disconnects, or when its VM stops
/// and the restart policy does not boot it again. The daemon then stops the VM, waits until the
/// supervisor exits, deletes the clone, and grants the slot to the next request.
///
/// Each lease has a ``LeaseOwner``. A client on the socket acts for the local user and may act on
/// every lease. A paired client from another Mac sees and changes only its own leases. It names a
/// source by one of the names in ``Configuration/offeredSources``. It cannot share a host
/// directory or ask for a priority above the default of 0.
///
/// With ``Configuration/peers`` set, the daemon also listens on TCP for paired Macs. It loads this
/// Mac's key only then. A key that cannot be loaded or a port that another process holds leaves
/// the local socket serving, and the daemon tries again later. A paired Mac proves its key in a
/// TLS handshake, receives a greeting with the protocol version, and then exchanges the same
/// lines as a local client.
///
/// After the daemon handles a request, it waits until the messages that it sent to the client so
/// far left, and only then reads the next request. Lease events sent later do not extend the
/// wait. A client that stops reading therefore stalls only its own connection.
public actor PoolDaemon {
    /// The daemon's settings and collaborators.
    public struct Configuration: Sendable {
        /// The data directory.
        public var directory: PoolDirectory

        /// The limits and timings.
        public var policy: PoolPolicy

        /// The launcher that starts and signals supervisor processes.
        public var launcher: any SupervisorLauncher

        /// The source bundles that paired clients may lease, keyed by the name that a client
        /// sends as its source.
        ///
        /// Each value is the bundle's absolute path. An empty dictionary leaves paired clients
        /// without sources.
        public var offeredSources: [String: String]

        /// How the daemon listens for paired Macs, or `nil` when it serves only the local socket.
        public var peers: PeerSettings?

        /// The source of the current time for expiries, restarts, and stop deadlines.
        public var now: @Sendable () -> Date

        /// The interval between checks of expiries and restart times, or `nil` when only explicit
        /// calls to ``PoolDaemon/tick()`` check them.
        public var tickInterval: Duration?

        /// The longest wait for a new supervisor's socket.
        public var supervisorConnectTimeout: Duration

        /// How long the daemon tries to reconnect to a supervisor that still runs before it ends
        /// the supervisor by signal.
        public var reconnectWindow: Duration

        /// The time after a stop command at which the daemon signals a supervisor that still runs,
        /// measured with ``now``.
        public var stopGrace: Duration

        /// The wait for a supervisor to exit after the daemon asked it to stop or signaled it.
        public var signalGrace: Duration

        /// The longest wait for a supervisor to exit on its own before a new boot or the deletion
        /// of the clone, after which the daemon stops it.
        public var releaseTimeout: Duration

        /// How long a supervisor log stays after its lease ends.
        public var logRetention: Duration

        /// The logger for lease events.
        public var logger: Logger

        /// Creates a configuration.
        ///
        /// - Parameters:
        ///   - directory: The data directory.
        ///   - policy: The limits and timings.
        ///   - launcher: The launcher that starts and signals supervisor processes.
        ///   - offeredSources: The absolute paths of the source bundles that paired clients may
        ///     lease, keyed by the name that a client sends.
        ///   - peers: How the daemon listens for paired Macs, or `nil` for the local socket only.
        ///   - now: The source of the current time.
        ///   - tickInterval: The interval between checks of expiries and restart times, or `nil`.
        ///   - supervisorConnectTimeout: The longest wait for a new supervisor's socket.
        ///   - reconnectWindow: How long the daemon reconnects to a running supervisor before it
        ///     signals it.
        ///   - stopGrace: The time after a stop command at which a running supervisor gets signals.
        ///   - signalGrace: The wait for a supervisor to exit after each stop request or signal.
        ///   - releaseTimeout: The longest wait for a supervisor to exit on its own.
        ///   - logRetention: How long a supervisor log stays after its lease ends.
        ///   - logger: The logger for lease events.
        public init(
            directory: PoolDirectory,
            policy: PoolPolicy = PoolPolicy(),
            launcher: any SupervisorLauncher,
            offeredSources: [String: String] = [:],
            peers: PeerSettings? = nil,
            now: @escaping @Sendable () -> Date = { Date() },
            tickInterval: Duration? = .seconds(1),
            supervisorConnectTimeout: Duration = .seconds(30),
            reconnectWindow: Duration = .seconds(30),
            stopGrace: Duration = .seconds(30),
            signalGrace: Duration = .seconds(10),
            releaseTimeout: Duration = .seconds(60),
            logRetention: Duration = .seconds(7 * 24 * 3600),
            logger: Logger = Logger(label: "macpool.daemon"),
        ) {
            self.directory = directory
            self.policy = policy
            self.launcher = launcher
            self.offeredSources = offeredSources
            self.peers = peers
            self.now = now
            self.tickInterval = tickInterval
            self.supervisorConnectTimeout = supervisorConnectTimeout
            self.reconnectWindow = reconnectWindow
            self.stopGrace = stopGrace
            self.signalGrace = signalGrace
            self.releaseTimeout = releaseTimeout
            self.logRetention = logRetention
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

    /// How a supervisor ended while the daemon waited for it.
    private enum SupervisorEnding: Equatable {
        /// The supervisor exited on its own, and its exit record tells how the run ended.
        case exited
        /// The daemon had to stop the supervisor by command or signal.
        case endedByDaemon
        /// The supervisor still holds its lock after the last step.
        ///
        /// - Parameter killSent: Whether the daemon sent `SIGKILL`. It withholds the signal from a
        ///   process that the launcher does not identify.
        case stuck(killSent: Bool)
        /// The supervisor still runs, because its lease ended and the state file does not record
        /// that yet.
        case deferred

        /// Whether the supervisor no longer holds its lock.
        var hasEnded: Bool {
            self == .exited || self == .endedByDaemon
        }

        /// The message that the daemon logs for a supervisor that does not end, or `nil` when it
        /// ended or keeps running by design.
        var stuckMessage: Logger.Message? {
            switch self {
            case .stuck(killSent: true):
                "A supervisor survives SIGKILL"
            case .stuck(killSent: false):
                "A supervisor does not exit, and the daemon withheld SIGKILL"
            case .exited, .endedByDaemon, .deferred:
                nil
            }
        }
    }

    /// The outcome of one attempt to listen for paired Macs.
    private enum PeerListenerAttempt {
        /// The listener is ready.
        case listening(PeerListener)
        /// The key or the port failed, and a later attempt may succeed.
        case failed
        /// The daemon shut down.
        case stopped
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

    /// The listener for paired Macs while it listens.
    private var peerListener: PeerListener?

    /// Why the listener for paired Macs last failed to start, or `nil` after it started.
    ///
    /// The daemon logs a failure only when its reason differs from this one. A failure that
    /// repeats on every attempt therefore appears in the log once.
    private var peerListenerFailure: String?

    /// The connected clients.
    private var clients: [ClientID: MessageChannel] = [:]

    /// The number of the next client.
    private var nextClient: UInt64 = 0

    /// The open supervisor connections.
    private var links: [LeaseID: Link] = [:]

    /// The token of the next supervisor connection.
    private var nextToken: UInt64 = 0

    /// The leases whose supervisor the daemon starts, reconnects to, or waits for.
    private var connecting: Set<LeaseID> = []

    /// The leases whose unresponsive supervisor the daemon ends by signal.
    private var terminating: Set<LeaseID> = []

    /// The leases whose clone the daemon deletes.
    private var discarding: Set<LeaseID> = []

    /// The background tasks that accept clients and tick.
    private var loops: [Task<Void, Never>] = []

    /// Whether ``shutdown()`` ran, after which the daemon ignores events.
    private var isShutDown = false

    /// Whether the last write of the state file succeeded.
    private var isStateSaved = true

    /// The phase of each lease when the daemon last logged it.
    ///
    /// Clients receive only the changes of their own leases, so the log follows the ledger
    /// instead and also covers detached leases.
    private var loggedPhases: [LeaseID: LeasePhase] = [:]

    /// The wait between checks of a lock and between connection attempts.
    private static let pollInterval = Duration.milliseconds(100)

    /// Takes the data directory's lock and reads the stored leases.
    ///
    /// A malformed state file moves aside with an `.invalid-` suffix and the time, and the daemon
    /// starts without leases. ``start()`` then stops the supervisors and deletes the clones that
    /// belong to no lease. A state file in a format version that this build does not read, or one
    /// that cannot be opened, stops the daemon instead and keeps every lease for a daemon that can
    /// read it. A version 1 file from an earlier build loads with the local user as every lease's
    /// owner.
    ///
    /// - Parameter configuration: The settings and collaborators.
    /// - Throws: ``PoolError/daemonRunning(path:)`` when another daemon serves the directory,
    ///   ``PoolError/invalidRequest(reason:)`` when the policy's slot count is out of range,
    ///   ``PoolError/insecureDirectory(path:reason:)`` when another user could control the
    ///   directory, ``PoolError/unsupportedStateVersion(path:version:)`` when the state file has a
    ///   format version that this build does not read, or another ``PoolError`` when the directory
    ///   or the state file cannot be used.
    public init(configuration: Configuration) throws(PoolError) {
        guard (1 ... PoolPolicy.maximumSlots).contains(configuration.policy.slots) else {
            throw .invalidRequest(reason: "the daemon takes 1 to \(PoolPolicy.maximumSlots) slots")
        }
        try configuration.directory.prepare()
        lock = try DaemonLock(directory: configuration.directory)
        store = PoolStore(file: configuration.directory.stateFile)
        let state: PoolState
        do {
            state = try store.load()
        } catch let .invalidState(path, reason) {
            let moved = try store.quarantine(at: Date())
            configuration.logger.error("The pool state is unusable and starts empty", metadata: [
                "path": "\(path)",
                "reason": "\(reason)",
                "moved_to": "\(moved.path(percentEncoded: false))",
            ])
            state = .empty
        } catch {
            throw error
        }
        ledger = LeaseLedger(policy: configuration.policy, directory: configuration.directory, state: state)
        self.configuration = configuration
        loggedPhases = ledger.leases.mapValues(\.phase)
    }

    /// Resumes the stored leases and starts accepting clients.
    ///
    /// - Throws: ``PoolError`` when the client socket cannot listen.
    public func start() async throws(PoolError) {
        removeOrphans()
        pruneLogs()
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
                await self?.accept(channel, owner: .local)
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
        if let peers = configuration.peers {
            loops.append(Task { [weak self] in
                while !Task.isCancelled {
                    switch await self?.openPeerListener(peers) ?? .stopped {
                    case let .listening(listener):
                        for await peer in listener.connections {
                            await self?.acceptPeer(peer)
                        }
                        await self?.peerListenerStopped(listener)
                    case .failed:
                        break
                    case .stopped:
                        return
                    }
                    try? await Task.sleep(for: peers.retryInterval)
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
        peerListener?.close()
        peerListener = nil
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

    /// Writes the state, applies expiries, restart times, and the reattach grace, signals
    /// supervisors that ignore a stop, and retries unfinished stops and clean-ups.
    public func tick() {
        guard !isShutDown else {
            return
        }
        let now = configuration.now()
        perform(ledger.tick(now: now))
        let stopGrace = configuration.stopGrace / .seconds(1)
        for (id, record) in ledger.leases.sorted(by: { $0.key < $1.key }) {
            let idle = links[id] == nil && !connecting.contains(id)
            switch record.phase {
            case .stopping:
                if let link = links[id], link.stopSentAt == nil {
                    // The stop waited for a write of the state.
                    stopMachine(id)
                } else if let sent = links[id]?.stopSentAt, now.timeIntervalSince(sent) >= stopGrace,
                          !terminating.contains(id) {
                    terminating.insert(id)
                    Task { await self.terminateUnresponsive(id) }
                } else if idle, !discarding.contains(id) {
                    startDiscard(id)
                }
            case .starting, .ready:
                // A supervisor that could not be ended earlier gets another attempt.
                if idle {
                    startRecovery(id)
                }
            case .restarting:
                break
            }
        }
    }

    /// Describes the pool.
    ///
    /// - Returns: The slots, leases, and queue, as the local user sees them.
    public func summary() -> PoolSummary {
        ledger.summary(for: .local)
    }

    // MARK: Clients

    /// Registers a new client and serves its requests.
    ///
    /// - Parameters:
    ///   - channel: The client's connection.
    ///   - owner: Who the client acts for, which the caller established for the connection.
    func accept(_ channel: MessageChannel, owner: LeaseOwner) {
        guard !isShutDown else {
            channel.close()
            return
        }
        let client = ClientID(value: nextClient)
        nextClient += 1
        clients[client] = channel
        Task { await self.serve(client, owner: owner, on: channel) }
    }

    /// Starts the listener for paired Macs, loading this Mac's key first.
    ///
    /// A failure is logged once until its reason changes or the listener starts.
    ///
    /// - Parameter settings: The address, the port, and the trusted keys.
    /// - Returns: The listener, ``PeerListenerAttempt/failed`` when the key or the port failed, or
    ///   ``PeerListenerAttempt/stopped`` after ``shutdown()``.
    private func openPeerListener(_ settings: PeerSettings) async -> PeerListenerAttempt {
        guard !isShutDown else {
            return .stopped
        }
        let started: PeerListener
        do throws(PoolError) {
            let identity = try MacIdentity.loadOrCreate(in: configuration.directory)
            started = try await PeerListener(identity: identity, settings: settings)
        } catch {
            if peerListenerFailure != error.description {
                peerListenerFailure = error.description
                configuration.logger.error("The listener for paired Macs cannot start", metadata: [
                    "reason": "\(error)",
                ])
            }
            return .failed
        }
        guard !isShutDown else {
            started.close()
            return .stopped
        }
        peerListener = started
        peerListenerFailure = nil
        configuration.logger.info("Listening for paired Macs", metadata: [
            "address": "\(settings.address)",
            "port": "\(started.port)",
        ])
        return .listening(started)
    }

    /// Forgets a listener for paired Macs that stopped accepting connections.
    ///
    /// - Parameter stopped: The listener whose connections ended.
    private func peerListenerStopped(_ stopped: PeerListener) {
        guard !isShutDown, peerListener === stopped else {
            return
        }
        stopped.close()
        peerListener = nil
        configuration.logger.error("The listener for paired Macs stopped")
    }

    /// Greets a paired Mac and serves its requests as the owner of its key.
    ///
    /// - Parameter peer: A connection whose handshake proved a trusted key.
    private func acceptPeer(_ peer: PeerListener.Peer) {
        guard !isShutDown else {
            peer.channel.close()
            return
        }
        try? peer.channel.send(HostGreeting(version: peer.version, role: .host))
        configuration.logger.info("A paired Mac connected", metadata: [
            "key": "\(peer.fingerprint)",
            "address": "\(peer.channel.peer)",
        ])
        accept(peer.channel, owner: .client(peer.fingerprint))
    }

    /// The port on which the daemon listens for paired Macs, or `nil` while it does not listen.
    var peerPort: UInt16? {
        peerListener?.port
    }

    /// Reads a client's requests until it disconnects.
    ///
    /// - Parameters:
    ///   - client: The client.
    ///   - owner: Who the client acts for.
    ///   - channel: The client's connection.
    private func serve(_ client: ClientID, owner: LeaseOwner, on channel: MessageChannel) async {
        while true {
            let request: PoolRequest?
            do {
                request = try await channel.receive(PoolRequest.self)
            } catch {
                // The reply must leave before the connection closes, or the client sees only the
                // closed connection.
                try? channel.send(PoolReply.failure(error.description))
                await channel.finish()
                break
            }
            guard let request, !isShutDown else {
                break
            }
            handle(request, from: client, owner: owner)
            // Reading on only after the replies left keeps a client that stops reading from
            // queueing replies without end.
            await channel.delivered()
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
    ///   - owner: Who the client acts for.
    private func handle(_ request: PoolRequest, from client: ClientID, owner: LeaseOwner) {
        do throws(PoolError) {
            switch request {
            case let .lease(terms):
                let admitted = try admit(terms, from: owner)
                configuration.logger.info("Queued a lease request", metadata: [
                    "source": "\(admitted.source)",
                    "owner": "\(owner)",
                ])
                perform(ledger.request(admitted, from: client, owner: owner, now: configuration.now()))
            case let .attach(id):
                try perform(ledger.attach(id, client: client, owner: owner))
            case let .release(id):
                try perform(ledger.release(id, owner: owner, reason: "released by a client"))
                reply(.released(id), to: client)
            case let .renew(id):
                let summary = try ledger.renew(id, owner: owner, now: configuration.now())
                perform([])
                reply(.renewed(summary), to: client)
            case .status:
                reply(.status(ledger.summary(for: owner)), to: client)
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

    /// Applies an owner's limits to a lease request and checks that it can serve a lease.
    ///
    /// A paired client's source is a name from ``Configuration/offeredSources``, which becomes
    /// the bundle's path. A paired client may not share a host directory, because the guest
    /// would reach the host's files through it. Its priority may not exceed the default of 0.
    /// Requests of equal priority wait in arrival order, so the local user gets ahead of a paired
    /// client only with a higher priority.
    ///
    /// - Parameters:
    ///   - terms: The requested terms.
    ///   - owner: Who requests the lease.
    /// - Returns: The terms with the source's path.
    /// - Throws: ``PoolError/invalidRequest(reason:)`` when a paired client names a source that
    ///   the host does not offer, asks for a shared directory, or asks for a priority above 0,
    ///   or the errors of ``LeaseTerms/validate()`` and ``checkSource(of:)``.
    private func admit(_ terms: LeaseTerms, from owner: LeaseOwner) throws(PoolError) -> LeaseTerms {
        var terms = terms
        if case .client = owner {
            guard terms.sharedDirectory == nil else {
                throw .invalidRequest(reason: "a paired client cannot share a host directory")
            }
            guard terms.priority <= 0 else {
                throw .invalidRequest(reason: "a paired client cannot ask for a priority above 0")
            }
            guard let path = configuration.offeredSources[terms.source] else {
                throw .invalidRequest(reason: "the host offers no source named \(terms.source)")
            }
            terms.source = path
        }
        try terms.validate()
        try checkSource(of: terms)
        return terms
    }

    /// Checks that a request's source and shared directory can serve a lease.
    ///
    /// A request that fails these checks would only fail its boots, so it is refused before it
    /// takes a place in the queue.
    ///
    /// - Parameter terms: The requested terms.
    /// - Throws: ``PoolError/library(_:)`` when the source's settings cannot be read, its own
    ///   credential rotation did not finish, or another process holds it, or
    ///   ``PoolError/invalidRequest(reason:)`` when the source never booted, lies on another
    ///   volume than the data directory, or the shared directory is missing.
    private func checkSource(of terms: LeaseTerms) throws(PoolError) {
        let source = terms.source
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
        guard settings.hasBooted != false else {
            throw .invalidRequest(reason: "the source \(source) never booted, so its clones have no guest account")
        }
        guard !BundleLock.isHeld(on: bundle) else {
            throw .library(.bundleInUse(path: source))
        }
        let manager = FileManager.default
        let sourceVolume = try? manager.attributesOfItem(atPath: source)[.systemNumber] as? Int
        let poolVolume = try? manager.attributesOfItem(
            atPath: configuration.directory.leasesDirectory.path(percentEncoded: false),
        )[.systemNumber] as? Int
        guard sourceVolume == poolVolume else {
            throw .invalidRequest(
                reason: "the source \(source) is not on the data directory's volume, so it cannot be cloned",
            )
        }
        if let shared = terms.sharedDirectory {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: shared, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw .invalidRequest(reason: "the shared directory \(shared) does not exist")
            }
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
            isStateSaved = true
        } catch {
            isStateSaved = false
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
                startRecovery(id)
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
                    "owner": "\(record.owner)",
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

    /// Waits for the lease's earlier supervisor, prepares the clone, starts the supervisor, and
    /// connects to it.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - terms: The lease's terms.
    private func launch(_ id: LeaseID, terms: LeaseTerms) async {
        let directory = configuration.directory
        // An earlier supervisor writes its exit record and closes its socket before it releases
        // its lock. Its files are therefore final once the lock is free, and only then can they go.
        let earlier = await endSupervisor(id, waitingFirst: configuration.releaseTimeout)
        guard !isShutDown else {
            return
        }
        if case .stuck = earlier {
            connecting.remove(id)
            configuration.logger.error("An earlier supervisor of a lease does not exit", metadata: ["lease": "\(id)"])
            return
        }
        // The lease may have ended while the daemon waited for the earlier supervisor. A deferred
        // ending also arrives here, because only an ending lease defers its stop.
        guard ledger.leases[id]?.phase == .starting else {
            connecting.remove(id)
            if ledger.leases[id]?.phase == .stopping {
                startDiscard(id)
            }
            return
        }
        try? FileManager.default.removeItem(at: directory.exitRecord(for: id))
        try? FileManager.default.removeItem(at: directory.supervisorSocket(for: id))
        do {
            try prepareClone(id, terms: terms)
        } catch {
            connecting.remove(id)
            let actions = ledger.bootFailed(id, reason: error.description)
            perform(actions.isEmpty ? [.discard(id)] : actions)
            return
        }
        let processID: Int32
        do {
            processID = try await configuration.launcher.launch(SupervisorLaunch(
                lease: id,
                directory: directory,
                sharedDirectory: terms.sharedDirectory,
                sharedDirectoryIsReadOnly: terms.sharedDirectoryIsReadOnly,
                bootTimeout: terms.bootTimeout,
            ))
        } catch {
            connecting.remove(id)
            perform(ledger.machineExited(id, .failed(error.description), now: configuration.now()))
            return
        }
        guard !isShutDown else {
            return
        }
        ledger.supervisorLaunched(id, processID: processID)
        perform([])
        if let channel = await connectToNewSupervisor(of: id) {
            connecting.remove(id)
            attach(channel, to: id)
            return
        }
        let reason = "the supervisor did not listen within \(configuration.supervisorConnectTimeout)"
        await conclude(id, ending: endSupervisor(id, waitingFirst: .zero), reason: reason)
    }

    /// Creates the lease's clone unless a usable one exists.
    ///
    /// The copy happens under a temporary name and takes the lease's name only once it has its own
    /// identity. A clone whose credential rotation began and did not finish holds credentials that
    /// nothing can use, so the boot starts from a fresh clone instead. A clone from an earlier boot
    /// keeps the guest's disk otherwise.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - terms: The lease's terms.
    /// - Throws: ``PoolError`` when the old clone cannot be removed, or the source is in use or
    ///   cannot be cloned.
    private func prepareClone(_ id: LeaseID, terms: LeaseTerms) throws(PoolError) {
        let manager = FileManager.default
        let clone = configuration.directory.bundle(for: id)
        if manager.fileExists(atPath: clone.root.path(percentEncoded: false)) {
            if let settings = try? clone.settings(), settings.credentialRotation != .started {
                return
            }
            do {
                try manager.removeItem(at: clone.root)
            } catch {
                throw .fileSystem("removing the unusable clone", clone.root, error)
            }
        }
        let partial = configuration.directory.partialBundle(for: id)
        try? manager.removeItem(at: partial)
        let source = VMBundle(root: URL(filePath: terms.source))
        do throws(MacpoolError) {
            let sourceLock = try BundleLock(bundle: source)
            defer { withExtendedLifetime(sourceLock) {} }
            let cloned = try source.clone(to: partial)
            do {
                try cloned.assignIdentity()
            } catch {
                try? manager.removeItem(at: partial)
                throw error
            }
        } catch {
            throw .library(error)
        }
        do {
            try manager.moveItem(at: partial, to: clone.root)
        } catch {
            try? manager.removeItem(at: partial)
            throw .fileSystem("naming the clone", clone.root, error)
        }
    }

    /// Connects to a new supervisor's socket, retrying until it listens.
    ///
    /// - Parameter id: The lease.
    /// - Returns: The connection, or `nil` when the supervisor exited before it listened or did
    ///   not listen within the configured timeout.
    private func connectToNewSupervisor(of id: LeaseID) async -> MessageChannel? {
        let directory = configuration.directory
        let socket = directory.supervisorSocket(for: id)
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.supervisorConnectTimeout
        while !isShutDown {
            if let channel = try? await MessageChannel.connect(to: socket, timeout: .seconds(2)) {
                return channel
            }
            // The daemon removed the earlier record before the launch, so a record now belongs to
            // this boot. It is final once the lock is free.
            let record = directory.exitRecord(for: id).path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: record), SupervisorLock.holder(of: id, in: directory) == nil {
                return nil
            }
            guard clock.now < deadline else {
                return nil
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return nil
    }

    /// Starts to reconnect to a lease's supervisor unless a connection or an attempt exists.
    ///
    /// - Parameter id: The lease.
    private func startRecovery(_ id: LeaseID) {
        guard ledger.leases[id] != nil, !connecting.contains(id), links[id] == nil else {
            return
        }
        connecting.insert(id)
        Task { await self.recover(id) }
    }

    /// Reconnects to a lease's supervisor, or concludes its run once the supervisor is gone.
    ///
    /// The supervisor sends its current status to every new connection, so a reconnect loses
    /// nothing. A supervisor that holds its lock but does not answer within the reconnect window
    /// is stopped by command or signal, and its run counts as a failure.
    ///
    /// - Parameter id: The lease.
    private func recover(_ id: LeaseID) async {
        let directory = configuration.directory
        let socket = directory.supervisorSocket(for: id)
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.reconnectWindow
        while !isShutDown {
            if SupervisorLock.holder(of: id, in: directory) == nil {
                await conclude(id, ending: .exited, reason: "")
                return
            }
            if let channel = try? await MessageChannel.connect(to: socket, timeout: .seconds(2)) {
                connecting.remove(id)
                if links[id] == nil {
                    configuration.logger.info("Reconnected to a supervisor", metadata: ["lease": "\(id)"])
                    attach(channel, to: id)
                } else {
                    channel.close()
                }
                return
            }
            guard clock.now < deadline else {
                break
            }
            try? await Task.sleep(for: Self.pollInterval * 5)
        }
        guard !isShutDown else {
            return
        }
        configuration.logger.warning("A running supervisor does not answer", metadata: ["lease": "\(id)"])
        let reason = "the supervisor did not answer within \(configuration.reconnectWindow)"
        await conclude(id, ending: endSupervisor(id, waitingFirst: .zero), reason: reason)
    }

    /// Applies the end of a supervisor's run to the ledger.
    ///
    /// A supervisor that the daemon had to stop counts as failed, because a stop that the daemon
    /// sent for its own reasons does not mean that the lease ended. A supervisor that is stuck or
    /// deferred leaves the lease as it is, and a later tick tries again.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - ending: How the supervisor ended.
    ///   - reason: Why the daemon stopped the supervisor, for ``SupervisorEnding/endedByDaemon``.
    private func conclude(_ id: LeaseID, ending: SupervisorEnding, reason: String) async {
        connecting.remove(id)
        guard !isShutDown, ledger.leases[id] != nil else {
            return
        }
        let outcome: MachineOutcome
        switch ending {
        case .exited:
            outcome = configuration.directory.readExitRecord(for: id) ?? .lost
        case .endedByDaemon:
            outcome = .failed(reason)
        case .stuck, .deferred:
            if let message = ending.stuckMessage {
                configuration.logger.error(message, metadata: ["lease": "\(id)"])
            }
            return
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
    /// A connection that ends without an exited status leads to a reconnect, because the
    /// supervisor may still run. A status from another protocol version, or one that cannot be
    /// read, ends the supervisor by signal.
    ///
    /// - Parameters:
    ///   - channel: The supervisor connection.
    ///   - id: The lease.
    ///   - token: The connection's token.
    private func follow(_ channel: MessageChannel, of id: LeaseID, token: UInt64) async {
        var exited = false
        var incompatibility: String?
        while true {
            let status: SupervisorStatus?
            do {
                status = try await channel.receive(SupervisorStatus.self)
            } catch {
                incompatibility = error.description
                break
            }
            guard let status else {
                break
            }
            guard !isShutDown, links[id]?.token == token else {
                channel.close()
                return
            }
            guard status.protocolVersion == SupervisorStatus.currentProtocol else {
                incompatibility = "protocol \(status.protocolVersion) instead of \(SupervisorStatus.currentProtocol)"
                break
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
        if let incompatibility {
            configuration.logger.warning("A supervisor is incompatible", metadata: [
                "lease": "\(id)",
                "reason": "\(incompatibility)",
            ])
            connecting.insert(id)
            let reason = "the supervisor is incompatible: \(incompatibility)"
            await conclude(id, ending: endSupervisor(id, waitingFirst: .zero), reason: reason)
            return
        }
        configuration.logger.warning("A supervisor connection ended", metadata: ["lease": "\(id)"])
        startRecovery(id)
    }

    /// Asks a lease's supervisor to stop the VM once the state file records the lease as stopping.
    ///
    /// A lease without a connection either has a launch or a reconnect under way, which sends the
    /// stop once it connects, or gets a reconnect now. The reconnect concludes the run when the
    /// supervisor is gone.
    ///
    /// - Parameter id: The lease.
    private func stopMachine(_ id: LeaseID) {
        guard !isStopDeferred(id) else {
            return
        }
        if var link = links[id] {
            try? link.channel.send(SupervisorCommand(.stop))
            link.stopSentAt = configuration.now()
            links[id] = link
        } else {
            startRecovery(id)
        }
    }

    /// Reports whether an ending lease's supervisor must keep running until a write of the state.
    ///
    /// A daemon that restarts after a failed write reads the lease as running. It would apply the
    /// restart policy to the stopped VM and could boot a released lease again. The daemon
    /// therefore neither stops nor signals the supervisor of a stopping lease until a write
    /// succeeds. The tick after that write sends the stop or starts the clone's deletion, which
    /// ends the supervisor.
    ///
    /// - Parameter id: The lease.
    /// - Returns: Whether the lease is stopping and the last write of the state failed.
    private func isStopDeferred(_ id: LeaseID) -> Bool {
        !isStateSaved && ledger.leases[id]?.phase == .stopping
    }

    /// Ends a supervisor that did not stop within the stop grace period.
    ///
    /// The connection to the supervisor ends with the process, and following it concludes the
    /// run.
    ///
    /// - Parameter id: The lease.
    private func terminateUnresponsive(_ id: LeaseID) async {
        configuration.logger.warning("A supervisor ignores its stop", metadata: ["lease": "\(id)"])
        if let message = await endSupervisor(id, waitingFirst: .zero).stuckMessage {
            configuration.logger.error(message, metadata: ["lease": "\(id)"])
        }
        terminating.remove(id)
    }

    /// Waits for a lease's supervisor to exit and ends it when it does not.
    ///
    /// After the first wait the daemon sends a stop command on the socket, then `SIGTERM`, then
    /// `SIGKILL`, and waits ``Configuration/signalGrace`` after each step. Other requests run during
    /// these waits, so the lease can end in the meantime. Each step therefore checks
    /// ``isStopDeferred(_:)`` first and leaves the supervisor running while it holds.
    ///
    /// A signal goes only to a process that the launcher identifies as the lease's supervisor.
    /// Each signal that the daemon withholds logs the launcher's reason.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - wait: The wait for the supervisor to exit on its own.
    /// - Returns: How the supervisor ended, or ``SupervisorEnding/deferred`` when it keeps running
    ///   until a write of the state.
    private func endSupervisor(_ id: LeaseID, waitingFirst wait: Duration) async -> SupervisorEnding {
        let directory = configuration.directory
        if await waitForSupervisorExit(of: id, within: wait) {
            return .exited
        }
        guard !isStopDeferred(id) else {
            return .deferred
        }
        let socket = directory.supervisorSocket(for: id)
        if let channel = try? await MessageChannel.connect(to: socket, timeout: .seconds(2)) {
            guard !isStopDeferred(id) else {
                channel.close()
                return .deferred
            }
            try? channel.send(SupervisorCommand(.stop))
            await channel.finish()
            if await waitForSupervisorExit(of: id, within: configuration.signalGrace) {
                return .endedByDaemon
            }
        }
        var killSent = false
        for signal in [SupervisorSignal.terminate, .kill] {
            guard !isStopDeferred(id) else {
                return .deferred
            }
            // The lock records the process that holds it, which covers a supervisor whose launch
            // the daemon could not store. The state's identifier has no start time, so its
            // arguments alone identify it unless the lock holds a malformed record.
            let record = SupervisorLock.holder(of: id, in: directory)
            let recorded = record?.processID ?? 0
            let processID = recorded > 0 ? recorded : ledger.leases[id]?.supervisorProcessID ?? 0
            let startTime = record?.startTime ?? .absent
            do {
                try await configuration.launcher.identify(
                    processID: processID,
                    startTime: startTime,
                    of: id,
                    in: directory,
                )
                // The check of the process suspends, so the lease may have ended meanwhile.
                guard !isStopDeferred(id) else {
                    return .deferred
                }
                configuration.logger.warning("Signaling a supervisor", metadata: [
                    "lease": "\(id)",
                    "pid": "\(processID)",
                    "signal": "\(signal)",
                ])
                configuration.launcher.send(signal, to: processID, of: id, in: directory)
                killSent = signal == .kill
            } catch {
                configuration.logger.warning("A process is not the lease's supervisor", metadata: [
                    "lease": "\(id)",
                    "pid": "\(processID)",
                    "signal": "\(signal)",
                    "reason": "\(error)",
                ])
            }
            if await waitForSupervisorExit(of: id, within: configuration.signalGrace) {
                return .endedByDaemon
            }
        }
        return .stuck(killSent: killSent)
    }

    /// Waits until no process holds a lease's supervisor lock.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - wait: The longest wait. A zero wait checks once.
    /// - Returns: Whether the lock is free.
    private func waitForSupervisorExit(of id: LeaseID, within wait: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + wait
        while SupervisorLock.holder(of: id, in: configuration.directory) != nil {
            guard clock.now < deadline else {
                return false
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return true
    }

    // MARK: Clean-up

    /// Starts deleting a lease's clone unless that is under way or the state file is out of date.
    ///
    /// A clone goes only after the state file records its lease as stopping. Otherwise a daemon
    /// that restarts after a failed write would find the lease running without a clone and boot it
    /// again. Every tick writes the state, and a tick after a successful write starts the deletion.
    ///
    /// - Parameter id: The lease.
    private func startDiscard(_ id: LeaseID) {
        guard isStateSaved, !discarding.contains(id) else {
            return
        }
        discarding.insert(id)
        Task { await self.discard(id) }
    }

    /// Deletes a lease's clone and files once its supervisor exited, and frees the slot.
    ///
    /// A supervisor that still runs after the release timeout is stopped by command or signal.
    /// When it survives that, another process holds the clone, or a failed write of the state
    /// defers the stop, the lease stays stopping and a later tick tries again.
    ///
    /// - Parameter id: The lease.
    private func discard(_ id: LeaseID) async {
        let directory = configuration.directory
        let clone = directory.bundle(for: id)
        switch await endSupervisor(id, waitingFirst: configuration.releaseTimeout) {
        case .exited, .endedByDaemon:
            break
        case .stuck:
            discarding.remove(id)
            configuration.logger.error("A stopped lease's supervisor does not exit", metadata: ["lease": "\(id)"])
            return
        case .deferred:
            discarding.remove(id)
            return
        }
        guard await waitForRelease(of: clone) else {
            discarding.remove(id)
            configuration.logger.error("A stopped lease's clone is still in use", metadata: ["lease": "\(id)"])
            return
        }
        do {
            try removeFiles(of: id)
        } catch {
            discarding.remove(id)
            configuration.logger.error("A stopped lease's clone could not be deleted", metadata: [
                "lease": "\(id)",
                "error": "\(error)",
            ])
            return
        }
        discarding.remove(id)
        links[id] = nil
        guard !isShutDown else {
            return
        }
        perform(ledger.discarded(id, now: configuration.now()))
        pruneLogs()
    }

    /// Deletes a lease's clone, partial clone, socket, exit record, and supervisor lock.
    ///
    /// The supervisor log stays for ``Configuration/logRetention``.
    ///
    /// - Parameter id: The lease, whose supervisor must have exited.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the clone cannot be deleted.
    private func removeFiles(of id: LeaseID) throws(PoolError) {
        let directory = configuration.directory
        let manager = FileManager.default
        for clone in [directory.bundle(for: id).root, directory.partialBundle(for: id)]
            where manager.fileExists(atPath: clone.path(percentEncoded: false)) {
            do {
                try manager.removeItem(at: clone)
            } catch {
                throw .fileSystem("deleting the clone", clone, error)
            }
        }
        try? manager.removeItem(at: directory.supervisorSocket(for: id))
        try? manager.removeItem(at: directory.exitRecord(for: id))
        try? manager.removeItem(at: directory.supervisorLock(for: id))
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

    /// Stops supervisors and deletes clones and run files that belong to no stored lease.
    ///
    /// They remain when the daemon stopped between writing them and recording the lease, or when
    /// an unusable state file was set aside. A supervisor that still runs gets a stop, and its
    /// files go once it exited. Partial clones always go, because only a running daemon writes
    /// them. Entries whose names are not lease identifiers stay untouched.
    private func removeOrphans() {
        let directory = configuration.directory
        let manager = FileManager.default
        var orphans: Set<LeaseID> = []
        let names = [directory.leasesDirectory, directory.runDirectory].flatMap { folder in
            (try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        }
        for name in names {
            let stem = name.split(separator: ".").first.map(String.init) ?? ""
            guard let id = LeaseID(stem) else {
                continue
            }
            if ledger.leases[id] == nil {
                orphans.insert(id)
            } else if name.hasSuffix(".partial") {
                try? manager.removeItem(at: directory.partialBundle(for: id))
            }
        }
        for id in orphans.sorted() {
            if SupervisorLock.holder(of: id, in: directory) == nil {
                removeOrphan(id)
            } else {
                configuration.logger.notice("Stopping a supervisor without a lease", metadata: ["lease": "\(id)"])
                Task {
                    if await self.endSupervisor(id, waitingFirst: .zero).hasEnded {
                        self.removeOrphan(id)
                    }
                }
            }
        }
    }

    /// Deletes the files of a lease that the ledger does not know, unless another process holds
    /// its clone.
    ///
    /// - Parameter id: The unknown lease.
    private func removeOrphan(_ id: LeaseID) {
        guard ledger.leases[id] == nil, !BundleLock.isHeld(on: configuration.directory.bundle(for: id)) else {
            return
        }
        configuration.logger.notice("Removing files without a lease", metadata: ["lease": "\(id)"])
        try? removeFiles(of: id)
    }

    /// Deletes supervisor logs of leases that ended longer ago than the retention period.
    private func pruneLogs() {
        let manager = FileManager.default
        let folder = configuration.directory.logsDirectory
        let cutoff = Date().addingTimeInterval(-(configuration.logRetention / .seconds(1)))
        for name in (try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] {
            guard name.hasSuffix(".log"), let id = LeaseID(String(name.dropLast(4))), ledger.leases[id] == nil else {
                continue
            }
            let file = folder.appending(path: name)
            let modified = try? manager.attributesOfItem(atPath: file.path(percentEncoded: false))[.modificationDate]
            if let modified = modified as? Date, modified < cutoff {
                try? manager.removeItem(at: file)
            }
        }
    }
}
