import ArgumentParser
import Foundation
import MacpoolPool
import Subprocess
import System

/// Leases a clone of a stopped bundle from the daemon.
///
/// The command waits in the daemon's queue until a slot is free. It prints `queued position=N`
/// while it waits, `lease_id=` and `bundle=` once the daemon boots the clone, and `address=`,
/// `expires_at=`, and `ready` once the VM is ready. A lease whose VM stops and boots again under
/// the restart policy prints `restarting reason=` and later `ready` again.
///
/// Without `--detach` the lease belongs to the command's connection. Control-C or `SIGTERM`
/// releases it, and so does the end of the command after `--`. The command runs with
/// `MACPOOL_LEASE_ID`, `MACPOOL_BUNDLE`, and `MACPOOL_ADDRESS` in its environment, and
/// `macpool lease` exits with its status. When the daemon restarts, the command reconnects and
/// keeps the lease. When the lease ends early or cannot be reattached, the command after `--`
/// gets `SIGTERM` and `macpool lease` waits for it to exit before it fails.
///
/// With `--detach` the command exits once the VM is ready, and the lease lasts until
/// `macpool release` or its expiry. Every lease expires its time to live after it was first
/// ready, and `macpool renew` moves the expiry.
///
/// With `--pool` the command leases from a paired host, and `--from` names a source that the host
/// offers. The lease then has no bundle or address on this Mac, so `MACPOOL_BUNDLE` and
/// `MACPOOL_ADDRESS` are empty. Reach the guest with `macpool ssh --pool`.
///
/// When `--pool` names a coordinator, the coordinator may choose another host that offers the
/// source. The command then prints `placed host=` with that host's short key, records the host in
/// the list of paired hosts, and sends the request to the host. Give the short key to `--pool` in
/// later commands for the lease.
///
/// When the connection to a paired host breaks, the command connects again and attaches to the
/// lease. The host keeps the lease for 60 seconds of its awake time after it notices the break.
/// The command tries until the lease expires, because the host may sleep for longer. See
/// ``ReattachSchedule``.
///
/// The command sends the release on the connection that holds the lease. A paired host limits the
/// connections of one Mac, so a new connection could be refused. Only while the command attaches
/// again does the release go over a new connection.
///
/// If a paired host does not confirm the release at Control-C, `macpool lease` fails. If the host
/// does not confirm it after the command after `--` ends, `macpool lease` prints a warning and still
/// exits with the command's status. In both cases the host ends the lease 60 seconds after it
/// notices that the connection closed.
struct LeaseCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "lease",
        abstract: "Leases a clone of a stopped bundle and holds it until release.",
    )

    /// How long a client tries to attach to its lease again after the daemon went away.
    ///
    /// The limit applies to the daemon on this Mac, and to a paired host before the lease is first
    /// ready.
    static let reconnectTimeout = Duration.seconds(60)

    /// The longest wait for each step of a release, which are the handshake, the greeting, and the
    /// reply.
    ///
    /// A release on the connection that holds the lease waits only for the reply.
    static let releaseTimeout = Duration.seconds(3)

    /// The data directory of this Mac's daemon, which also holds this Mac's key and paired hosts.
    @OptionGroup var location: PoolOptions

    /// The paired host to lease from, if any.
    @OptionGroup var selection: HostSelection

    /// The stopped source bundle, or the name of a source that the paired host offers.
    @Option(help: "The stopped source bundle to clone. With --pool, the name of a source that the host offers.")
    var from: String

    /// The lease's time to live in seconds.
    @Option(
        name: .customLong("ttl"),
        help: "The lease's time to live in seconds, counted from the first ready. renew starts it again.",
    )
    var timeToLive = 3600

    /// The queue priority.
    @Option(help: "The queue priority. Requests with a higher priority get a slot first.")
    var priority = 0

    /// When the daemon boots the VM again after it stopped.
    @Option(
        help: "When the VM boots again after it stops: never, on-failure, or always.",
        transform: RestartPolicy.parse,
    )
    var restart = RestartPolicy.onFailure

    /// The options that share a host directory with the guest.
    @OptionGroup var sharing: ShareOptions

    /// The longest wait for each boot, in seconds.
    @Option(
        name: .customLong("boot-timeout"),
        help: "The longest wait for the guest's address, SSH, and credential rotation on each boot, in seconds.",
    )
    var bootTimeout = 900

    /// Whether the command exits once the VM is ready and leaves the lease running.
    @Flag(help: "Exits once the VM is ready. The lease lasts until release or expiry.")
    var detach = false

    /// A command to run while the lease lasts.
    @Argument(
        parsing: .postTerminator,
        help: "A command to run after --. The lease ends when it exits.",
    )
    var command: [String] = []

    /// Rejects contradictory options, a path as the source on a paired host, and out-of-range
    /// durations.
    ///
    /// A paired host knows its sources by name. The check keeps a path on this Mac from reaching
    /// the host.
    ///
    /// - Throws: `ValidationError` when the options contradict each other, `--from` holds a `/`
    ///   with `--pool`, or a duration is out of range.
    func validate() throws {
        guard !(detach && !command.isEmpty) else {
            throw ValidationError("--detach cannot run a command.")
        }
        guard selection.host == nil || sharing.share == nil else {
            throw ValidationError("--share cannot share a directory of this Mac with a lease on another Mac.")
        }
        guard selection.host == nil || !from.contains("/") else {
            throw ValidationError("With --pool, --from takes the name of a source that the host offers, not a path.")
        }
        guard (1 ... LeaseTerms.maximumTimeToLive).contains(timeToLive) else {
            throw ValidationError("--ttl takes 1 to \(LeaseTerms.maximumTimeToLive) seconds.")
        }
        guard (1 ... LeaseTerms.maximumBootTimeout).contains(bootTimeout) else {
            throw ValidationError("--boot-timeout takes 1 to \(LeaseTerms.maximumBootTimeout) seconds.")
        }
    }

    /// Requests the lease, reports its progress, and holds it.
    ///
    /// - Throws: ``CommandError`` when the paired host is unknown, no daemon answers, the daemon
    ///   rejects the request, the lease ends early, or a signal interrupts the wait. Throws
    ///   `ExitCode` with the status of a command that failed.
    func run() async throws {
        let status = try await perform()
        if status != 0 {
            throw ExitCode(status)
        }
    }

    /// The lease's terms from the options.
    ///
    /// The source is an absolute path for the daemon on this Mac and the name as typed for a
    /// paired host.
    var terms: LeaseTerms {
        LeaseTerms(
            source: selection.host == nil ? URL(filePath: from).absoluteURL.path(percentEncoded: false) : from,
            timeToLive: timeToLive,
            priority: priority,
            restartPolicy: restart,
            sharedDirectory: sharing.absolutePath,
            sharedDirectoryIsReadOnly: sharing.readOnly,
            bootTimeout: bootTimeout,
            detached: detach,
        )
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Returns: The exit status, which is the command's status when one ran.
    /// - Throws: ``CommandError`` when the paired host is unknown, no daemon answers, the daemon
    ///   rejects the request, the lease ends early, a signal interrupts the wait, or a paired host
    ///   does not confirm the release at Control-C.
    private func perform() async throws(CommandError) -> Int32 {
        let directory = location.directory
        var selection = selection
        let terms = terms
        if selection.host == nil {
            // A paired host checks the source by name, and validate() requires a path.
            try pool { () throws(PoolError) in try terms.validate() }
        }
        var channel = try await selection.connect(in: directory)
        try pool { () throws(PoolError) in try channel.send(PoolRequest.lease(terms)) }
        let (events, sink) = AsyncStream.makeStream(of: LeaseEvent.self)
        var reader = Self.read(channel, into: sink)
        let watch = SignalWatch { sink.yield(.signal($0)) }
        var running: Task<Void, Never>?
        var reattaching: Task<Void, Never>?
        defer {
            watch.cancel()
            reader.cancel()
            reattaching?.cancel()
            channel.close()
        }

        var id: LeaseID?
        var isPlaced = false
        var expiry: Date?
        var isReady = false
        var interruption: Int32?
        var failure = CommandError.interrupted
        var releasing: PendingRelease?
        defer { releasing?.timer.cancel() }
        loop: for await event in events {
            if case let .reply(reply) = event {
                expiry = Self.expiry(after: reply, of: id, from: expiry)
            }
            if let pending = releasing, let id {
                switch pending.outcome(of: event, for: id) {
                case nil:
                    continue
                case .confirmed:
                    return try finish(pending, of: id, failure: nil)
                case let .failed(reason):
                    return try finish(pending, of: id, failure: selection.shown(reason))
                }
            }
            switch event {
            case let .reply(.queued(position)):
                Report.line("queued position=\(position)")
            case let .reply(.placed(placed)):
                // Only a coordinator places a request, and only before a host grants the lease.
                guard id == nil, !isPlaced else {
                    failure = .pool(.malformedMessage(reason: "a placement arrived after the request was placed"))
                    break loop
                }
                isPlaced = true
                let host = try pool { () throws(PoolError) in try TrustedHost.introduce(placed, in: directory) }
                Report.line("placed host=\(host.key.shortKey)")
                reader.cancel()
                channel.close()
                selection.host = host.key.shortKey
                channel = try await selection.connect(in: directory)
                try pool { () throws(PoolError) in try channel.send(PoolRequest.lease(terms)) }
                reader = Self.read(channel, into: sink)
            case let .reply(.starting(lease)):
                if id == nil {
                    id = lease.id
                    Report.line("lease_id=\(lease.id)")
                    Report.line("bundle=\(selection.shown(lease.bundle ?? ""))")
                } else {
                    Report.line("starting")
                }
            case let .reply(.ready(lease)):
                Report.line("address=\(selection.shown(lease.address ?? ""))")
                Report.line("expires_at=\(lease.expiresAt.map(LeaseOutput.timestamp) ?? "")")
                Report.line("ready")
                isReady = true
                if detach {
                    return 0
                }
                if !command.isEmpty, running == nil {
                    running = Self.start(command, for: lease, into: sink)
                }
            case let .reply(.restarting(_, reason)):
                isReady = false
                Report.line("restarting reason=\(selection.shown(reason))")
            case let .reply(.ended(ended, reason)):
                Report.line("ended reason=\(selection.shown(reason))")
                failure = .leaseEnded(id: ended.rawValue, reason: selection.shown(reason))
                break loop
            case let .reply(.failure(message)):
                failure = .pool(.daemonRefused(message: selection.shown(message)))
                break loop
            case .reply(.released), .reply(.renewed), .reply(.status), .reply(.invitation), .reply(.paired),
                 .reply(.alreadyPaired), .reply(.wrongCode), .reply(.revoked), .reply(.forgotten), .reply(.access),
                 .reply(.unblocked), .reply(.grant), .releaseTimedOut:
                break
            case .disconnected:
                guard let id else {
                    failure = .pool(.connectionClosed)
                    break loop
                }
                channel.close()
                let deadline = ReattachSchedule.deadline(expiry: expiry, pairedHost: selection.host != nil, now: Date())
                reattaching = Self.reattach(
                    id,
                    through: selection,
                    in: directory,
                    on: ReattachSchedule(deadline: deadline),
                    into: sink,
                )
            case let .reattached(reattached):
                reattaching = nil
                channel = reattached
                reader = Self.read(channel, into: sink)
            case let .reattachFailed(error):
                failure = error
                break loop
            case let .signal(number):
                if let running {
                    // The command ends first, and its end releases the lease.
                    interruption = number
                    running.cancel()
                    continue
                }
                guard let id else {
                    // Closing the connection withdraws the queued request.
                    break loop
                }
                // Control-C is the normal end of a held lease, so only an interrupted boot fails.
                let status = isReady ? 0 : 128 + number
                guard reattaching == nil else {
                    try await Self.release(id, through: selection, in: directory)
                    Report.line("released \(id)")
                    return status
                }
                releasing = Self.release(id, on: channel, exitingWith: status, failing: true, into: sink)
            case let .commandEnded(commandStatus):
                let status = interruption.map { 128 + $0 } ?? commandStatus
                guard let id else {
                    return status
                }
                guard reattaching == nil else {
                    do throws(CommandError) {
                        try await Self.release(id, through: selection, in: directory)
                        Report.line("released \(id)")
                    } catch {
                        // A CI job reads the command's status, and the host ends the lease by itself.
                        Report.warning(error.description)
                    }
                    return status
                }
                releasing = Self.release(id, on: channel, exitingWith: status, failing: false, into: sink)
            }
        }
        // The command must not outlive the lease, because its VM goes away with the lease.
        if let running {
            running.cancel()
            await running.value
        }
        throw failure
    }

    /// Ends a release that the command sent on the connection that holds the lease.
    ///
    /// The daemon on this Mac ends the lease when the connection closes, so a failed release there
    /// goes unreported. A paired host keeps the lease for its reattach grace instead.
    ///
    /// - Parameters:
    ///   - pending: The release.
    ///   - id: The lease.
    ///   - reason: Why the release failed, or `nil` after the daemon confirmed it.
    /// - Returns: The status that the command exits with.
    /// - Throws: ``CommandError/releaseUnconfirmed(id:reason:)`` when a paired host did not confirm
    ///   a release that fails the command.
    private func finish(_ pending: PendingRelease, of id: LeaseID, failure reason: String?) throws(CommandError)
        -> Int32 {
        pending.timer.cancel()
        guard let reason, selection.host != nil else {
            Report.line("released \(id)")
            return pending.status
        }
        let error = CommandError.releaseUnconfirmed(id: id.rawValue, reason: reason)
        guard !pending.failsCommand else {
            throw error
        }
        // A CI job reads the command's status, and the host ends the lease by itself.
        Report.warning(error.description)
        return pending.status
    }

    /// Sends a release on the connection that holds the lease and starts the wait for its reply.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - channel: The connection that holds the lease.
    ///   - status: The status that the command exits with once the release ends.
    ///   - failing: Whether a paired host that does not confirm the release fails the command.
    ///   - sink: The event stream that receives ``LeaseEvent/releaseTimedOut`` after
    ///     ``releaseTimeout``.
    /// - Returns: The release.
    private static func release(
        _ id: LeaseID,
        on channel: MessageChannel,
        exitingWith status: Int32,
        failing: Bool,
        into sink: AsyncStream<LeaseEvent>.Continuation,
    ) -> PendingRelease {
        // A send fails only on a broken connection, and the reader then reports the disconnect.
        try? channel.send(PoolRequest.release(id))
        let timer = Task {
            do {
                try await Task.sleep(for: releaseTimeout)
                sink.yield(.releaseTimedOut)
            } catch {
                // The release ended first and cancelled the wait.
            }
        }
        return PendingRelease(status: status, failsCommand: failing, timer: timer)
    }

    /// Forwards a channel's replies to the event stream until the connection ends.
    ///
    /// - Parameters:
    ///   - channel: The daemon connection.
    ///   - sink: The event stream's continuation.
    /// - Returns: The forwarding task.
    private static func read(
        _ channel: MessageChannel,
        into sink: AsyncStream<LeaseEvent>.Continuation,
    ) -> Task<Void, Never> {
        Task {
            while let reply = try? await channel.receive(PoolReply.self) {
                sink.yield(.reply(reply))
            }
            if !Task.isCancelled {
                sink.yield(.disconnected)
            }
        }
    }

    /// Reconnects to a daemon that went away and attaches to the lease again.
    ///
    /// The attempts run in a task, so signals and the command's end reach the event stream
    /// meanwhile.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - selection: The daemon on this Mac or the paired host that holds the lease.
    ///   - directory: This Mac's data directory.
    ///   - schedule: The pauses between attempts and their deadline.
    ///   - sink: The event stream that receives the new connection, on which the daemon reports
    ///     the lease's stage, or the error that ended the attempts.
    /// - Returns: The reconnecting task, which stops trying when cancelled.
    private static func reattach(
        _ id: LeaseID,
        through selection: HostSelection,
        in directory: PoolDirectory,
        on schedule: ReattachSchedule,
        into sink: AsyncStream<LeaseEvent>.Continuation,
    ) -> Task<Void, Never> {
        Report.line("reconnecting")
        return Task {
            do throws(CommandError) {
                let attached = try await schedule.run { () async throws(CommandError) in
                    let channel = try await selection.connect(in: directory)
                    do throws(CommandError) {
                        try pool { () throws(PoolError) in try channel.send(PoolRequest.attach(id)) }
                    } catch {
                        channel.close()
                        throw error
                    }
                    return channel
                }
                guard let attached else {
                    return
                }
                guard !Task.isCancelled else {
                    attached.close()
                    return
                }
                sink.yield(.reattached(attached))
            } catch {
                sink.yield(.reattachFailed(error))
            }
        }
    }

    /// Chooses the expiry at which the attempts to attach again end after a reply about the lease.
    ///
    /// A `ready` reply carries the expiry. If another client renews the lease later, the daemon
    /// sends a `renewed` reply with the new expiry on this connection too.
    ///
    /// - Parameters:
    ///   - reply: A reply on the connection that holds the lease.
    ///   - id: The lease, or `nil` before the daemon granted one.
    ///   - expiry: The expiry before the reply.
    /// - Returns: The expiry in a `ready` reply or in a `renewed` reply about `id`. Otherwise
    ///   `expiry`.
    static func expiry(after reply: PoolReply, of id: LeaseID?, from expiry: Date?) -> Date? {
        switch reply {
        case let .ready(lease):
            lease.expiresAt
        case let .renewed(lease) where lease.id == id:
            lease.expiresAt
        default:
            expiry
        }
    }

    /// Releases a lease over a new connection.
    ///
    /// The command uses a new connection only while the connection that holds the lease is down.
    /// The daemon on this Mac ends an attached lease when its client's connection closes, so a
    /// failed release there goes unreported. A paired host keeps the lease for its reattach grace
    /// instead, so a failed release there fails the call.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - selection: The daemon on this Mac or the paired host that holds the lease.
    ///   - directory: This Mac's data directory.
    /// - Throws: ``CommandError/releaseUnconfirmed(id:reason:)`` when a paired host does not
    ///   confirm the release within ``releaseTimeout`` for each step.
    static func release(
        _ id: LeaseID,
        through selection: HostSelection,
        in directory: PoolDirectory,
    ) async throws(CommandError) {
        guard selection.host != nil else {
            _ = try? await selection.send(.release(id), in: directory)
            return
        }
        do throws(CommandError) {
            _ = try await selection.send(.release(id), in: directory, timeout: releaseTimeout)
        } catch {
            throw .releaseUnconfirmed(id: id.rawValue, reason: error.description)
        }
    }

    /// Runs the command after `--` with the lease in its environment.
    ///
    /// Cancelling the task sends the command `SIGTERM` and kills it 10 seconds later.
    ///
    /// - Parameters:
    ///   - command: The executable and its arguments.
    ///   - lease: The ready lease.
    ///   - sink: The event stream that receives the command's end.
    /// - Returns: The task that runs the command.
    private static func start(
        _ command: [String],
        for lease: LeaseSummary,
        into sink: AsyncStream<LeaseEvent>.Continuation,
    ) -> Task<Void, Never> {
        let environment = Environment.inherit.updating([
            "MACPOOL_LEASE_ID": lease.id.rawValue,
            "MACPOOL_BUNDLE": lease.bundle ?? "",
            "MACPOOL_ADDRESS": lease.address ?? "",
        ])
        let options = {
            var options = PlatformOptions()
            options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(10))]
            return options
        }()
        let executable = command.first ?? ""
        let arguments = Arguments(Array(command.dropFirst()))
        return Task {
            let status: Int32
            do {
                let result = try await Subprocess.run(
                    executable.contains("/") ? .path(.init(executable)) : .name(executable),
                    arguments: arguments,
                    environment: environment,
                    platformOptions: options,
                    input: .currentStandardInput,
                    output: .currentStandardOutput,
                    error: .currentStandardError,
                )
                switch result.terminationStatus {
                case let .exited(code):
                    status = code
                case let .signaled(signal):
                    status = 128 + signal
                }
            } catch {
                Report.line("the command did not run: \(error)")
                status = 127
            }
            sink.yield(.commandEnded(status))
        }
    }
}

