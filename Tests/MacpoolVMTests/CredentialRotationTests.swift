import Foundation
import Logging
@testable import MacpoolVM
import Synchronization
import Testing

/// Tests of the rotation's guest script, its encodings, and its state transitions.
struct CredentialRotationTests {
    /// Encodes the automatic login password as macOS stores it in `/etc/kcpassword`.
    @Test func encodesAutoLoginPassword() {
        var generator = GuestAccountTests.SequenceGenerator(state: 7)
        for password in ["a", "elevenchars", "twelve-chars", "an-eighteen-chars!", "a-password-of-24-chars!!"] {
            let data = CredentialRotation.autoLoginData(for: password, using: &generator)
            #expect(data.count.isMultiple(of: 12))
            #expect(data.count > password.utf8.count)
            let key = CredentialRotation.autoLoginKey
            let decoded = data.enumerated().map { index, byte in byte ^ key[index % key.count] }
            #expect(Array(decoded.prefix(password.utf8.count)) == Array(password.utf8))
            #expect(decoded[password.utf8.count] == 0)
        }
    }

    /// Keeps the root script free of single quotes, because the command line wraps it in them.
    @Test func scriptNeedsNoQuoting() {
        #expect(!CredentialRotation.rootScript.contains("'"))
        #expect(CredentialRotation.rootScript.hasPrefix("set -eu\n"))
        #expect(CredentialRotation.rootScript.hasSuffix("/bin/cat /etc/ssh/ssh_host_ed25519_key.pub"))
    }

    /// Accepts user names and passwords that need no quoting and rejects the rest.
    @Test func checksAccountCharacters() {
        #expect(CredentialRotation.isPlainUsername("macpool"))
        #expect(CredentialRotation.isPlainUsername("ci.runner_2-a"))
        #expect(!CredentialRotation.isPlainUsername(""))
        #expect(!CredentialRotation.isPlainUsername("-o"))
        #expect(!CredentialRotation.isPlainUsername("a b"))
        #expect(!CredentialRotation.isPlainUsername("a'b"))
        #expect(!CredentialRotation.isPlainUsername("ä"))
        #expect(CredentialRotation.isPlainPassword("Ab3xYz9"))
        #expect(!CredentialRotation.isPlainPassword(""))
        #expect(!CredentialRotation.isPlainPassword("a b"))
        #expect(!CredentialRotation.isPlainPassword("a\"b"))
    }

