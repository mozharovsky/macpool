import Foundation
import Logging
import Synchronization

/// A kind of log line that a Mac on the network can make the daemon write again and again.
enum PeerLogLine: Hashable, Sendable {
    /// A paired Mac connected.
    ///
    /// The line names the Mac's address. The rate counts only the key, because the Mac chooses
    /// its address.
    case connected(KeyFingerprint)

    /// A paired Mac opened a connection beyond ``PoolDaemon/connectionsPerPeer``.
    case tooManyConnections(KeyFingerprint)

    /// A paired Mac sent nothing for ``PoolDaemon/peerSilenceLimit``, and the daemon closed its
    /// connection.
    case silent(KeyFingerprint)

    /// A Mac connected to pair while ``PoolDaemon/pairingConnectionLimit`` Macs paired.
    case tooManyPairings

    /// The listener for paired Macs refused a connection because the connections from its
    /// ``HandshakeSource`` held the most handshake places that one source may hold.
    ///
    /// The line names the address. The rate counts no address, because the Mac chooses it.
    case tooManyHandshakes

    /// The listener for paired Macs refused a connection from an address outside
    /// ``PeerSettings/allowedSources``.
    ///
    /// The line names the address. The rate counts no address, because the Mac chooses it.
    case outsideAllowedSources

    /// A paired client's request found the list of paired clients unreadable.
    case unreadableClientList

    /// A paired client asked the host to forget it, and the host could not update the list of
    /// paired clients.
    case unsavedClientList

    /// A paired client asked for an offered source whose settings cannot be read.
    ///
    /// The value is the source's name in ``PoolDaemon/Configuration/offeredSources``.
    case unreadableSource(String)

    /// A reply to a paired client named a host path, and the daemon sent a failure instead.
    case hostPathInReply
}

/// The levels of log lines that Macs on the network can repeat.
///
/// The LaunchAgent runs the daemon at the info level, and nothing rotates its log. The rate
/// writes each ``PeerLogLine`` at its full level at most once per ``interval``. In between, the
/// line goes to the debug level.
///
/// The daemon writes a line with a key only for a paired client, and a line with a source only
/// for an offered source. The rate keeps only the times of the last ``interval``. It therefore
/// holds at most three times for each client that was paired in that time, one for each offered
/// source, and one for each other kind of line.
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

/// A ``PeerLogRate`` that several threads share.
///
/// The listener for paired Macs refuses connections on its own queue, outside the daemon's actor.
/// It keeps its own rate for the lines that it writes.
final class LockedPeerLogRate: Sendable {
    /// The rate.
    private let rate = Mutex(PeerLogRate())

    /// The source of the current time.
    private let now: @Sendable () -> Date

    /// Creates a rate that has written no line.
    ///
    /// - Parameter now: The source of the current time.
    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    /// Returns the level for a line and records the time if the level is the full one.
    ///
    /// - Parameters:
    ///   - line: The kind of line.
    ///   - full: The level of the line when it is due.
    /// - Returns: `full` if the line was not written at that level within the last
    ///   ``PeerLogRate/interval``, or `.debug`.
    func level(of line: PeerLogLine, full: Logger.Level) -> Logger.Level {
        let now = now()
        return rate.withLock { $0.level(of: line, full: full, at: now) }
    }
}
