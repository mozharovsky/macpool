import Foundation
import MacpoolVM
import Network
import Testing

/// Tests of the SSH banner check against local listeners.
struct SSHProbeTests {
    /// A loopback TCP listener that sends a fixed greeting to every client.
    final class GreetingServer: Sendable {
        /// The listener.
        private let listener: NWListener

        /// The queue of the listener and its connections.
        private let queue = DispatchQueue(label: "macpool.tests.greeting")

        /// Starts a listener on a free loopback port.
        ///
        /// - Parameter greeting: The bytes that each client receives.
        /// - Throws: An error when the listener cannot be created.
        init(greeting: String) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
            let queue = queue
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.send(content: Data(greeting.utf8), completion: .contentProcessed { _ in })
            }
        }

        /// Starts accepting clients and returns the bound port.
        ///
        /// - Returns: The port that clients connect to.
        func start() async -> UInt16 {
            await withCheckedContinuation { continuation in
                listener.stateUpdateHandler = { [listener] state in
                    if case .ready = state, let port = listener.port {
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: port.rawValue)
                    }
                }
                listener.start(queue: queue)
            }
        }

        /// Stops accepting clients.
        func stop() {
            listener.cancel()
        }
    }

    /// Reports an SSH server that sends its banner.
    @Test func acceptsBanner() async throws {
        let server = try GreetingServer(greeting: "SSH-2.0-OpenSSH_9.9\r\n")
        let port = await server.start()
        defer { server.stop() }
        #expect(await SSHProbe.answers(host: "127.0.0.1", port: port, timeout: .seconds(5)))
    }

    /// Rejects a server that answers with something other than an SSH banner.
    @Test func rejectsOtherGreeting() async throws {
        let server = try GreetingServer(greeting: "HTTP/1.1 400 Bad Request\r\n")
        let port = await server.start()
        defer { server.stop() }
        #expect(await !SSHProbe.answers(host: "127.0.0.1", port: port, timeout: .seconds(5)))
    }

    /// Returns promptly when nothing listens on the port.
    @Test func rejectsClosedPort() async {
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await !SSHProbe.answers(host: "127.0.0.1", port: 9, timeout: .seconds(2)))
        #expect(clock.now - started < .seconds(4))
    }
}