    /// Refuses a bundle without a pending rotation before it contacts any guest.
    @Test func refusesBundleWithoutPendingRotation() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: nil)
        let guest = try ScriptedGuest(directory: directory, replies: [])
        await #expect(throws: MacpoolError.credentialRotation(
            step: "starting",
            reason: "the bundle has no pending rotation",
        )) {
            try await Self.rotate(bundle, through: guest)
        }
        #expect(try bundle.settings().credentialRotation == nil)
        #expect(guest.calls.isEmpty)
    }

    /// Replaces the account and the pin and records the finished rotation.
    @Test func finishesRotation() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .pending)
        let inherited = try GuestAccount.load(from: bundle.guestAccountFile)
        let guest = try ScriptedGuest(directory: directory, replies: [
            .success(""),
            .success("ssh-ed25519 \(HostKeyTests.second) root@guest\n"),
            .success(""),
        ])

        let key = try await Self.rotate(bundle, through: guest)

        #expect(key.base64 == HostKeyTests.second)
        #expect(try bundle.settings().credentialRotation == .finished)
        let account = try GuestAccount.load(from: bundle.guestAccountFile)
        #expect(account.username == inherited.username)
        #expect(account.password != inherited.password)
        #expect(try Self.permissions(of: bundle.guestAccountFile) == 0o600)
        let pin = try String(contentsOf: bundle.knownHostsFile, encoding: .utf8)
        #expect(pin == "macpool-guest ssh-ed25519 \(HostKeyTests.second)\n")
        #expect(try Self.permissions(of: bundle.knownHostsFile) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: bundle.rotatingGuestAccountFile.filePath))

        let calls = guest.calls
        try #require(calls.count == 3)
        #expect(calls[0].knownHosts == "macpool-guest ssh-ed25519 \(HostKeyTests.first)\n")
        #expect(!calls[0].trustsFirstKey)
        #expect(calls[1].knownHosts == calls[0].knownHosts)
        let input = calls[1].input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        try #require(input.count == 6)
        #expect(input[0] == inherited.password)
        #expect(input[1] == inherited.password)
        #expect(input[2] == account.password)
        #expect(input[3].count.isMultiple(of: 24))
        #expect(input[4] == CredentialRotation.inputEndMarker)
        #expect(input[5].isEmpty)
        #expect(calls[2].accountFile == bundle.rotatingGuestAccountFile)
        #expect(calls[2].knownHosts == pin)
        #expect(!calls[2].trustsFirstKey)
        for call in calls {
            #expect(call.username == inherited.username)
            #expect(!call.command.contains(inherited.password))
            #expect(!call.command.contains(account.password))
        }
    }

    /// Trusts the first key only when the bundle has no `known_hosts` file.
    @Test func trustsFirstKeyWithoutKnownHosts() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .pending)
        try FileManager.default.removeItem(at: bundle.knownHostsFile)
        let guest = try ScriptedGuest(directory: directory, replies: [
            .success(""),
            .success("ssh-ed25519 \(HostKeyTests.second)\n"),
            .success(""),
        ])

        _ = try await Self.rotate(bundle, through: guest)

        let calls = guest.calls
        try #require(calls.count == 3)
        #expect(calls[0].knownHosts.isEmpty)
        #expect(calls[0].trustsFirstKey)
        #expect(calls[1].trustsFirstKey)
        #expect(!calls[2].trustsFirstKey)
        #expect(try bundle.settings().credentialRotation == .finished)
    }

    /// Fails on a `known_hosts` file that exists and cannot be read, before any login.
    @Test func failsOnUnreadableKnownHosts() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .pending)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: bundle.knownHostsFile.filePath)
        let guest = try ScriptedGuest(directory: directory, replies: [])

        await #expect {
            try await Self.rotate(bundle, through: guest)
        } throws: { error in
            guard case .fileSystem = error as? MacpoolError else {
                return false
            }
            return true
        }
        #expect(guest.calls.isEmpty)
        #expect(try bundle.settings().credentialRotation == .pending)
    }

    /// Keeps the rotation pending when the inherited account never logs in.
    @Test func keepsPendingAfterFailedFirstLogin() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .pending)
        let account = try Data(contentsOf: bundle.guestAccountFile)
        let refused = GuestCommandResult(succeeded: false, status: "exited(255)", output: "", errorOutput: "denied")
        let guest = try ScriptedGuest(
            directory: directory,
            replies: Array(repeating: .result(refused), count: CredentialRotation.loginAttempts),
        )

        await #expect(throws: MacpoolError.credentialRotation(
            step: "logging in with the inherited account",
            reason: refused.failureSummary,
        )) {
            try await Self.rotate(bundle, through: guest)
        }
        #expect(guest.calls.count == CredentialRotation.loginAttempts)
        #expect(try bundle.settings().credentialRotation == .pending)
        #expect(try Data(contentsOf: bundle.guestAccountFile) == account)
        #expect(!FileManager.default.fileExists(atPath: bundle.rotatingGuestAccountFile.filePath))
    }

    /// Leaves the started record and the private next account when the guest script fails.
    @Test func keepsStartedAfterFailedScript() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .pending)
        let failed = GuestCommandResult(succeeded: false, status: "exited(1)", output: "", errorOutput: "dscl failed")
        try await Self.expectStarted(bundle, in: directory, replies: [.success(""), .result(failed)])
        #expect(try Self.permissions(of: bundle.rotatingGuestAccountFile) == 0o600)
    }

    /// Leaves the started record when the guest prints no Ed25519 key.
    @Test func keepsStartedWithoutNewKey() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .pending)
        try await Self.expectStarted(bundle, in: directory, replies: [.success(""), .success("done\n")])
    }

    /// Leaves the started record when the new account never logs in.
    @Test func keepsStartedAfterFailedVerification() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .pending)
        let refused = GuestCommandResult(succeeded: false, status: "exited(255)", output: "", errorOutput: "denied")
        let replies: [ScriptedGuest.Reply] = [.success(""), .success("ssh-ed25519 \(HostKeyTests.second)\n")]
            + Array(repeating: .result(refused), count: CredentialRotation.loginAttempts)
        try await Self.expectStarted(bundle, in: directory, replies: replies)
    }

    /// Ends a command that outlasts the time limit and leaves the started record.
    @Test func timesOutDuringScript() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .pending)
        let guest = try ScriptedGuest(directory: directory, replies: [.success(""), .hang])

        await #expect(throws: MacpoolError.credentialRotation(
            step: "replacing the credentials in the guest",
            reason: "the rotation's time limit ran out",
        )) {
            try await Self.rotate(bundle, through: guest, timeout: .milliseconds(300))
        }
        #expect(guest.cancelledCalls == 1)
        #expect(try bundle.settings().credentialRotation == .started)
    }

    /// Ends a running command when the caller cancels and leaves the started record.
    @Test func stopsOnCancellation() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .pending)
        let guest = try ScriptedGuest(directory: directory, replies: [.success(""), .hang])
        let rotation = Task {
            try await Self.rotate(bundle, through: guest)
        }
        while guest.calls.count < 2 {
            await Task.yield()
        }
        rotation.cancel()

        await #expect(throws: MacpoolError.credentialRotation(
            step: "replacing the credentials in the guest",
            reason: "the rotation was cancelled",
        )) {
            try await rotation.value
        }
        #expect(guest.cancelledCalls == 1)
        #expect(try bundle.settings().credentialRotation == .started)
    }

    /// Runs a rotation through a scripted guest without pauses between login attempts.
    ///
    /// - Parameters:
    ///   - bundle: The clone's bundle.
    ///   - guest: The scripted guest.
    ///   - timeout: The rotation's time limit.
    /// - Returns: The new host key.
    /// - Throws: The rotation's error.
    private static func rotate(
        _ bundle: VMBundle,
        through guest: ScriptedGuest,
        timeout: Duration = .seconds(60),
    ) async throws(MacpoolError) -> HostKey {
        try await CredentialRotation.rotate(
            bundle: bundle,
            timeout: timeout,
            logger: Logger(label: "test"),
            shell: guest,
            retryInterval: .zero,
        )
    }

    /// Runs a rotation that must fail after the guest started to change, and checks that the
    /// bundle still holds the inherited account and pin.
    ///
    /// - Parameters:
    ///   - bundle: The clone's bundle.
    ///   - directory: The test's directory.
    ///   - replies: The scripted guest's replies.
    /// - Throws: An error when the bundle cannot be read or the rotation succeeds.
    private static func expectStarted(
        _ bundle: VMBundle,
        in directory: TemporaryDirectory,
        replies: [ScriptedGuest.Reply],
    ) async throws {
        let account = try Data(contentsOf: bundle.guestAccountFile)
        let pin = try Data(contentsOf: bundle.knownHostsFile)
        let guest = try ScriptedGuest(directory: directory, replies: replies)
        await #expect(throws: MacpoolError.self) {
            try await rotate(bundle, through: guest)
        }
        #expect(guest.calls.count == replies.count)
        #expect(try bundle.settings().credentialRotation == .started)
        #expect(try Data(contentsOf: bundle.guestAccountFile) == account)
        #expect(try Data(contentsOf: bundle.knownHostsFile) == pin)
        #expect(FileManager.default.fileExists(atPath: bundle.rotatingGuestAccountFile.filePath))
    }

    /// Reads a file's POSIX permission bits.
    ///
    /// - Parameter url: The file.
    /// - Returns: The permission bits.
    /// - Throws: An error when the file's attributes cannot be read.
    private static func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.filePath)
        return (attributes[.posixPermissions] as? Int) ?? -1
    }
}

