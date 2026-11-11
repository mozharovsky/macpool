import Foundation
import Logging

/// A kind of log line that a Mac on the network can make the daemon write again and again.
enum PeerLogLine: Hashable, Sendable {
    /// A paired Mac connected.
    ///
    /// The line names the Mac's address. The rate counts only the key, because the Mac chooses
    /// its address.
    case connected(KeyFingerprint)

    /// A paired Mac opened a connection beyond ``PoolDaemon/connectionsPerPeer``.
    case tooManyConnections(KeyFingerprint)

    /// A Mac connected to pair while ``PoolDaemon/pairingConnectionLimit`` Macs paired.
    case tooManyPairings

    /// A paired client's request found the list of paired clients unreadable.
    case unreadableClientList
}

/// The levels of log lines that Macs on the network can repeat.
///
/// The LaunchAgent runs the daemon at the info level, and nothing rotates its log. The rate
/// writes each ``PeerLogLine`` at its full level at most once per ``interval``. In between, the
/// line goes to the debug level.
///
/// The daemon writes a line with a key only for a paired client. The rate keeps only the times
/// of the last ``interval``. It therefore holds at most two times for each client that was paired
/// in that time, and one for each other kind of line.
struct PeerLogRate {
    /// The shortest time between two lines of one kind at their full level, in seconds.
    static let interval: TimeInterval = 60

    /// When each line was last written at its full level, within the last ``interval``.
    private(set) var times: [PeerLogLine: Date] = [:]

    /// Returns the level for a line and records the time if the level is the full one.
    ///
    /// If the clock went back since the last time of the line, the line is due again. A clock
    /// that moved back therefore cannot keep a line at the debug level.
    ///
    /// - Parameters:
    ///   - line: The kind of line.
    ///   - full: The level of the line when it is due.
    ///   - now: The current time.
    /// - Returns: `full` if the line was not written at that level within the last ``interval``,
    ///   or `.debug`.
    mutating func level(of line: PeerLogLine, full: Logger.Level, at now: Date) -> Logger.Level {
        times = times.filter { (0 ..< Self.interval).contains(now.timeIntervalSince($0.value)) }
        guard times[line] == nil else {
            return .debug
        }
        times[line] = now
        return full
    }
}
