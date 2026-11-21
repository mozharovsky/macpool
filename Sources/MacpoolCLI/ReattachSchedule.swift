import Foundation
import MacpoolPool

/// The attempts of `macpool lease` to attach to its lease again after the connection to the daemon
/// broke.
///
/// The pause after a failed attempt starts at ``firstPause`` and doubles up to ``longestPause``.
/// A pause ends at the deadline, so the last attempt starts at the deadline at the latest.
///
/// The attempts stop early in two cases. If an attempt fails in a way that another attempt cannot
/// change, such as another host key, the schedule stops at once. If a host finishes the handshake
/// and refuses every attempt for ``refusalLimit``, the host is awake and no longer holds the
/// lease.
struct ReattachSchedule: Sendable {
    /// The pause after the first failed attempt.
    static let firstPause = Duration.seconds(1)

    /// The longest pause between attempts.
    ///
    /// A paired host keeps the lease for 60 seconds of its awake time after it notices the break.
    /// After a host wakes, the next attempt therefore starts with time left for its handshake.
    static let longestPause = Duration.seconds(15)

    /// How long the attempts continue while a host that finished the handshake refuses them.
    ///
    /// Such a host is awake. It closes a silent connection of this Mac after
    /// `PoolDaemon.peerSilenceLimit` and keeps the lease for its reattach grace after that. Longer
    /// refusals mean that the lease has ended. The schedule measures this limit on ``awakeTime``,
    /// because the host does not count the time that it sleeps.
    static let refusalLimit = PoolDaemon.peerSilenceLimit + PoolPolicy().reattachGrace

    /// The time after which no attempt starts.
    let deadline: Date

    /// Returns the current time.
    let now: @Sendable () -> Date

    /// Returns the current time on a clock that stops while this Mac sleeps.
    let awakeTime: @Sendable () -> SuspendingClock.Instant

    /// Waits for the length of a pause, or less if the task is cancelled.
    let pause: @Sendable (Duration) async -> Void

    /// Creates a schedule.
    ///
    /// - Parameters:
    ///   - deadline: The time after which no attempt starts.
    ///   - now: Returns the current time. The default reads the system time.
    ///   - awakeTime: Returns the current time on a clock that stops while this Mac sleeps. The
    ///     default reads `SuspendingClock`.
    ///   - pause: Waits for the length of a pause. The default sleeps.
    init(
        deadline: Date,
        now: @escaping @Sendable () -> Date = { Date() },
        awakeTime: @escaping @Sendable () -> SuspendingClock.Instant = { SuspendingClock().now },
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    ) {
        self.deadline = deadline
        self.now = now
        self.awakeTime = awakeTime
        self.pause = pause
    }

    /// Chooses the deadline of the attempts for a lease.
    ///
    /// A paired host may sleep for longer than any fixed limit, and it keeps the lease while it
    /// sleeps. The attempts on a ready lease of a paired host therefore last until the lease
    /// expires.
    ///
    /// - Parameters:
    ///   - expiry: The lease's expiry from its last `ready` reply, or `nil` before the first one.
    ///   - pairedHost: Whether a paired host holds the lease.
    ///   - now: The current time.
    /// - Returns: The expiry for a paired host that reported one. Otherwise
    ///   ``LeaseCommand/reconnectTimeout`` after `now`.
    static func deadline(expiry: Date?, pairedHost: Bool, now: Date) -> Date {
        if pairedHost, let expiry {
            return expiry
        }
        return now.addingTimeInterval(LeaseCommand.reconnectTimeout / .seconds(1))
    }

    /// Runs attempts until one succeeds, the deadline passes, or the task is cancelled.
    ///
    /// A failure that does not reach the host, such as a handshake that times out while the host
    /// sleeps, starts the count of ``refusalLimit`` again. A sleep of this Mac between refusals
    /// does not count.
    ///
    /// - Parameter attempt: Connects to the daemon and asks it to attach the lease.
    /// - Returns: The result of the first attempt that succeeds, or `nil` when the task is
    ///   cancelled first.
    /// - Throws: The error of the last attempt if it fails at or after the deadline, the error of
    ///   an attempt that ``isTransient(_:)`` rejects, or ``CommandError/reattachRefused(seconds:reason:)``
    ///   when the host refuses the attempts for ``refusalLimit``.
    func run<Value>(_ attempt: () async throws(CommandError) -> Value) async throws(CommandError) -> Value? {
        var next = Self.firstPause
        var refusedSince: SuspendingClock.Instant?
        while !Task.isCancelled {
            do throws(CommandError) {
                return try await attempt()
            } catch {
                let failed = now()
                guard Self.isTransient(error), failed < deadline else {
                    throw error
                }
                if Self.isRefusal(error) {
                    let awake = awakeTime()
                    let since = refusedSince ?? awake
                    refusedSince = since
                    guard since.duration(to: awake) < Self.refusalLimit else {
                        throw .reattachRefused(seconds: Int(Self.refusalLimit / .seconds(1)), reason: error.description)
                    }
                } else {
                    refusedSince = nil
                }
                await pause(min(next, .seconds(deadline.timeIntervalSince(failed))))
                next = min(next * 2, Self.longestPause)
            }
        }
        return nil
    }

    /// Reports whether another attempt may succeed after an error.
    ///
    /// - Parameter error: The error of an attempt.
    /// - Returns: Whether the connection failed or closed, or the host refused it after the
    ///   handshake. Another host key, another protocol version, an unknown host, or an unreadable
    ///   key stays the same on the next attempt.
    static func isTransient(_ error: CommandError) -> Bool {
        switch error {
        case .pool(.connection), .pool(.connectionClosed), .pool(.daemonUnreachable), .pool(.greetingFailed):
            true
        default:
            false
        }
    }

    /// Reports whether an error shows that the host finished the handshake and is therefore
    /// awake.
    ///
    /// - Parameter error: The error of an attempt.
    /// - Returns: Whether the host refused the connection or sent no greeting after the handshake.
    static func isRefusal(_ error: CommandError) -> Bool {
        if case .pool(.greetingFailed) = error {
            return true
        }
        return false
    }
}
