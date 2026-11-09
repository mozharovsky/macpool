import Foundation
import Network
import Synchronization

/// A check whether a guest's SSH server accepts connections.
public enum SSHProbe {
    /// The first bytes of every SSH server's identification string.
    static let bannerPrefix = Data("SSH-".utf8)

    /// Reports whether an SSH server answers with its protocol banner.
    ///
    /// An open port alone is not enough, because the guest's `launchd` accepts connections on port
    /// 22 before `sshd` is ready to answer them.
    ///
    /// - Parameters:
    ///   - host: The server's IPv4 or IPv6 address or host name.
    ///   - port: The server's TCP port.
    ///   - timeout: The longest time for connecting and reading the banner.
    /// - Returns: `true` when the server sent a banner in time, and `false` otherwise.
    public static func answers(host: String, port: UInt16 = 22, timeout: Duration = .seconds(3)) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            return false
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "macpool.ssh-probe")
        let outcome = ProbeOutcome(connection: connection)
        return await withCheckedContinuation { continuation in
            outcome.install(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let length = bannerPrefix.count
                    connection.receive(minimumIncompleteLength: length, maximumLength: length) { content, _, _, _ in
                        outcome.finish(content == bannerPrefix)
                    }
                case .waiting, .failed, .cancelled:
                    outcome.finish(false)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(timeout / .nanoseconds(1)))) {
                outcome.finish(false)
            }
        }
    }
}

/// The single result of one probe, which the first of several callbacks decides.
///
/// The connection's state handler, its receive handler, and the timeout race to finish the probe.
/// Only the first one resumes the waiting task and cancels the connection.
private final class ProbeOutcome: Sendable {
    /// The connection to cancel when the probe ends.
    private let connection: NWConnection

    /// The waiting task until the probe ends.
    private let continuation = Mutex<CheckedContinuation<Bool, Never>?>(nil)

    /// Creates the outcome of a probe over a connection.
    ///
    /// - Parameter connection: The connection that the probe uses.
    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Stores the task that waits for the result.
    ///
    /// - Parameter continuation: The waiting task's continuation.
    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    /// Ends the probe unless an earlier callback already did.
    ///
    /// - Parameter answered: Whether the server sent its banner.
    func finish(_ answered: Bool) {
        guard let continuation = continuation.withLock({ $0.take() }) else {
            return
        }
        connection.cancel()
        continuation.resume(returning: answered)
    }
}
