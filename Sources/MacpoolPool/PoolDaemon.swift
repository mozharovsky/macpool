public import Foundation
public import Logging
import MacpoolVM
import Synchronization

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
/// directory or ask for a priority above the ceiling in its record. At most ``PoolPolicy/slots``
/// of its requests wait in the queue at once. No reply to a paired client names a host path.
///
/// The daemon reads a paired client's record again before each of its requests. If the record is
/// gone or blocked, the daemon refuses the request and closes the connection. If the list cannot
/// be read, the daemon refuses only the request. A revocation blocks the record and closes the
/// client's connections at once.
///
/// With ``Configuration/peers`` set, the daemon also listens on TCP for paired Macs. It loads this
/// Mac's key only then. A key or a list of paired clients that cannot be loaded, or a port that
/// another process holds, leaves the local socket serving, and the daemon tries again later. A
/// paired Mac proves its key in a TLS handshake, receives a greeting with the protocol version,
/// and then exchanges the same lines as a local client.
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
        ///
        /// The daemon replaces every reply to a paired client that names a host path. A name
        /// therefore has no `/`. Otherwise a name could hold a path, and every reply about its
        /// source would fail.
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

    /// A connected client and the owner it acts for.
    private struct ClientConnection {
        /// The client's connection.
        let channel: MessageChannel
        /// Who the client acts for.
        let owner: LeaseOwner
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
        /// The key, the list of paired clients, or the port failed, and a later attempt may
        /// succeed.
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

    /// The most connections that one paired Mac may have at once.
    ///
    /// Each connection queues up to 4 MiB of replies. The limit bounds the memory that one Mac
    /// can hold this way.
    static let connectionsPerPeer = 4

    /// The most connections of Macs that pair at once.
    ///
    /// While an invitation is open, any key passes the handshake. The limit bounds the connections
    /// that such keys hold.
    static let pairingConnectionLimit = 4

    /// The longest wait for the one request of a Mac that pairs.
    static let pairingTimeout = Duration.seconds(5)

    /// The open invitation for a client Mac to pair, if any.
    private let invitation = PairingInvitation()

    /// The connections of Macs that pair.
    private var pairingConnections = 0

    /// The levels of the log lines that Macs on the network can repeat.
    private var peerLogRate = PeerLogRate()

    /// The keys of revoked Macs whose block the daemon could not save.
    ///
    /// The daemon refuses these keys like blocked records until it restarts. It removes a key
    /// when a later revocation saves the block. It also removes the key when a person deletes the
    /// Mac's record and the Mac pairs again with a new code.
    private(set) var unsavedBlocks: Set<KeyFingerprint> = []

    /// The connected clients.
    private var clients: [ClientID: ClientConnection] = [:]

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
    ///   ``PoolError/invalidRequest(reason:)`` when the policy's slot count is out of range or an
    ///   offered source has a name with `/` or a path that is not absolute,
    ///   ``PoolError/insecureDirectory(path:reason:)`` when another user could control the
    ///   directory, ``PoolError/unsupportedStateVersion(path:version:)`` when the state file has a
    ///   format version that this build does not read, or another ``PoolError`` when the directory
    ///   or the state file cannot be used.
    public init(configuration: Configuration) throws(PoolError) {
        guard (1 ... PoolPolicy.maximumSlots).contains(configuration.policy.slots) else {
            throw .invalidRequest(reason: "the daemon takes 1 to \(PoolPolicy.maximumSlots) slots")
        }
        for (name, path) in configuration.offeredSources {
            // A slash and a combining mark after it form one Character. The check therefore reads
            // bytes.
            guard !name.utf8.contains(UInt8(ascii: "/")) else {
                throw .invalidRequest(reason: "the offered source \"\(name)\" needs a name without \"/\"")
            }
            guard path.hasPrefix("/") else {
                throw .invalidRequest(reason: "the offered source \"\(name)\" needs an absolute path")
            }
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
        for client in clients.values {
            client.channel.close()
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
        if let expired = invitation.expire(at: now) {
            invitationEnded(expired)
            reply(.failure("the invitation expired"), to: expired.inviter)
        }
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
    /// - Returns: The slots, leases, queue, and images, as the local user sees them.
    public func summary() -> PoolSummary {
        var summary = ledger.summary(for: .local)
        summary.images = configuration.directory.images()
        return summary
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
        clients[client] = ClientConnection(channel: channel, owner: owner)
        Task { await self.serve(client, owner: owner, on: channel) }
    }

    /// Starts the listener for paired Macs, loading this Mac's key and the list of paired clients
    /// first.
    ///
    /// A failure is logged once until its reason changes or the listener starts.
    ///
    /// - Parameter settings: The address and the port.
    /// - Returns: The listener, ``PeerListenerAttempt/failed`` when the key, the list, or the port
    ///   failed, or ``PeerListenerAttempt/stopped`` after ``shutdown()``.
    private func openPeerListener(_ settings: PeerSettings) async -> PeerListenerAttempt {
        guard !isShutDown else {
            return .stopped
        }
        let started: PeerListener
        do throws(PoolError) {
            let identity = try MacIdentity.loadOrCreate(in: configuration.directory)
            // A list that cannot be read now would refuse every handshake, so the log says why
            // once instead.
            _ = try TrustList<TrustedClient>.load(from: configuration.directory)
            let clients = ClientListReader(directory: configuration.directory, logger: configuration.logger)
            let invitation = invitation
            let now = configuration.now
            started = try await PeerListener(identity: identity, settings: settings) { key in
                guard let list = clients.read() else {
                    return false
                }
                if let record = list[key] {
                    return !record.isBlocked
                }
                // A Mac that the host does not know gets in only to pair.
                return invitation.isOpen(at: now())
            }
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

    /// Serves a Mac whose handshake succeeded as a paired client or as a Mac that pairs.
    ///
    /// The daemon reads the list of paired clients again, because it may have changed since the
    /// handshake. If the list names the key, the Mac is a paired client unless it is blocked. If
    /// the list does not name the key and an invitation is open, the Mac may pair. The daemon
    /// closes any other connection.
    ///
    /// - Parameter peer: A connection whose handshake proved a key.
    private func acceptPeer(_ peer: PeerListener.Peer) {
        guard !isShutDown, let clients = try? TrustList<TrustedClient>.load(from: configuration.directory) else {
            peer.channel.close()
            return
        }
        if let record = clients[peer.fingerprint] {
            if isBlocked(record) {
                peer.channel.close()
            } else {
                acceptPairedMac(peer)
            }
        } else if invitation.isOpen(at: configuration.now()) {
            acceptPairingMac(peer)
        } else {
            peer.channel.close()
        }
    }

    /// Greets a paired Mac and serves its requests as the owner of its key.
    ///
    /// A Mac that already has ``connectionsPerPeer`` connections gets a failure reply instead of
    /// the greeting, and the daemon closes the new connection.
    ///
    /// - Parameter peer: A connection whose handshake proved the key of a paired client.
    private func acceptPairedMac(_ peer: PeerListener.Peer) {
        let owner = LeaseOwner.client(peer.fingerprint)
        guard clients.values.count(where: { $0.owner == owner }) < Self.connectionsPerPeer else {
            let level = peerLogLevel(of: .tooManyConnections(peer.fingerprint), full: .warning)
            configuration.logger.log(level: level, "A paired Mac has too many connections", metadata: [
                "key": "\(peer.fingerprint)",
                "address": "\(peer.channel.peer)",
            ])
            try? peer.channel.send(PoolReply.failure(
                "this Mac already has \(Self.connectionsPerPeer) connections to the host, the most it may have",
            ))
            Task { await peer.channel.finish() }
            return
        }
        try? peer.channel.send(HostGreeting(version: peer.version, role: .host))
        let level = peerLogLevel(of: .connected(peer.fingerprint), full: .info)
        configuration.logger.log(level: level, "A paired Mac connected", metadata: [
            "key": "\(peer.fingerprint)",
            "address": "\(peer.channel.peer)",
        ])
        accept(peer.channel, owner: owner)
    }

    /// Greets a Mac that may pair and waits for its pairing request.
    ///
    /// If ``pairingConnectionLimit`` Macs already pair, the new one gets a failure reply instead
    /// of the greeting, and the daemon closes its connection.
    ///
    /// - Parameter peer: A connection whose handshake proved a key that the host does not know.
    private func acceptPairingMac(_ peer: PeerListener.Peer) {
        guard pairingConnections < Self.pairingConnectionLimit else {
            let level = peerLogLevel(of: .tooManyPairings, full: .warning)
            configuration.logger.log(level: level, "Too many Macs pair at once", metadata: [
                "key": "\(peer.fingerprint)",
                "address": "\(peer.channel.peer)",
            ])
            try? peer.channel.send(PoolReply.failure("other Macs are pairing with the host, so try again shortly"))
            Task { await peer.channel.finish() }
            return
        }
        pairingConnections += 1
        try? peer.channel.send(HostGreeting(version: peer.version, role: .host))
        // Any key passes the handshake while an invitation is open. Only the outcome of a pairing
        // reaches the info level.
        configuration.logger.debug("A Mac connected to pair", metadata: [
            "key": "\(peer.fingerprint)",
            "address": "\(peer.channel.peer)",
        ])
        Task { await self.servePairing(peer) }
    }

    /// Returns the level of a log line that Macs on the network can repeat.
    ///
    /// - Parameters:
    ///   - line: The kind of line.
    ///   - full: The level of the line when it is due.
    /// - Returns: `full` at most once per ``PeerLogRate/interval`` for the line, or `.debug`.
    private func peerLogLevel(of line: PeerLogLine, full: Logger.Level) -> Logger.Level {
        peerLogRate.level(of: line, full: full, at: configuration.now())
    }

    /// Reads the one request of a Mac that pairs, replies to it, and closes the connection.
    ///
    /// The daemon closes the connection if no request arrives within ``pairingTimeout``. Any
    /// request other than a pairing gets a failure reply.
    ///
    /// - Parameter peer: The connection of a Mac that the host does not know.
    private func servePairing(_ peer: PeerListener.Peer) async {
        let watchdog = Task {
            try await Task.sleep(for: Self.pairingTimeout)
            peer.channel.close()
        }
        let request = try? await peer.channel.receive(PoolRequest.self)
        watchdog.cancel()
        switch request {
        case let .pair(secret, name)?:
            try? peer.channel.send(visible(
                pair(peer.fingerprint, secret: secret, name: name),
                to: .client(peer.fingerprint),
            ))
        case nil:
            break
        default:
            try? peer.channel.send(PoolReply.failure("this Mac is not paired with the host, so it can only pair"))
        }
        await peer.channel.finish()
        pairingConnections -= 1
    }

    /// Checks a pairing request against the open invitation and records a new paired client.
    ///
    /// If the list already names the key, the daemon leaves the record unchanged. A paired Mac
    /// then receives the host again, and a blocked one receives a failure. The daemon reads the
    /// list again here, because the list may have changed since the handshake.
    ///
    /// The reply to the Mac that pairs never names a host path. The inviting connection receives
    /// the client or the reason that the invitation ended. It also receives
    /// ``PoolReply/wrongCode`` after the first wrong secret.
    ///
    /// - Parameters:
    ///   - key: The fingerprint of the key that the Mac proved.
    ///   - secret: The secret from the request.
    ///   - name: The name of the Mac.
    /// - Returns: The reply to the Mac that pairs.
    private func pair(_ key: KeyFingerprint, secret: String, name: String) -> PoolReply {
        guard PairedMac.isValidName(name) else {
            return .failure("the name of this Mac must have \(PairedMac.nameRule)")
        }
        guard let hostKey = peerListener?.hostKey, let hostName = configuration.peers?.name else {
            return .failure("the host stopped listening for Macs")
        }
        // A secret that is not base32 counts as a wrong one.
        let now = configuration.now()
        switch invitation.redeem(Base32.decode(secret) ?? [], at: now) {
        case .closed:
            return .failure("the host has no open invitation, so ask for a new code")
        case let .rejected(inviter, wrongSecrets):
            // One warning per invitation keeps a flood of wrong secrets out of the log.
            if wrongSecrets == 1 {
                configuration.logger.warning("A Mac sent a wrong pairing code", metadata: ["key": "\(key)"])
                reply(.wrongCode, to: inviter)
            }
            return .failure("the pairing code is wrong")
        case let .accepted(ended, priorityCeiling):
            invitationEnded(ended)
            let host = PairedMac(name: hostName, key: hostKey)
            let client = TrustedClient(
                key: key,
                name: name,
                pairedAt: now,
                isBlocked: false,
                priorityCeiling: priorityCeiling,
            )
            return record(client, invitedBy: ended.inviter, host: host)
        }
    }

    /// Records a client whose secret was right and returns the reply to it.
    ///
    /// - Parameters:
    ///   - client: The new record, with the key that the client proved and the invitation's
    ///     priority ceiling.
    ///   - inviter: The connection that opened the invitation.
    ///   - host: This host's name and key.
    /// - Returns: The reply to the client.
    private func record(_ client: TrustedClient, invitedBy inviter: ClientID, host: PairedMac) -> PoolReply {
        let key = client.key
        do throws(PoolError) {
            var clients = try TrustList<TrustedClient>.load(from: configuration.directory)
            if let known = clients[key] {
                guard !isBlocked(known) else {
                    configuration.logger.warning("A blocked Mac used a pairing code", metadata: ["key": "\(key)"])
                    reply(.failure("a blocked Mac used the code and ended the invitation"), to: inviter)
                    return .failure("the host blocked this Mac")
                }
                configuration.logger.info("A paired Mac used a pairing code", metadata: ["key": "\(key)"])
                reply(.alreadyPaired(PairedMac(name: known.name, key: key)), to: inviter)
                return .paired(host)
            }
            clients.insert(client)
            try clients.save(to: configuration.directory)
            // A new code from the host's user ends a block that the daemon kept only in memory.
            unsavedBlocks.remove(key)
        } catch {
            configuration.logger.error("The host cannot record a paired Mac", metadata: [
                "key": "\(key)",
                "reason": "\(error)",
            ])
            reply(.failure("the pairing failed: \(error)"), to: inviter)
            return .failure("the host cannot record the pairing")
        }
        configuration.logger.info("Paired a Mac", metadata: [
            "key": "\(key)",
            "name": "\(client.name)",
            "priority_ceiling": "\(client.priorityCeiling)",
        ])
        reply(.paired(PairedMac(name: client.name, key: key)), to: inviter)
        return .paired(host)
    }

    /// Logs the count of wrong secrets that an invitation received, if any.
    ///
    /// - Parameter ended: The invitation.
    private func invitationEnded(_ ended: PairingInvitation.Ended) {
        guard ended.wrongSecrets > 0 else {
            return
        }
        configuration.logger.warning("An invitation ended after wrong pairing codes", metadata: [
            "count": "\(ended.wrongSecrets)",
        ])
    }

    /// Opens an invitation for the local user.
    ///
    /// - Parameters:
    ///   - address: The host's address for the code.
    ///   - priorityCeiling: The highest priority that the client who pairs may ask for.
    ///   - client: The inviting connection.
    ///   - owner: Who the client acts for.
    /// - Returns: The reply with the code.
    /// - Throws: ``PoolError/invalidRequest(reason:)`` when a paired client invites, the address
    ///   cannot be part of a code, the ceiling is below 0, the daemon does not listen for paired
    ///   Macs, or the host's name for clients is not a valid name or contains a host path.
    private func invite(
        address: String,
        priorityCeiling: Int,
        from client: ClientID,
        owner: LeaseOwner,
    ) throws(PoolError) -> PoolReply {
        guard owner == .local else {
            throw .invalidRequest(reason: "only the host's own user can invite Macs")
        }
        guard PairingCode.isValidAddress(address) else {
            throw .invalidRequest(reason: "\(address) is not a host name or an IP address")
        }
        // A negative ceiling would restrict the client, and a build that does not know the field
        // would ignore it.
        guard priorityCeiling >= 0 else {
            throw .invalidRequest(reason: "the priority ceiling must be 0 or more")
        }
        guard let listener = peerListener else {
            throw .invalidRequest(reason: "the host does not listen for paired Macs"
                + (peerListenerFailure.map { ": \($0)" } ?? ""))
        }
        let hostName = configuration.peers?.name ?? ""
        guard PairedMac.isValidName(hostName) else {
            throw .invalidRequest(reason: "the host's name for clients must have \(PairedMac.nameRule)")
        }
        // Every Mac that pairs receives the host's name. If the name held a host path, the check
        // of the reply would replace it after the host had recorded the Mac.
        guard !namesHostPath([hostName]) else {
            throw .invalidRequest(
                reason: "the host's name for clients contains a path on this Mac. Choose another name",
            )
        }
        let opened = invitation.open(for: client, priorityCeiling: priorityCeiling, at: configuration.now())
        if let replaced = opened.replaced {
            invitationEnded(replaced)
            if replaced.inviter != client {
                reply(.failure("a newer invitation replaced this one"), to: replaced.inviter)
            }
        }
        configuration.logger.info("Opened an invitation", metadata: [
            "address": "\(address)",
            "priority_ceiling": "\(priorityCeiling)",
        ])
        let code = PairingCode(address: address, port: listener.port, hostKey: listener.hostKey, secret: opened.secret)
        return .invitation(code, expiresAt: opened.expiresAt)
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
                // The error may repeat text from the line. If a paired Mac's line held a host path,
                // visible(_:to:) would replace the reply, and the change would confirm the path. A
                // paired Mac therefore gets a fixed reason.
                let reason = owner == .local ? error.description : "the host could not read the request"
                // The reply must leave before the connection closes, or the client sees only the
                // closed connection.
                try? channel.send(PoolReply.failure(reason))
                await channel.finish()
                break
            }
            guard let request, !isShutDown else {
                break
            }
            guard handle(request, from: client, owner: owner) else {
                // A Mac that stops reading would hold delivered() open, and with it the
                // connection. finish(within:) bounds the wait for the last reply.
                await channel.finish()
                break
            }
            // Reading on only after the replies left keeps a client that stops reading from
            // queueing replies without end.
            await channel.delivered()
        }
        channel.close()
        if let closed = invitation.close(for: client) {
            invitationEnded(closed)
        }
        guard !isShutDown, clients.removeValue(forKey: client) != nil else {
            return
        }
        perform(ledger.clientDisconnected(client, now: configuration.now()))
    }

    /// Answers one request.
    ///
    /// Before each request of a paired client, the daemon reads the client's record again,
    /// because the list may have changed since the client connected. If the list no longer names
    /// the client or blocks it, the daemon refuses the request and ends the connection. If the
    /// list cannot be read, the daemon refuses only the request.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - client: The client that sent it.
    ///   - owner: Who the client acts for.
    /// - Returns: Whether the connection stays open for the next request.
    private func handle(_ request: PoolRequest, from client: ClientID, owner: LeaseOwner) -> Bool {
        // A revocation may close the connection after the line arrived.
        guard clients[client] != nil else {
            return false
        }
        var record: TrustedClient?
        if case let .client(key) = owner {
            do throws(PoolError) {
                record = try pairedRecord(key)
            } catch {
                // A person's mistake in the file should not end the attached leases of every Mac.
                reply(.failure(error.description), to: client)
                return true
            }
            guard record != nil else {
                reply(.failure(Self.notAcceptedReason), to: client)
                return false
            }
        }
        do throws(PoolError) {
            switch request {
            case let .lease(terms):
                let admitted = try admit(terms, from: record)
                configuration.logger.info("Queued a lease request", metadata: [
                    "source": "\(admitted.terms.source)",
                    "owner": "\(owner)",
                ])
                perform(ledger.request(
                    admitted.terms,
                    from: client,
                    owner: owner,
                    sourceName: admitted.sourceName,
                    now: configuration.now(),
                ))
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
                var summary = ledger.summary(for: owner)
                // A paired Mac gets no paths on this Mac's disk.
                if owner == .local {
                    summary.images = configuration.directory.images()
                }
                reply(.status(summary), to: client)
            case let .invite(address, priorityCeiling):
                try reply(
                    invite(address: address, priorityCeiling: priorityCeiling, from: client, owner: owner),
                    to: client,
                )
            case let .pair(secret, name):
                guard case let .client(key) = owner else {
                    throw .invalidRequest(reason: "only another Mac can pair with the host")
                }
                reply(pair(key, secret: secret, name: name), to: client)
            case let .revoke(key, endLeases):
                guard owner == .local else {
                    throw .invalidRequest(reason: "only the host's own user can revoke Macs")
                }
                try reply(revoke(key, endLeases: endLeases), to: client)
            }
        } catch {
            reply(.failure(error.description), to: client)
        }
        return true
    }

    /// Blocks a paired Mac, closes its connections, and ends its leases that need a client.
    ///
    /// If `endLeases` is set, the daemon also ends the Mac's detached leases. If the first save of
    /// the block fails, the daemon saves it once more after it closed the connections. If that
    /// save also fails, the daemon keeps the block in ``unsavedBlocks`` and reports the failure.
    ///
    /// If the list cannot be read or has no record of the key, the daemon looks for the key among
    /// the connected Macs and the owners of leases. It closes that Mac's connections and ends its
    /// leases. When the list cannot be read, the daemon also keeps the block in ``unsavedBlocks``.
    /// It reports either case as a failure.
    ///
    /// - Parameters:
    ///   - text: The Mac's short key or full fingerprint.
    ///   - endLeases: Whether the daemon also ends the Mac's detached leases.
    /// - Returns: The reply to the local user.
    /// - Throws: ``PoolError/invalidRequest(reason:)`` when no paired Mac has the key, when a short
    ///   key names more than one Mac, or when the daemon closed the connections without saving a
    ///   block. The errors of ``TrustList/load(from:)`` propagate when no connected Mac or owner of
    ///   a lease has the key.
    private func revoke(_ text: String, endLeases: Bool) throws(PoolError) -> PoolReply {
        let list: TrustList<TrustedClient>
        do throws(PoolError) {
            list = try TrustList<TrustedClient>.load(from: configuration.directory)
        } catch {
            guard let key = activeKey(namedBy: text) else {
                throw error
            }
            let ended = cutOff(key, endLeases: endLeases, reason: Self.revocationReason)
            unsavedBlocks.insert(key)
            logUnblocked(key, ended, reason: "\(error)")
            throw .invalidRequest(reason: "the host closed the Mac's connections, but it cannot read its list of "
                + "paired Macs to block the Mac: \(error). \(Self.revokeAgain)")
        }
        let matches = list.records.filter { $0.key.isNamed(by: text) }
        if matches.isEmpty, let key = activeKey(namedBy: text) {
            let ended = cutOff(key, endLeases: endLeases, reason: Self.revocationReason)
            logUnblocked(key, ended, reason: "the list has no record of the key")
            throw .invalidRequest(reason: "the host closed the Mac's connections, but its list of paired Macs has "
                + "no record of the Mac to block. The Mac can pair again with a new code")
        }
        let record = try Self.onlyMatch(of: text, in: matches)
        var blocked = list
        blocked.block(record.key)
        var saveError = save(blocked)
        let ended = cutOff(record.key, endLeases: endLeases, reason: Self.revocationReason)
        if saveError != nil {
            // A failure that does not repeat then still leaves the Mac blocked.
            saveError = save(blocked)
        }
        if let saveError {
            unsavedBlocks.insert(record.key)
            logUnblocked(record.key, ended, reason: "\(saveError)")
            throw .invalidRequest(reason: "the host closed the Mac's connections, but it cannot record that the Mac "
                + "is blocked: \(saveError). \(Self.revokeAgain)")
        }
        unsavedBlocks.remove(record.key)
        configuration.logger.notice("Revoked a paired Mac", metadata: [
            "key": "\(record.key)",
            "name": "\(record.name)",
            "connections": "\(ended.connections)",
            "leases": "\(ended.leases)",
        ])
        return .revoked(
            PairedMac(name: record.name, key: record.key),
            connections: ended.connections,
            leases: ended.leases,
        )
    }

    /// The reason of the leases that a revocation ends.
    private static let revocationReason = "the host revoked this Mac"

    /// The advice in a revocation's failure when the daemon could not save the block.
    private static let revokeAgain = "The Mac stays blocked until the daemon restarts. Revoke it again once the list "
        + "can be saved"

    /// Reports whether the daemon refuses a paired client.
    ///
    /// - Parameter record: The client's record in the list of paired clients.
    /// - Returns: `true` when the record is blocked or the daemon keeps an unsaved block of its key.
    private func isBlocked(_ record: TrustedClient) -> Bool {
        record.isBlocked || unsavedBlocks.contains(record.key)
    }

    /// Finds the one connected Mac or owner of a lease with a key that a person's text names.
    ///
    /// - Parameter text: The short key or full fingerprint that the person gave.
    /// - Returns: The key, or `nil` when no key or more than one key matches.
    private func activeKey(namedBy text: String) -> KeyFingerprint? {
        let owners = Set(clients.values.map(\.owner) + ledger.leases.values.map(\.owner))
        let keys = owners.compactMap { owner in
            if case let .client(key) = owner, key.isNamed(by: text) {
                key
            } else {
                nil
            }
        }
        return try? Self.onlyMatch(of: text, in: keys)
    }

    /// Saves the list of paired clients.
    ///
    /// - Parameter list: The list to save.
    /// - Returns: The error of a failed save, or `nil` after the list was saved.
    private func save(_ list: TrustList<TrustedClient>) -> PoolError? {
        do throws(PoolError) {
            try list.save(to: configuration.directory)
            return nil
        } catch {
            return error
        }
    }

    /// Logs a revocation that closed a Mac's connections but could not block the Mac.
    ///
    /// - Parameters:
    ///   - key: The fingerprint of the Mac's key.
    ///   - ended: The connections and leases that the revocation ended.
    ///   - reason: Why the daemon could not block the Mac.
    private func logUnblocked(_ key: KeyFingerprint, _ ended: CutOff, reason: String) {
        configuration.logger.error("The host closed a revoked Mac's connections but cannot block it", metadata: [
            "key": "\(key)",
            "connections": "\(ended.connections)",
            "leases": "\(ended.leases)",
            "reason": "\(reason)",
        ])
    }

    /// The connections and leases that ``cutOff(_:endLeases:reason:)`` ended.
    private struct CutOff {
        /// The number of connections that the daemon closed.
        var connections: Int
        /// The number of leases that ended.
        var leases: Int
    }

    /// Ends the leases of a paired Mac and closes its connections.
    ///
    /// The daemon ends the leases first. Their attached clients then receive the reason. Each
    /// closed connection receives a refusal, and its waiting requests leave the queue.
    ///
    /// - Parameters:
    ///   - key: The fingerprint of the Mac's key.
    ///   - endLeases: Whether the daemon also ends the leases that outlive their client. The
    ///     leases that need a client end in either case.
    ///   - reason: Why the leases end.
    /// - Returns: The counts of closed connections and of the Mac's leases that ended.
    private func cutOff(_ key: KeyFingerprint, endLeases: Bool, reason: String) -> CutOff {
        let owner = LeaseOwner.client(key)
        let before = ledger.liveLeases(of: owner).count
        // A lease that needs a client may wait for its client to reattach after a daemon
        // restart. The Mac can no longer reattach. The lease therefore ends now.
        for id in ledger.liveLeases(of: owner) where endLeases || ledger.leases[id]?.needsClient == true {
            perform((try? ledger.release(id, owner: .local, reason: reason)) ?? [])
        }
        let connections = clients.filter { $0.value.owner == owner }.keys.sorted()
        for connection in connections {
            disconnect(connection, sending: .failure(Self.notAcceptedReason))
        }
        return CutOff(connections: connections.count, leases: before - ledger.liveLeases(of: owner).count)
    }

    /// The refusal that a paired Mac receives after the host stopped accepting it.
    private static let notAcceptedReason = PoolError.invalidRequest(reason: "the host no longer accepts this Mac")
        .description

    /// Sends a last reply to a paired client and closes its connection.
    ///
    /// The daemon withdraws the client's waiting requests and ends its attached leases at once,
    /// as when the client disconnects. A paired client holds no invitation, because only the local
    /// user may invite.
    ///
    /// - Parameters:
    ///   - client: The client.
    ///   - last: The reply that the client receives before the connection closes.
    private func disconnect(_ client: ClientID, sending last: PoolReply) {
        guard let connection = clients.removeValue(forKey: client) else {
            return
        }
        perform(ledger.clientDisconnected(client, now: configuration.now()))
        try? connection.channel.send(visible(last, to: connection.owner))
        Task { await connection.channel.finish() }
    }

    /// Returns the one Mac that a person's key names.
    ///
    /// - Parameters:
    ///   - text: The short key or full fingerprint that the person gave.
    ///   - matches: The Macs with a key that `text` names, each once.
    /// - Returns: The only match.
    /// - Throws: ``PoolError/invalidRequest(reason:)`` when `matches` is empty or has more than one
    ///   Mac.
    private static func onlyMatch<Mac>(of text: String, in matches: [Mac]) throws(PoolError) -> Mac {
        guard matches.count < 2 else {
            throw .invalidRequest(
                reason: "\(matches.count) paired Macs have the short key \(text). Give the full key",
            )
        }
        guard let match = matches.first else {
            throw .invalidRequest(reason: "no paired Mac has the key \(text). Give its short key or its full key")
        }
        return match
    }

    /// Sends a reply to a client that is still connected.
    ///
    /// - Parameters:
    ///   - reply: The reply.
    ///   - client: The receiving client.
    private func reply(_ reply: PoolReply, to client: ClientID) {
        guard let connection = clients[client] else {
            return
        }
        try? connection.channel.send(visible(reply, to: connection.owner))
    }

    /// Returns the reply that a client may receive.
    ///
    /// A reply to a paired client must not name the data directory, an offered source, the home
    /// directory, a file URL, or a path that starts with `~/`. If one does, the daemon logs it
    /// and returns a failure in its place. The replies to paired clients avoid these texts on
    /// their own. This check catches a text that a later change adds.
    ///
    /// - Parameters:
    ///   - reply: The reply to check.
    ///   - owner: Who the receiving client acts for.
    /// - Returns: The reply, or a failure that names no path.
    func visible(_ reply: PoolReply, to owner: LeaseOwner) -> PoolReply {
        guard owner != .local, namesHostPath(reply.texts) else {
            return reply
        }
        configuration.logger.log(
            level: peerLogLevel(of: .hostPathInReply, full: .warning),
            "A reply to a paired Mac named a host path",
            metadata: ["reply": "\(reply)"],
        )
        return .failure("the host could not complete the request. The host's log has the reason")
    }

    /// Reports whether any of the texts contains one of ``forbiddenTexts``.
    ///
    /// The check compares the UTF-8 bytes of case-folded, canonically decomposed texts. A path
    /// therefore matches in any letter case and either Unicode normalization form, and also when
    /// a combining mark follows it. On the default volume format, a path in another letter case
    /// names the same file.
    ///
    /// - Parameter texts: The texts of a reply, or the host's name for clients.
    /// - Returns: `true` if a text names a host path.
    private func namesHostPath(_ texts: [String]) -> Bool {
        let forbidden = forbiddenTexts.map(Self.caselessBytes(of:))
        return texts.contains { text in
            let bytes = Self.caselessBytes(of: text)
            return forbidden.contains { bytes.contains($0) }
        }
    }

    /// Returns the UTF-8 bytes of a text after case folding and canonical decomposition.
    ///
    /// - Parameter text: The text to convert.
    /// - Returns: The bytes. Two texts that differ only in letter case or normalization form have
    ///   the same bytes.
    private static func caselessBytes(of text: String) -> [UInt8] {
        // The canonical caseless match of the Unicode standard decomposes a text before and after
        // case folding.
        let folded = text.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
        return Array(folded.decomposedStringWithCanonicalMapping.utf8)
    }

    /// The texts that no reply to a paired client may contain.
    ///
    /// The texts are the host paths, their percent-encoded forms, the `file://` prefix of every
    /// file URL, and the `~/` prefix of every path in the home directory. A file URL encodes the
    /// decomposed form of a path. The precomposed form is also encoded, because other code may
    /// encode a path that way.
    private var forbiddenTexts: [String] {
        let directories = [configuration.directory.root, FileManager.default.homeDirectoryForCurrentUser]
        let paths = directories.map { $0.path(percentEncoded: false) } + configuration.offeredSources.values
        var texts = ["file://", "~/"]
        for path in paths {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            // A path of "/" alone would match every text with a slash.
            guard !trimmed.isEmpty else {
                continue
            }
            texts.append(trimmed)
            texts.append(URL(filePath: trimmed).path(percentEncoded: true))
            if let encoded = trimmed.precomposedStringWithCanonicalMapping
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                texts.append(encoded)
            }
        }
        return texts
    }

    /// Applies an owner's limits to a lease request and checks that it can serve a lease.
    ///
    /// A paired client's source is a name from ``Configuration/offeredSources``, which becomes
    /// the bundle's path. A paired client may not share a host directory, because the guest
    /// would reach the host's files through it. Its priority may not exceed the ceiling in its
    /// record. At most ``PoolPolicy/slots`` of its requests wait in the queue. Requests of equal
    /// priority wait in arrival order. The local user therefore gets ahead of a paired client
    /// only with a higher priority.
    ///
    /// - Parameters:
    ///   - terms: The requested terms.
    ///   - paired: The record of the paired client that requests the lease, or `nil` for the
    ///     local user.
    /// - Returns: The terms with the source's path, and the source's name for a paired client.
    /// - Throws: ``PoolError/invalidRequest(reason:)`` when a paired client names a source that
    ///   the host does not offer, asks for a shared directory or a priority above its ceiling, or
    ///   already has the most requests in the queue. The errors of ``LeaseTerms/validate()`` and
    ///   ``checkSource(of:offeredName:)`` propagate.
    private func admit(_ terms: LeaseTerms, from paired: TrustedClient?) throws(PoolError) -> AdmittedRequest {
        guard let paired else {
            try terms.validate()
            try checkSource(of: terms, offeredName: nil)
            return AdmittedRequest(terms: terms, sourceName: nil)
        }
        guard terms.sharedDirectory == nil else {
            throw .invalidRequest(reason: "a paired client cannot share a host directory")
        }
        guard terms.priority <= paired.priorityCeiling else {
            throw .invalidRequest(reason: "this Mac may ask for a priority of at most \(paired.priorityCeiling)")
        }
        guard ledger.waitingRequests(of: .client(paired.key)) < configuration.policy.slots else {
            throw .invalidRequest(reason: "this Mac already has as many requests in the queue as the host has slots")
        }
        // The reason does not repeat the name. If the name were a host path, visible(_:to:) would
        // replace the reply, and the change would confirm the path.
        guard let path = configuration.offeredSources[terms.source] else {
            throw .invalidRequest(reason: "the host does not offer the requested source")
        }
        var admitted = terms
        admitted.source = path
        try admitted.validate()
        try checkSource(of: admitted, offeredName: terms.source)
        return AdmittedRequest(terms: admitted, sourceName: terms.source)
    }

    /// Reads the record of a paired client from the list of paired clients.
    ///
    /// - Parameter key: The fingerprint of the client's key.
    /// - Returns: The client's record, or `nil` when the list no longer names the key or blocks
    ///   it.
    /// - Throws: ``PoolError/invalidRequest(reason:)`` when the list cannot be read. The reason
    ///   names no host path. The daemon logs the list's error.
    private func pairedRecord(_ key: KeyFingerprint) throws(PoolError) -> TrustedClient? {
        let clients: TrustList<TrustedClient>
        do {
            clients = try TrustList<TrustedClient>.load(from: configuration.directory)
        } catch {
            configuration.logger.log(
                level: peerLogLevel(of: .unreadableClientList, full: .error),
                "The list of paired clients cannot be read",
                metadata: ["reason": "\(error)"],
            )
            throw .invalidRequest(reason: "the host cannot read its list of paired Macs")
        }
        guard let record = clients[key], !isBlocked(record) else {
            return nil
        }
        return record
    }

    /// Checks that a request's source and shared directory can serve a lease.
    ///
    /// A request that fails these checks would only fail its boots, so it is refused before it
    /// takes a place in the queue. See ``checkImage(at:offeredName:)`` for the image record.
    ///
    /// If `offeredName` is set, every error names the source by it and names no host path. The
    /// daemon then logs the error of settings that cannot be read.
    ///
    /// - Parameters:
    ///   - terms: The requested terms with the source's path.
    ///   - offeredName: The name of the source that a paired client asked for, or `nil` for a
    ///     local request.
    /// - Throws: ``PoolError/library(_:)`` for a local request when the source's settings or its
    ///   image record cannot be read, its own credential rotation did not finish, or another
    ///   process holds it. A paired client's request gets ``PoolError/invalidRequest(reason:)``
    ///   for these instead. Every request gets ``PoolError/invalidRequest(reason:)`` when the
    ///   source never booted, is an image without a record that marks it ready, lies on another
    ///   volume than the data directory, or the shared directory is missing.
    private func checkSource(of terms: LeaseTerms, offeredName: String?) throws(PoolError) {
        let source = terms.source
        let shown = offeredName ?? source
        let bundle = VMBundle(root: URL(filePath: source))
        let settings: BundleSettings
        do {
            settings = try bundle.settings()
        } catch {
            if let offeredName {
                configuration.logger.log(
                    level: peerLogLevel(of: .unreadableSource(offeredName), full: .warning),
                    "An offered source cannot be read",
                    metadata: ["source": "\(source)", "reason": "\(error)"],
                )
                throw .invalidRequest(reason: "the host cannot read the source \(shown)")
            }
            throw .library(error)
        }
        guard settings.credentialRotation != .started else {
            throw offeredName == nil
                ? .library(.credentialRotationIncomplete(path: source))
                : .invalidRequest(reason: "the source \(shown) did not finish its credential rotation")
        }
        guard settings.hasBooted != false else {
            throw .invalidRequest(reason: "the source \(shown) never booted, so its clones have no guest account")
        }
        try checkImage(at: source, offeredName: offeredName)
        guard !BundleLock.isHeld(on: bundle) else {
            throw offeredName == nil
                ? .library(.bundleInUse(path: source))
                : .invalidRequest(reason: "another process uses the source \(shown)")
        }
        let manager = FileManager.default
        let sourceVolume = try? manager.attributesOfItem(atPath: source)[.systemNumber] as? Int
        let poolVolume = try? manager.attributesOfItem(
            atPath: configuration.directory.leasesDirectory.path(percentEncoded: false),
        )[.systemNumber] as? Int
        guard sourceVolume == poolVolume else {
            throw .invalidRequest(
                reason: "the source \(shown) is not on the data directory's volume, so it cannot be cloned",
            )
        }
        if let shared = terms.sharedDirectory {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: shared, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw .invalidRequest(reason: "the shared directory \(shared) does not exist")
            }
        }
    }

    /// Checks that a source's image record lets the daemon lease it.
    ///
    /// A source in the data directory's `images` directory needs an image record that marks it
    /// ready. A source elsewhere may have no record.
    ///
    /// - Parameters:
    ///   - source: The source's path as the request named it.
    ///   - offeredName: The name that a paired client used for the source, or `nil` for a local
    ///     client. If it is set, the refusals name the source by it instead of its path.
    /// - Throws: ``PoolError/library(_:)`` when a local client's image record cannot be read.
    ///   ``PoolError/invalidRequest(reason:)`` when the source is an image without a readable
    ///   record that marks it ready.
    private func checkImage(at source: String, offeredName: String?) throws(PoolError) {
        let bundle = VMBundle(root: URL(filePath: source))
        // A paired Mac learns no paths on this Mac's disk.
        let imageName = offeredName ?? source
        let image: ImageRecord?
        do {
            image = try bundle.imageRecord()
        } catch {
            guard offeredName == nil else {
                throw .invalidRequest(
                    reason: "the image \(imageName) has an unreadable image.json, so it cannot be leased",
                )
            }
            throw .library(error)
        }
        if image == nil, isInImagesDirectory(bundle) {
            throw .invalidRequest(reason: "the image \(imageName) has no image.json, so it cannot be leased")
        }
        if let image, !image.isReady {
            throw .invalidRequest(reason: "the image \(imageName) did not pass its checks, so it cannot be leased")
        }
    }

    /// Reports whether a bundle lies directly in the data directory's `images` directory.
    ///
    /// - Parameter bundle: The bundle.
    /// - Returns: Whether the bundle's parent directory is `images`, after resolving symbolic links.
    private func isInImagesDirectory(_ bundle: VMBundle) -> Bool {
        let parent = bundle.root.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let images = configuration.directory.imagesDirectory.standardizedFileURL.resolvingSymlinksInPath()
        return parent.pathComponents == images.pathComponents
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
    /// - Throws: ``PoolError`` when the old clone cannot be removed, or the source is in use, is an
    ///   image that is no longer ready, or cannot be cloned.
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
        let sourceLock: BundleLock
        do {
            sourceLock = try BundleLock(bundle: source)
        } catch {
            throw .library(error)
        }
        defer { withExtendedLifetime(sourceLock) {} }
        // The image may have changed while the request waited in the queue. A paired client gets
        // the hidden failure instead of this reason, so the reason may name the path for the log.
        try checkImage(at: terms.source, offeredName: nil)
        do throws(MacpoolError) {
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
            return deferEnding(of: id)
        }
        let socket = directory.supervisorSocket(for: id)
        if let channel = try? await MessageChannel.connect(to: socket, timeout: .seconds(2)) {
            guard !isStopDeferred(id) else {
                channel.close()
                return deferEnding(of: id)
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
                return deferEnding(of: id)
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
                    return deferEnding(of: id)
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

    /// Logs that a supervisor keeps running until a write of the state.
    ///
    /// - Parameter id: The lease.
    /// - Returns: ``SupervisorEnding/deferred``.
    private func deferEnding(of id: LeaseID) -> SupervisorEnding {
        configuration.logger.debug("A supervisor keeps running until the state file records its stop", metadata: [
            "lease": "\(id)",
        ])
        return .deferred
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

/// A lease request after the daemon applied its owner's limits.
private struct AdmittedRequest {
    /// The terms with the source's path.
    let terms: LeaseTerms

    /// The name of the source that a paired client asked for, or `nil` for a local request.
    let sourceName: String?
}

/// Reads the list of paired clients during the handshakes of the listener for paired Macs.
///
/// The reader logs a failure once until its reason changes or a read succeeds.
private final class ClientListReader: Sendable {
    /// The data directory.
    private let directory: PoolDirectory

    /// The daemon's logger.
    private let logger: Logger

    /// The reason of the last failed read, or `nil` after a read succeeded.
    private let failure = Mutex<String?>(nil)

    /// Creates a reader.
    ///
    /// - Parameters:
    ///   - directory: The data directory.
    ///   - logger: The daemon's logger.
    init(directory: PoolDirectory, logger: Logger) {
        self.directory = directory
        self.logger = logger
    }

    /// Reads the list.
    ///
    /// - Returns: The list, or `nil` when it cannot be read. The listener then admits nobody.
    func read() -> TrustList<TrustedClient>? {
        do throws(PoolError) {
            let list = try TrustList<TrustedClient>.load(from: directory)
            failure.withLock { $0 = nil }
            return list
        } catch {
            let isNew = failure.withLock { last in
                defer { last = error.description }
                return last != error.description
            }
            if isNew {
                logger.error("The list of paired clients cannot be read, so no paired Mac can connect", metadata: [
                    "reason": "\(error)",
                ])
            }
            return nil
        }
    }
}

/// The texts of replies, for the check that replies to paired clients name no host path.
private extension PoolReply {
    /// Every text in the reply.
    var texts: [String] {
        switch self {
        case .queued, .released, .wrongCode:
            []
        case let .starting(lease), let .ready(lease), let .renewed(lease):
            lease.texts
        case let .restarting(lease, reason):
            lease.texts + [reason]
        case let .ended(_, reason):
            [reason]
        case let .status(pool):
            pool.leases.flatMap(\.texts) + pool.queue.map(\.source) + pool.images.flatMap(\.texts)
        case let .failure(message):
            [message]
        case let .invitation(code, _):
            [code.description]
        case let .paired(mac), let .alreadyPaired(mac), let .revoked(mac, _, _):
            [mac.name]
        }
    }
}

/// The texts of a lease summary.
private extension LeaseSummary {
    /// The source, the clone's path, and the address, without the missing ones.
    var texts: [String] {
        [source, bundle, address].compactMap(\.self)
    }
}

/// The texts of an image summary.
private extension ImageSummary {
    /// The name, the path, the problem if there is one, and the names and versions of the builds.
    var texts: [String] {
        [name, path] + [problem].compactMap(\.self) + builds.keys + builds.values
    }
}
