import ArgumentParser
import Foundation
import Logging
@testable import MacpoolCLI
@testable import MacpoolPool
import Synchronization
import Testing

/// Tests of the commands that pair Macs and end their pairings.
struct PairingCommandTests {
    /// Prints a code with the listener's address and then the Mac that pairs with it.
    @Test func invitesAMac() async throws {
        let host = try await PairingDaemon()
        let invitation = try await host.invite("--priority-ceiling", "3")
        #expect(invitation.code.address == "127.0.0.1")
        #expect(invitation.code.port == host.port)
        #expect(invitation.output.all.count == 2)
        #expect(invitation.output.all.last?.hasPrefix("expires_at=") == true)

        let client = try host.clientDirectory()
        let paired = try await PoolClient.pair(using: invitation.code, name: "runner", directory: client)
        #expect(paired.name == "lab")
        let key = try PairingDaemon.key(of: client)
        #expect(try await invitation.finish() == ["paired \(PeerText.name("runner", key: key))"])
        let clients = try TrustedClient.paired(in: host.directory)
        #expect(clients.map(\.key) == [key])
        #expect(clients.first?.priorityCeiling == 3)
        await host.stop()
    }

    /// Gives the other Mac the address of `--address` instead of the listener's address.
    @Test func invitesWithAnotherAddress() async throws {
        let host = try await PairingDaemon()
        let invitation = try await host.invite("--address", "lab.example")
        #expect(invitation.code.address == "lab.example")
        invitation.task.cancel()
        await host.stop()
    }

    /// Warns about a wrong code and keeps the invitation open for the right one.
    @Test func warnsAboutAWrongCode() async throws {
        let host = try await PairingDaemon()
        let invitation = try await host.invite()
        let code = invitation.code
        let wrong = try PairingCode(
            address: code.address,
            port: code.port,
            hostKey: PairingDaemon.key(of: host.directory),
            secret: [UInt8](repeating: 0, count: PairingCode.secretBytes),
        )
        let client = try host.clientDirectory()
        await #expect(throws: PoolError.self) {
            try await PoolClient.pair(using: wrong, name: "runner", directory: client)
        }
        _ = try await PoolClient.pair(using: code, name: "runner", directory: client)
        let lines = try await invitation.finish()
        #expect(invitation.warnings.all == ["A Mac sent a wrong code. The invitation stays open."])
        #expect(lines.first?.hasPrefix("paired ") == true)
        await host.stop()
    }

    /// Reports a Mac that had paired before.
    @Test func reportsAMacThatPairedBefore() async throws {
        let host = try await PairingDaemon()
        let client = try host.clientDirectory()
        let first = try await host.invite()
        _ = try await PoolClient.pair(using: first.code, name: "runner", directory: client)
        _ = try await first.finish()

        let second = try await host.invite()
        _ = try await PoolClient.pair(using: second.code, name: "renamed", directory: client)
        let key = try PairingDaemon.key(of: client)
        #expect(try await second.finish() == ["already paired \(PeerText.name("runner", key: key))"])
        await host.stop()
    }

    /// Fails with the daemon's reason when the daemon does not listen for paired Macs.
    @Test func failsWithoutAListener() async throws {
        let host = try await PairingDaemon(listening: false)
        let command = try #require(
            try Macpool.parseAsRoot(["host", "invite", "--data-dir", host.path]) as? HostInviteCommand,
        )
        await #expect(throws: CommandError.pool(.daemonRefused(message: "the host does not listen for paired Macs"))) {
            try await command.perform(printing: { _ in }, warning: { _ in })
        }
        await host.stop()
    }

    /// Rejects a negative priority ceiling before it asks the daemon.
    @Test func refusesANegativeCeiling() {
        #expect(throws: (any Error).self) {
            try Macpool.parseAsRoot(["host", "invite", "--priority-ceiling", "-1"])
        }
    }

    /// Revokes a Mac by its short key in any case and prints what ended.
    @Test func revokesAMac() async throws {
        let host = try await PairingDaemon()
        let client = try host.clientDirectory()
        let invitation = try await host.invite()
        _ = try await PoolClient.pair(using: invitation.code, name: "runner", directory: client)
        _ = try await invitation.finish()
        let key = try PairingDaemon.key(of: client)

        let revoke = try #require(
            try Macpool.parseAsRoot(["host", "revoke", "--data-dir", host.path, key.shortKey.uppercased()])
                as? HostRevokeCommand,
        )
        #expect(try await revoke.lines() == ["revoked \(PeerText.name("runner", key: key)) connections=0 leases=0"])
        #expect(try TrustedClient.paired(in: host.directory).first?.isBlocked == true)

        let unknown = try #require(
            try Macpool.parseAsRoot(["host", "revoke", "--data-dir", host.path, "aaaa-aaaa-aaaa-aaaa"])
                as? HostRevokeCommand,
        )
        let error = await #expect(throws: CommandError.self) {
            try await unknown.lines()
        }
        #expect(error?.description.contains("no paired Mac has the key aaaa-aaaa-aaaa-aaaa") == true)
        await host.stop()
    }
}

