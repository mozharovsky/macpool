import Foundation
@testable import MacpoolVM
import Testing

/// Tests of the command lines, inputs, and checks of a guest session.
struct GuestSessionTests {
    /// Runs a command through `/bin/sh` as the account with the pinned key and the given input.
    @Test func runsCommandAsAccount() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .finished)
        let account = try GuestAccount.load(from: bundle.guestAccountFile)
        let guest = try ScriptedGuest(directory: directory, replies: [.success("macpool\n")])
        let session = try GuestSession(bundle: bundle, runner: guest)

        let result = try await session.run("echo 'it works' | cat", input: "data\n")

        #expect(result.succeeded)
        #expect(result.output == "macpool\n")
        let call = try #require(guest.calls.first)
        #expect(call.command == #"/bin/sh -c 'echo '\''it works'\'' | cat'"#)
        #expect(call.input == "data\n")
        #expect(call.username == account.username)
        #expect(call.accountFile == bundle.guestAccountFile)
        #expect(call.knownHosts == "macpool-guest ssh-ed25519 \(HostKeyTests.first)\n")
        #expect(!call.trustsFirstKey)
    }

    /// Runs a root command through `sudo` and a shell that checks the marker after the password.
    @Test func sendsPasswordAndMarkerToSudo() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: false, rotation: nil)
        let account = try GuestAccount.load(from: bundle.guestAccountFile)
        let guest = try ScriptedGuest(directory: directory, replies: [.success("0\n")])
        let session = try GuestSession(bundle: bundle, runner: guest)

        _ = try await session.run("id -u", input: "data\n", asRoot: true)

        let call = try #require(guest.calls.first)
        let script = #"IFS= read -r line && [ "$line" = macpool-sudo-input ] || "#
            + #"{ echo "macpool: sudo did not read the password" >&2; exit 125; }; exec /bin/sh -c "$1""#
        #expect(call.command == "/usr/bin/sudo -S -k -p '' -- /bin/sh -c '\(script)' macpool-sudo 'id -u'")
        #expect(call.input == account.password + "\nmacpool-sudo-input\ndata\n")
        #expect(!call.command.contains(account.password))
        #expect(!GuestSession.rootScript.contains("'"))
    }

    /// Throws when the root script reports that `sudo` did not read the password.
    @Test func refusesPasswordlessSudo() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .finished)
        let refused = GuestCommandResult(
            status: .exited(125),
            output: "",
            errorOutput: "macpool: sudo did not read the password\n",
        )
        let guest = try ScriptedGuest(directory: directory, replies: [.result(refused), .result(refused)])
        let session = try GuestSession(bundle: bundle, runner: guest)

        await #expect(throws: MacpoolError.passwordlessSudo(path: bundle.root.filePath)) {
            try await session.run("/bin/cat", input: "x\n", asRoot: true)
        }
        // The same status from an account command is the command's own result.
        #expect(try await session.run("/bin/cat") == refused)
    }

    /// Returns status 125 from a root command that exits with it on its own.
    @Test func keepsOwnStatusOfRootCommand() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .finished)
        let own = GuestCommandResult(status: .exited(125), output: "", errorOutput: "other\n")
        let guest = try ScriptedGuest(directory: directory, replies: [.result(own)])
        let session = try GuestSession(bundle: bundle, runner: guest)

        #expect(try await session.run("exit 125", asRoot: true) == own)
    }

    /// Rejects an account whose user name needs shell quoting before it contacts the guest.
    @Test func rejectsUsernameThatNeedsQuoting() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .finished)
        try GuestAccount(fullName: "a", username: "a b", password: "secret").write(to: bundle.guestAccountFile)
        let guest = try ScriptedGuest(directory: directory, replies: [])
        let session = try GuestSession(bundle: bundle, runner: guest)

        await #expect(throws: MacpoolError.invalidBundle(
            path: bundle.guestAccountFile.filePath,
            reason: "the user name needs shell quoting",
        )) {
            try await session.run("true")
        }
        #expect(guest.calls.isEmpty)
    }

    /// Rejects a root command when the password holds a line break. The break would split the input.
    @Test func rejectsPasswordWithLineBreakForRoot() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .finished)
        try GuestAccount(fullName: "a", username: "macpool", password: "one\ntwo").write(to: bundle.guestAccountFile)
        let guest = try ScriptedGuest(directory: directory, replies: [.success("")])
        let session = try GuestSession(bundle: bundle, runner: guest)

        await #expect(throws: MacpoolError.invalidBundle(
            path: bundle.guestAccountFile.filePath,
            reason: "the password holds a line break",
        )) {
            try await session.run("true", asRoot: true)
        }
        #expect(guest.calls.isEmpty)
        // An account command sends no password, so it still runs.
        _ = try await session.run("true")
        #expect(guest.calls.count == 1)
    }

    /// Returns a failed command as a result rather than an error.
    @Test func reportsFailedCommand() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .finished)
        let failed = GuestCommandResult(status: .exited(3), output: "", errorOutput: "no\n")
        let guest = try ScriptedGuest(directory: directory, replies: [.result(failed)])
        let session = try GuestSession(bundle: bundle, runner: guest)

        let result = try await session.run("exit 3")

        #expect(result == failed)
        #expect(result.failureSummary == "ssh exited(3): no")
    }

    /// Refuses a bundle whose credential rotation has not finished.
    @Test(arguments: [
        (CredentialRotationState.pending, true),
        (CredentialRotationState.started, false),
    ])
    func refusesUnfinishedRotation(state: CredentialRotationState, inProgress: Bool) throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: state)
        let guest = try ScriptedGuest(directory: directory, replies: [])
        let path = bundle.root.filePath
        let expected: MacpoolError = inProgress
            ? .credentialRotationInProgress(path: path)
            : .credentialRotationIncomplete(path: path)
        #expect(throws: expected) {
            try GuestSession(bundle: bundle, runner: guest)
        }
        #expect(guest.isDirectoryRemoved)
    }

    /// Refuses a bundle that pins no host key, whether `known_hosts` is missing or empty.
    @Test(arguments: [false, true])
    func refusesBundleWithoutPinnedKey(keepsEmptyFile: Bool) throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .finished)
        if keepsEmptyFile {
            try Data().write(to: bundle.knownHostsFile)
        } else {
            try FileManager.default.removeItem(at: bundle.knownHostsFile)
        }
        let guest = try ScriptedGuest(directory: directory, replies: [])
        #expect(throws: MacpoolError.invalidBundle(
            path: bundle.knownHostsFile.filePath,
            reason: "no Ed25519 host key is pinned",
        )) {
            try GuestSession(bundle: bundle, runner: guest)
        }
        #expect(guest.isDirectoryRemoved)
    }

    /// Removes the private directory when the session is released.
    @Test func removesDirectoryWhenReleased() throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .finished)
        var session: GuestSession? = try GuestSession(bundle: bundle, address: "192.0.2.1")
        let shell = try #require(session?.runner as? GuestShell)
        #expect(FileManager.default.fileExists(atPath: shell.askpass.filePath))
        session = nil
        #expect(!FileManager.default.fileExists(atPath: shell.directory.filePath))
    }

    /// Quotes text so that a POSIX shell reads it back as one unchanged word.
    @Test func quotesForShell() {
        #expect(GuestSession.quoted("plain") == "'plain'")
        #expect(GuestSession.quoted("") == "''")
        #expect(GuestSession.quoted("it's") == #"'it'\''s'"#)
        #expect(GuestSession.quoted("$HOME `x` \"y\"") == "'$HOME `x` \"y\"'")
    }
}
