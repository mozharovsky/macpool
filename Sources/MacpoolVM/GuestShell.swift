import Foundation
import Subprocess
import System

/// An SSH client for one guest that logs in with the password of a stored account file.
///
/// The client ignores the user's SSH configuration and agent, so no identity leaves the host. It
/// gives `ssh` the password through an askpass script in a private temporary directory. The script
/// reads the account file that a call names, so the directory itself never holds a password.
///
/// Every connection looks the host key up under ``VMBundle/hostKeyAlias`` in a `known_hosts` file
/// that the caller writes with ``writeKnownHosts(_:named:)``, and accepts only Ed25519 keys. Call
/// ``removeDirectory()`` when the client is no longer needed.
struct GuestShell {
    /// The result of one remote command.
    struct CommandResult {
        /// Whether `ssh` and the remote command exited with status zero.
        let succeeded: Bool

        /// The exit status of `ssh`, such as `exited(255)`.
        let status: String

        /// The remote command's standard output.
        let output: String

        /// The standard error of `ssh` and the remote command.
        let errorOutput: String

        /// The exit status and the end of the error output.
        var failureSummary: String {
            let trimmed = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "ssh \(status) without output" : "ssh \(status): \(trimmed.suffix(400))"
        }
    }

    /// The most bytes collected from each output stream of a command.
    static let outputLimit = 1 << 16

    /// The guest's IPv4 address.
    let address: String

    /// The account's short user name, which ``CredentialRotation`` checks before it builds a
    /// command line with it.
    let username: String

    /// The private temporary directory with the askpass script and the `known_hosts` files.
    let directory: URL

    /// Creates a client and its private temporary directory.
    ///
    /// - Parameters:
    ///   - address: The guest's IPv4 address.
    ///   - username: The account's short user name.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the directory or the
    ///   askpass script cannot be created.
    init(address: String, username: String) throws(MacpoolError) {
        let template = FileManager.default.temporaryDirectory.appending(path: "macpool-ssh-XXXXXX").filePath
        var buffer = Array(template.utf8CString)
        guard mkdtemp(&buffer) != nil else {
            throw .systemCall("creating a directory for SSH", URL(filePath: template))
        }
        // mkdtemp creates the directory with owner-only permissions and writes its name in place.
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        self.address = address
        self.username = username
        directory = URL(filePath: path, directoryHint: .isDirectory)
        let script = "#!/bin/sh\nexec /usr/bin/plutil -extract password raw -o - \"$MACPOOL_ACCOUNT_FILE\"\n"
        do {
            try FileSystem.createNewFile(at: askpass, contents: Data(script.utf8), permissions: 0o700)
        } catch {
            removeDirectory()
            throw error
        }
    }

    /// The askpass script, which prints the password of the file in `MACPOOL_ACCOUNT_FILE`.
    var askpass: URL {
        directory.appending(path: "askpass")
    }

    /// Writes a `known_hosts` file that pins keys under ``VMBundle/hostKeyAlias``.
    ///
    /// - Parameters:
    ///   - keys: The keys to accept. An empty list makes the file empty.
    ///   - name: The file's name inside the client's directory.
    /// - Returns: The file.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the file cannot be
    ///   written.
    func writeKnownHosts(_ keys: [HostKey], named name: String) throws(MacpoolError) -> URL {
        let file = directory.appending(path: name)
        let text = keys.map { $0.knownHostsLine(alias: VMBundle.hostKeyAlias) + "\n" }.joined()
        try FileSystem.replacePrivateFile(at: file, contents: Data(text.utf8), for: "writing known hosts")
        return file
    }

    /// Runs a command in the guest.
    ///
    /// - Parameters:
    ///   - command: The command line that the account's login shell runs.
    ///   - input: The command's standard input, which keeps secrets out of process listings.
    ///   - accountFile: The account file whose password `ssh` sends.
    ///   - knownHosts: The `known_hosts` file from ``writeKnownHosts(_:named:)``.
    ///   - trustsFirstKey: Whether an empty `known_hosts` file accepts the key the guest presents.
    ///     A key that differs from a pinned one fails the connection either way.
    /// - Returns: The command's outputs and whether it succeeded.
    /// - Throws: ``MacpoolError/credentialRotation(step:reason:)`` when `ssh` cannot start or
    ///   its output exceeds ``outputLimit``.
    func run(
        _ command: String,
        input: String,
        accountFile: URL,
        knownHosts: URL,
        trustsFirstKey: Bool,
    ) async throws(MacpoolError) -> CommandResult {
        let arguments = [
            "-F", "/dev/null",
            "-o", "ForwardAgent=no",
            "-o", "IdentityAgent=none",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
            // ssh splits this value on spaces, so the path is quoted inside it.
            "-o", "UserKnownHostsFile=\"\(knownHosts.filePath)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlias=\(VMBundle.hostKeyAlias)",
            "-o", "HostKeyAlgorithms=\(HostKey.algorithm)",
            "-o", "StrictHostKeyChecking=\(trustsFirstKey ? "accept-new" : "yes")",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=6",
            "\(username)@\(address)",
            command,
        ]
        let environment = Environment.inherit.updating([
            "SSH_ASKPASS": askpass.filePath,
            "SSH_ASKPASS_REQUIRE": "force",
            "MACPOOL_ACCOUNT_FILE": accountFile.filePath,
        ])
        do {
            let result = try await Subprocess.run(
                .path("/usr/bin/ssh"),
                arguments: Arguments(arguments),
                environment: environment,
                input: .string(input),
                output: .string(limit: Self.outputLimit),
                error: .string(limit: Self.outputLimit),
            )
            return CommandResult(
                succeeded: result.terminationStatus.isSuccess,
                status: "\(result.terminationStatus)",
                output: result.standardOutput,
                errorOutput: result.standardError,
            )
        } catch {
            throw .credentialRotation(step: "running ssh", reason: "\(error)")
        }
    }

    /// Removes the client's temporary directory.
    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}