/// A guest that answers commands with scripted replies and records every call.
private final class ScriptedGuest: GuestCommandRunner {
    /// A scripted answer to one command.
    enum Reply: Sendable {
        /// The command finishes with this result.
        case result(GuestCommandResult)
        /// The command runs until its task is cancelled.
        case hang

        /// A successful command that printed the given output.
        ///
        /// - Parameter output: The command's standard output.
        /// - Returns: The reply.
        static func success(_ output: String) -> Reply {
            .result(GuestCommandResult(succeeded: true, status: "exited(0)", output: output, errorOutput: ""))
        }
    }

    /// One recorded command.
    struct Call: Sendable {
        /// The command line.
        let command: String
        /// The command's standard input.
        let input: String
        /// The login's user name.
        let username: String
        /// The account file whose password the login used.
        let accountFile: URL
        /// The contents of the `known_hosts` file at the time of the call.
        let knownHosts: String
        /// Whether the login trusted an unpinned key.
        let trustsFirstKey: Bool
    }

    /// The guest's mutable record.
    private struct Record {
        /// The replies that the next calls receive, in order.
        var replies: [Reply]
        /// The calls so far.
        var calls: [Call] = []
        /// The number of calls that ended by cancellation.
        var cancelledCalls = 0
    }

    /// The directory for the `known_hosts` files.
    let directory: URL

