public import Foundation
import Synchronization

/// The socket through which a VM supervisor reports its status and accepts a stop.
///
/// The supervisor publishes each change of its VM's stage. Every connection receives the current
/// status first and each later one in order, so a daemon that connects after a restart learns
/// the stage at once. A ``SupervisorCommand/Kind/stop`` command from any connection calls the
/// stop handler.
public final class SupervisorServer: Sendable {
    /// The status and connections that the listener and the publisher share.
    private final class Core: Sendable {
        /// The shared values.
        private struct State {
            /// The latest status.
            var status: SupervisorStatus
            /// The open connections.
            var channels: [ObjectIdentifier: MessageChannel] = [:]
        }

        /// The protected values.
        private let state: Mutex<State>

        /// The handler for stop commands.
        let onStop: @Sendable () -> Void

        /// Creates the shared values.
        ///
        /// - Parameters:
        ///   - status: The first status.
        ///   - onStop: The handler for stop commands.
        init(status: SupervisorStatus, onStop: @escaping @Sendable () -> Void) {
            state = Mutex(State(status: status))
            self.onStop = onStop
        }

        /// Sends the current status to a new connection and serves its commands until it ends.
        ///
        /// - Parameter channel: The new connection.
        func serve(_ channel: MessageChannel) async {
            let key = ObjectIdentifier(channel)
            state.withLock { state in
                state.channels[key] = channel
                try? channel.send(state.status)
            }
            while let command = try? await channel.receive(SupervisorCommand.self) {
                switch command.command {
                case .stop:
                    onStop()
                }
            }
            state.withLock { _ = $0.channels.removeValue(forKey: key) }
            channel.close()
        }

        /// Records a status and sends it to every connection.
        ///
        /// - Parameter status: The new status.
        func publish(_ status: SupervisorStatus) {
            state.withLock { state in
                state.status = status
                for channel in state.channels.values {
                    try? channel.send(status)
                }
            }
        }

        /// Delivers the queued statuses and closes every connection.
        func finishAll() async {
            let channels = state.withLock { state in
                defer { state.channels = [:] }
                return Array(state.channels.values)
            }
            for channel in channels {
                await channel.finish()
            }
        }
    }

    /// The listening socket.
    private let listener: SocketListener

    /// The shared status and connections.
    private let core: Core

    /// The task that accepts connections.
    private let accepting: Task<Void, Never>

    /// Starts listening with an initial status.
    ///
    /// - Parameters:
    ///   - socket: The socket file, which the call replaces when it exists.
    ///   - status: The status that the first connections receive.
    ///   - onStop: The handler that a stop command calls. It may run several times and from any
    ///     thread.
    /// - Throws: ``PoolError`` when the socket cannot listen.
    public init(
        socket: URL,
        status: SupervisorStatus,
        onStop: @escaping @Sendable () -> Void,
    ) async throws(PoolError) {
        let listener = try await SocketListener(socket: socket)
        let core = Core(status: status, onStop: onStop)
        self.listener = listener
        self.core = core
        accepting = Task {
            await withDiscardingTaskGroup { group in
                for await channel in listener.connections {
                    group.addTask { await core.serve(channel) }
                }
            }
        }
    }

    /// Records a status and sends it to every connection.
    ///
    /// - Parameter status: The new status.
    public func publish(_ status: SupervisorStatus) {
        core.publish(status)
    }

    /// Stops listening, removes the socket, delivers the queued statuses, and closes every
    /// connection.
    public func close() async {
        listener.close()
        await core.finishAll()
        accepting.cancel()
    }
}
