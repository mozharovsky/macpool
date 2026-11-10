import Foundation
@testable import MacpoolPool
import Network
import Testing

/// Tests of socket paths that Network would truncate or that do not fit in a socket address.
///
/// Each test makes its aliases in its own directories, so no link stays in the user's temporary
/// directory.
@Suite(.timeLimit(.minutes(1)))
struct SocketPathTests {
    /// A run directory and two directories for aliases of it.
    private struct Scratch {
        /// The directory that the test removes at the end.
        let root: ShortDirectory

        /// The directory that holds the sockets.
        let run: URL

        /// The listener's alias directory.
        let listenerAliases: URL

        /// The client's alias directory, which differs from the listener's.
        let clientAliases: URL

        /// Creates the directories.
        ///
        /// - Parameter name: The run directory's name.
        /// - Throws: An error when a directory cannot be created.
        init(run name: String) throws {
            root = try ShortDirectory()
            run = root.url.appending(path: name, directoryHint: .isDirectory)
            listenerAliases = root.url.appending(path: "a", directoryHint: .isDirectory)
            clientAliases = root.url.appending(path: "b", directoryHint: .isDirectory)
            for directory in [run, listenerAliases, clientAliases] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700],
                )
            }
        }
    }

    /// The name that Network gives a socket file for a path, with one byte per character.
    ///
    /// - Parameter path: The socket path.
    /// - Returns: The truncated path.
    private static func truncated(_ path: String) -> String {
        String(decoding: path.utf8.prefix(path.count), as: UTF8.self)
    }

    /// Checks whether a file is a socket.
    ///
    /// - Parameter path: The file's path.
    /// - Returns: Whether the file exists and is a socket.
    private static func isSocket(_ path: String) -> Bool {
        let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType
        return type == .typeSocket
    }

    /// Exchanges one request and one reply between a listener and a client.
    ///
    /// - Parameters:
    ///   - listener: The listener.
    ///   - client: A client connected to the listener.
    /// - Throws: An error when a message does not arrive.
    private static func exchange(_ listener: SocketListener, _ client: MessageChannel) async throws {
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())
        try client.send(PoolRequest.status)
        #expect(try await server.receive(PoolRequest.self) == .status)
        try server.send(PoolReply.queued(position: 1))
        #expect(try await client.receive(PoolReply.self) == .queued(position: 1))
        client.close()
        server.close()
    }

    /// Tells the paths that Network keeps from the ones that need an alias.
    @Test func classifiesPaths() {
        #expect(SocketPath.isExact("/tmp/pool/run/daemon.sock"))
        #expect(!SocketPath.isExact("/tmp/caf\u{E9}/run/daemon.sock"))
        // A carriage return and a line feed form one character.
        #expect(!SocketPath.isExact("/tmp/a\r\nb/run/daemon.sock"))
        #expect(SocketPath.isExact("/" + String(repeating: "x", count: 102)))
        #expect(!SocketPath.isExact("/" + String(repeating: "x", count: 103)))
        // Only a short inexact path had a truncated socket in earlier builds.
        #expect(SocketPath.hasTruncatedName("/tmp/caf\u{E9}/run/daemon.sock"))
        #expect(!SocketPath.hasTruncatedName("/tmp/pool/run/daemon.sock"))
        #expect(!SocketPath.hasTruncatedName("/" + String(repeating: "x", count: 103)))
        #expect(!SocketPath.hasTruncatedName("/" + String(repeating: "\u{E9}", count: 60)))
    }

    /// Creates the socket under its full name in the real directory through an alias, and a
    /// client with another alias of that directory connects.
    @Test func listensUnderFullNameThroughAlias() async throws {
        let scratch = try Scratch(run: "caf\u{E9} \t\u{43A}")
        let socket = scratch.run.appending(path: "daemon.sock")
        let path = socket.path(percentEncoded: false)
        let listener = try await SocketListener(socket: socket, aliasDirectory: scratch.listenerAliases)
        defer { listener.close() }
        #expect(Self.isSocket(path))
        #expect(!FileManager.default.fileExists(atPath: Self.truncated(path)))
        let links = try FileManager.default
            .contentsOfDirectory(atPath: scratch.listenerAliases.path(percentEncoded: false))
        #expect(links.count == 1)
        let client = try await MessageChannel.connect(
            to: socket,
            timeout: .seconds(10),
            aliasDirectory: scratch.clientAliases,
        )
        let clientLinks = try FileManager.default
            .contentsOfDirectory(atPath: scratch.clientAliases.path(percentEncoded: false))
        #expect(clientLinks == links)
        try await Self.exchange(listener, client)
    }

    /// Listens and connects on a path that is too long for a socket address.
    @Test func listensOnLongPath() async throws {
        let scratch = try Scratch(run: String(repeating: "x", count: 100))
        let socket = scratch.run.appending(path: "daemon.sock")
        let path = socket.path(percentEncoded: false)
        #expect(path.utf8.count >= SocketPath.capacity)
        let listener = try await SocketListener(socket: socket, aliasDirectory: scratch.listenerAliases)
        defer { listener.close() }
        #expect(Self.isSocket(path))
        let client = try await MessageChannel.connect(
            to: socket,
            timeout: .seconds(10),
            aliasDirectory: scratch.clientAliases,
        )
        try await Self.exchange(listener, client)
    }

    /// Listens under the full name while an earlier build's file holds the truncated name.
    @Test func ignoresFileUnderTruncatedName() async throws {
        let scratch = try Scratch(run: "caf\u{E9}")
        let socket = scratch.run.appending(path: "daemon.sock")
        let stale = Self.truncated(socket.path(percentEncoded: false))
        #expect(stale.hasSuffix("/daemon.so"))
        #expect(FileManager.default.createFile(atPath: stale, contents: Data()))
        let listener = try await SocketListener(socket: socket, aliasDirectory: scratch.listenerAliases)
        defer { listener.close() }
        let client = try await MessageChannel.connect(
            to: socket,
            timeout: .seconds(10),
            aliasDirectory: scratch.clientAliases,
        )
        try await Self.exchange(listener, client)
        #expect(FileManager.default.fileExists(atPath: stale))
    }

    /// Reaches a listener that an earlier build started on the truncated name, as a supervisor
    /// from before an upgrade does.
    @Test func reachesListenerOfEarlierBuild() async throws {
        let scratch = try Scratch(run: "caf\u{E9}")
        let socket = scratch.run.appending(path: "0a1b2c3d.sock")
        let path = socket.path(percentEncoded: false)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let legacy = try NWListener(using: parameters)
        legacy.newConnectionHandler = { $0.cancel() }
        let ready = AsyncStream.makeStream(of: Bool.self)
        legacy.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.continuation.yield(true)
            case .failed, .cancelled:
                ready.continuation.yield(false)
            default:
                break
            }
        }
        legacy.start(queue: DispatchQueue(label: "legacy"))
        defer { legacy.cancel() }
        var states = ready.stream.makeAsyncIterator()
        #expect(await states.next() == true)
        #expect(Self.isSocket(Self.truncated(path)))
        #expect(!FileManager.default.fileExists(atPath: path))
        let client = try await MessageChannel.connect(
            to: socket,
            timeout: .seconds(10),
            aliasDirectory: scratch.clientAliases,
        )
        client.close()
    }

    /// Reports the socket path and its length when the alias does not fit either, and refuses
    /// an alias directory that others can enter.
    @Test func refusesUnusableAlias() async throws {
        let scratch = try Scratch(run: "caf\u{E9}")
        let socket = scratch.run.appending(path: "daemon.sock")
        let path = socket.path(percentEncoded: false)
        let deep = scratch.root.url.appending(path: String(repeating: "y", count: 100), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: deep,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700],
        )
        await #expect(throws: PoolError.socketPathTooLong(path: path, length: path.utf8.count)) {
            try await SocketListener(socket: socket, aliasDirectory: deep)
        }
        #expect(PoolError.socketPathTooLong(path: path, length: 30).description.contains("30 bytes"))
        #expect(chmod(scratch.listenerAliases.path(percentEncoded: false), 0o755) == 0)
        await #expect {
            try await SocketListener(socket: socket, aliasDirectory: scratch.listenerAliases)
        } throws: { error in
            if case .insecureDirectory = error as? PoolError {
                true
            } else {
                false
            }
        }
    }
}
