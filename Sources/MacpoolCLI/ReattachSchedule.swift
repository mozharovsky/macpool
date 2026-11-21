import Foundation
import MacpoolPool

/// The attempts of `macpool lease` to attach to its lease again after the connection to the daemon
/// broke.
///
/// The pause after a failed attempt starts at ``firstPause`` and doubles up to ``longestPause``.
/// A pause ends at the deadline, so the last attempt starts at the deadline at the latest. The
/// attempts stop early when an attempt fails in a way that another attempt cannot change.
struct ReattachSchedule: Sendable {
    /// The pause after the first failed attempt.
    static let firstPause = Duration.seconds(1)

    /// The longest pause between attempts.
    ///
    /// A paired host keeps the lease for 60 seconds of its awake time after it notices the break.
    /// After a host wakes, the next attempt therefore starts with time left for its handshake.
    static let longestPause = Duration.seconds(15)

    /// The time after which no attempt starts.
    let deadline: Date

    /// Returns the current time.
    let now: @Sendable () -> Date

    /// Waits for the length of a pause, or less if the task is cancelled.
    let pause: @Sendable (Duration) async -> Void

    /// Creates a schedule.
    ///
    /// - Parameters:
    ///   - deadline: The time after which no attempt starts.
    ///   - now: Returns the current time. The default reads the system time.
    ///   - pause: Waits for the length of a pause. The default sleeps.
    init(
        deadline: Date,
        now: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    ) {
        self.deadline = deadline
        self.now = now
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
    /// - Parameter attempt: Connects to the daemon and asks it to attach the lease.
    /// - Returns: The result of the first attempt that succeeds, or `nil` when the task is
    ///   cancelled first.
    /// - Throws: The error of the last attempt if it fails at or after the deadline, or the error
    ///   of an attempt that fails for a reason other than a failed or closed connection.
    func run<Value>(_ attempt: () async throws(CommandError) -> Value) async throws(CommandError) -> Value? {
        var next = Self.firstPause
        while !Task.isCancelled {
            do throws(CommandError) {
                return try await attempt()
            } catch {
                let remaining = deadline.timeIntervalSince(now())
                guard Self.isTransient(error), remaining > 0 else {
                    throw error
                }
                await pause(min(next, .seconds(remaining)))
                next = min(next * 2, Self.longestPause)
            }
        }
        return nil
    }

    /// Reports whether another attempt may succeed after an error.
    ///
    /// - Parameter error: The error of an attempt.
    /// - Returns: Whether the connection failed or closed. An unknown host or an unreadable key
    ///   stays the same on the next attempt.
    static func isTransient(_ error: CommandError) -> Bool {
        switch error {
        case .pool(.connection), .pool(.connectionClosed), .pool(.daemonUnreachable):
            true
        default:
            false
        }
    }
}
