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
/// When the connection to a paired host breaks, the command connects again and attaches to the
/// lease. The host keeps the lease for 60 seconds of its awake time after it notices the break.
/// The command tries until the lease expires, because the host may sleep for longer. See
/// ``ReattachSchedule``.
///
/// If a paired host does not confirm the release, the command fails. The host then ends the lease
/// 60 seconds after it notices that the command's connection closed.
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

    /// The longest wait for each step of a release on a paired host, which are the handshake, the
    /// greeting, and the reply.
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

    /// Rejects a detached lease with a command and out-of-range durations.
    ///
    /// - Throws: `ValidationError` when the options contradict each other or a duration is out of
    ///   range.
    func validate() throws {
        guard !(detach && !command.isEmpty) else {
            throw ValidationError("--detach cannot run a command.")
        }
        guard selection.host == nil || sharing.share == nil else {
            throw ValidationError("--share cannot share a directory of this Mac with a lease on another Mac.")
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
    ///   does not confirm the release.
    private func perform() async throws(CommandError) -> Int32 {
        let directory = location.directory
        let selection = selection
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
        var expiry: Date?
        var isReady = false
        var interruption: Int32?
        var failure = CommandError.interrupted
        loop: for await event in events {
            switch event {
            case let .reply(.queued(position)):
                Report.line("queued position=\(position)")
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
                expiry = lease.expiresAt
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
                 .reply(.alreadyPaired), .reply(.wrongCode), .reply(.revoked), .reply(.forgotten), .reply(.access):
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
                try await Self.release(id, through: selection, in: directory)
                Report.line("released \(id)")
                // Control-C is the normal end of a held lease, so only an interrupted boot fails.
                return isReady ? 0 : 128 + number
            case let .commandEnded(status):
                if let id {
                    try await Self.release(id, through: selection, in: directory)
                    Report.line("released \(id)")
                }
                if let interruption {
                    return 128 + interruption
                }
                return status
            }
        }
        // The command must not outlive the lease, because its VM goes away with the lease.
        if let running {
            running.cancel()
            await running.value
        }
        throw failure
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

    /// Releases a lease over a new connection.
    ///
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