/// Something that the lease command reacts to.
private enum LeaseEvent: Sendable {
    /// The daemon replied.
    case reply(PoolReply)
    /// The daemon connection ended.
    case disconnected
    /// The command reconnected to the daemon and asked to attach to the lease.
    case reattached(MessageChannel)
    /// No daemon answered within the reconnect timeout.
    case reattachFailed(CommandError)
    /// A termination signal arrived.
    case signal(Int32)
    /// The command after `--` exited with a status.
    case commandEnded(Int32)
    /// The daemon did not confirm a release within ``LeaseCommand/releaseTimeout``.
    case releaseTimedOut
}

/// A release that the command sent on the connection that holds the lease.
private struct PendingRelease {
    /// The status that the command exits with once the release ends.
    let status: Int32

    /// Whether a paired host that does not confirm the release fails the command.
    let failsCommand: Bool

    /// The task that sends ``LeaseEvent/releaseTimedOut``.
    let timer: Task<Void, Never>

    /// How a release ended.
    enum Outcome: Equatable {
        /// The daemon confirmed the release.
        case confirmed
        /// The daemon refused the release, the connection closed, or no reply came in time.
        ///
        /// - Parameter reason: Why the release failed.
        case failed(String)
    }

    /// Decides whether an event ends the release.
    ///
    /// The daemon reports the end of the lease before it confirms the release, and the command
    /// ignores a signal while it waits.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - id: The released lease.
    /// - Returns: How the release ended, or `nil` while it goes on.
    func outcome(of event: LeaseEvent, for id: LeaseID) -> Outcome? {
        switch event {
        case let .reply(.released(released)) where released == id:
            .confirmed
        case let .reply(.failure(message)):
            .failed(message)
        case .disconnected:
            .failed(PoolError.connectionClosed.description)
        case .releaseTimedOut:
            .failed("the daemon sent no reply within \(LeaseCommand.releaseTimeout)")
        default:
            nil
        }
    }
}

/// Parsing of restart policies from the command line.
extension RestartPolicy {
    /// Parses a policy that a person typed.
    ///
    /// - Parameter text: `never`, `on-failure`, or `always`.
    /// - Returns: The policy.
    /// - Throws: `ValidationError` for any other text.
    static func parse(_ text: String) throws -> RestartPolicy {
        guard let policy = RestartPolicy(rawValue: text) else {
            throw ValidationError("--restart takes never, on-failure, or always.")
        }
        return policy
    }
}