/// A daemon in the test process that listens for paired Macs on 127.0.0.1 under the name `lab`.
///
/// The daemon launches no supervisors, because the tests lease nothing.
private final class PairingDaemon {
    /// The temporary directory that holds the data directories.
    private let parent: URL

    /// The daemon's data directory.
    let directory: PoolDirectory

    /// The daemon.
    let daemon: PoolDaemon

    /// The port of the listener, or 0 without one.
    let port: UInt16

    /// The number of client directories that ``clientDirectory()`` created.
    private var clients = 0

    /// Starts the daemon and waits until it listens.
    ///
    /// - Parameter listening: Whether the daemon listens for paired Macs.
    /// - Throws: An error when the daemon does not start or does not listen within 10 seconds.
    init(listening: Bool = true) async throws {
        parent = FileManager.default.temporaryDirectory
            .appending(path: "mp-" + UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        directory = PoolDirectory(root: parent.appending(path: "pool", directoryHint: .isDirectory))
        let peers = PeerSettings(name: "lab", address: "127.0.0.1", port: 0, retryInterval: .milliseconds(100))
        daemon = try PoolDaemon(configuration: PoolDaemon.Configuration(
            directory: directory,
            launcher: ProcessSupervisorLauncher(executable: URL(filePath: "/usr/bin/false")),
            peers: listening ? peers : nil,
            tickInterval: nil,
            logger: Logger(label: "macpool.test") { _ in SwiftLogNoOpLogHandler() },
        ))
        try await daemon.start()
        guard listening else {
            port = 0
            return
        }
        let deadline = ContinuousClock.now + .seconds(10)
        var port = await daemon.peerPort
        while port == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            port = await daemon.peerPort
        }
        self.port = try #require(port)
    }

    /// Removes the data directories.
    deinit {
        try? FileManager.default.removeItem(at: parent)
    }

    /// The data directory's path for `--data-dir`.
    var path: String {
        directory.root.path(percentEncoded: false)
    }

    /// Runs `macpool host invite` with the options and waits for its code.
    ///
    /// - Parameter options: The options after `--data-dir`.
    /// - Returns: The running invitation.
    /// - Throws: An error when the options do not parse or the command ends before it prints a code.
    func invite(_ options: String...) async throws -> RunningInvitation {
        let command = try #require(
            try Macpool.parseAsRoot(["host", "invite", "--data-dir", path] + options) as? HostInviteCommand,
        )
        let output = PrintedLines()
        let warnings = PrintedLines()
        let task = Task { try await command.perform(printing: output.append, warning: warnings.append) }
        let deadline = ContinuousClock.now + .seconds(10)
        while output.all.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let line = output.all.first, line.hasPrefix("code="),
              let code = PairingCode(String(line.dropFirst(5))) else {
            task.cancel()
            throw PoolError.connectionClosed
        }
        return RunningInvitation(code: code, output: output, warnings: warnings, task: task)
    }

    /// Creates the data directory of a client Mac inside the host's temporary directory.
    ///
    /// - Returns: The data directory. It does not exist yet.
    func clientDirectory() throws -> PoolDirectory {
        clients += 1
        return PoolDirectory(root: parent.appending(path: "client\(clients)", directoryHint: .isDirectory))
    }

    /// Returns the fingerprint of the key in a data directory.
    ///
    /// - Parameter directory: The data directory.
    /// - Returns: The fingerprint.
    /// - Throws: ``PoolError`` when the key cannot be read or created.
    static func key(of directory: PoolDirectory) throws -> KeyFingerprint {
        try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: directory).keyDigest)
    }

    /// Stops the daemon.
    func stop() async {
        await daemon.shutdown()
    }
}

/// The lines that a command printed, in order.
private final class PrintedLines: Sendable {
    /// The lines.
    private let lines = Mutex<[String]>([])

    /// Records a line.
    ///
    /// - Parameter line: The line without a line break.
    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    /// The lines so far.
    var all: [String] {
        lines.withLock { $0 }
    }
}

/// A run of `macpool host invite` in a task.
private struct RunningInvitation {
    /// The code that the command printed.
    let code: PairingCode

    /// The lines on standard output.
    let output: PrintedLines

    /// The warnings on standard error.
    let warnings: PrintedLines

    /// The task that runs the command.
    let task: Task<Void, any Error>

    /// Waits until the command ends.
    ///
    /// - Returns: The lines that the command printed after `code=` and `expires_at=`.
    /// - Throws: The command's error.
    func finish() async throws -> [String] {
        try await task.value
        return Array(output.all.dropFirst(2))
    }
}
