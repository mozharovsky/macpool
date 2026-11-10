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

    /// Runs a root command through `sudo` with the password as the first line of input.
    @Test func sendsPasswordToSudoOnInput() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: false, rotation: nil)
        let account = try GuestAccount.load(from: bundle.guestAccountFile)
        let guest = try ScriptedGuest(directory: directory, replies: [.success("0\n")])
        let session = try GuestSession(bundle: bundle, runner: guest)

        _ = try await session.run("id -u", input: "data\n", asRoot: true)

        let call = try #require(guest.calls.first)
        #expect(call.command == "/usr/bin/sudo -S -k -p '' -- /bin/sh -c 'id -u'")
        #expect(call.input == account.password + "\ndata\n")
        #expect(!call.command.contains(account.password))
    }

    /// Returns a failed command as a result rather than an error.
    @Test func reportsFailedCommand() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try VMBundleTests.makeSource(in: directory, hasBooted: true, rotation: .finished)
        let failed = GuestCommandResult(succeeded: false, status: "exited(3)", output: "", errorOutput: "no\n")
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