    /// The replies and the calls.
    private let record: Mutex<Record>

    /// Creates a guest with its replies.
    ///
    /// - Parameters:
    ///   - directory: The test's directory, which receives a subdirectory for `known_hosts` files.
    ///   - replies: The replies, one per expected call.
    /// - Throws: An error when the subdirectory cannot be created.
    init(directory: TemporaryDirectory, replies: [Reply]) throws {
        self.directory = directory.url.appending(path: "guest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false)
        record = Mutex(Record(replies: replies))
    }

    /// The calls so far.
    var calls: [Call] {
        record.withLock { $0.calls }
    }

    /// The number of calls that ended by cancellation.
    var cancelledCalls: Int {
        record.withLock { $0.cancelledCalls }
    }

    /// Writes a `known_hosts` file as ``GuestShell`` does.
    ///
    /// - Parameters:
    ///   - keys: The keys to accept.
    ///   - name: The file's name.
    /// - Returns: The file.
    /// - Throws: ``MacpoolError`` when the file cannot be written.
    func writeKnownHosts(_ keys: [HostKey], named name: String) throws(MacpoolError) -> URL {
        let file = directory.appending(path: name)
        let text = keys.map { $0.knownHostsLine(alias: VMBundle.hostKeyAlias) + "\n" }.joined()
        try FileSystem.replacePrivateFile(at: file, contents: Data(text.utf8), for: "writing known hosts")
        return file
    }

    /// Records a command and answers with the next reply.
    ///
    /// - Parameters:
    ///   - command: The command line.
    ///   - input: The command's standard input.
    ///   - username: The login's user name.
    ///   - accountFile: The account file.
    ///   - knownHosts: The `known_hosts` file.
    ///   - trustsFirstKey: Whether the login trusts an unpinned key.
    /// - Returns: The scripted result.
    /// - Throws: ``MacpoolError/credentialRotation(step:reason:)`` when no reply is left.
    func run(
        _ command: String,
        input: String,
        username: String,
        accountFile: URL,
        knownHosts: URL,
        trustsFirstKey: Bool,
    ) async throws(MacpoolError) -> GuestCommandResult {
        let pins = (try? String(contentsOf: knownHosts, encoding: .utf8)) ?? ""
        let call = Call(
            command: command,
            input: input,
            username: username,
            accountFile: accountFile,
            knownHosts: pins,
            trustsFirstKey: trustsFirstKey,
        )
        let reply = record.withLock { record -> Reply? in
            record.calls.append(call)
            return record.replies.isEmpty ? nil : record.replies.removeFirst()
        }
        switch reply {
        case let .result(result):
            return result
        case .hang:
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            record.withLock { $0.cancelledCalls += 1 }
            return GuestCommandResult(succeeded: false, status: "signaled(15)", output: "", errorOutput: "")
        case nil:
            throw .credentialRotation(step: "test", reason: "no scripted reply left")
        }
    }
}
