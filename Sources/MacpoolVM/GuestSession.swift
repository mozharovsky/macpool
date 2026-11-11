import Foundation

/// A way to run commands in a running guest as the account that a bundle stores.
///
/// Each command opens its own SSH connection and logs in with the password in the bundle's
/// account file. The connection accepts only the Ed25519 host keys in the bundle's `known_hosts`.
/// A clone's ``CredentialRotation`` pins its key there. In the guest, `/bin/sh` runs the command
/// line.
///
/// If a command runs as root, it goes through `sudo`. The session sends the account's password and
/// a random marker line ahead of the command's input, so the password never appears in a command
/// line. Each call uses a new marker.
/// A root shell reads the marker before it starts the command. If `sudo` did not read the password,
/// the shell reads the password in place of the marker, discards it, and stops. The call then
/// throws ``MacpoolError/passwordlessSudo(path:)``.
///
/// The session keeps an askpass script and a copy of the pinned keys in a private temporary
/// directory. It removes the directory when it is released. The directory never holds a
/// password.
public final class GuestSession: Sendable {
    /// The bundle whose account and pinned keys the session uses.
    public let bundle: VMBundle

    /// The runner that reaches the guest.
    let runner: any GuestCommandRunner

    /// The session's copy of the pinned keys.
    let knownHosts: URL

    /// Creates a session for a guest that runs from a bundle.
    ///
    /// The bundle must pin at least one Ed25519 host key, and its credential rotation must have
    /// finished or never been needed. The call does not contact the guest.
    ///
    /// - Parameters:
    ///   - bundle: The bundle that the running guest booted from.
    ///   - address: The guest's IPv4 address.
    /// - Throws: ``MacpoolError/credentialRotationInProgress(path:)`` when the bundle's rotation is
    ///   pending. ``MacpoolError/credentialRotationIncomplete(path:)`` when it began and did not
    ///   finish. ``MacpoolError/invalidBundle(path:reason:)`` when `known_hosts` is missing or
    ///   pins no Ed25519 key. Another ``MacpoolError`` when a bundle file cannot be read or the
    ///   temporary directory cannot be created.
    public convenience init(bundle: VMBundle, address: String) throws(MacpoolError) {
        try self.init(bundle: bundle, runner: GuestShell(address: address))
    }

    /// Creates a session that runs commands through a runner.
    ///
    /// The session owns the runner's directory and removes it when the session is released, or
    /// right away when this initializer fails.
    ///
    /// - Parameters:
    ///   - bundle: The bundle that the running guest booted from.
    ///   - runner: The runner that reaches the guest.
    /// - Throws: ``MacpoolError`` as ``init(bundle:address:)`` describes.
    init(bundle: VMBundle, runner: any GuestCommandRunner) throws(MacpoolError) {
        do throws(MacpoolError) {
            switch try bundle.settings().credentialRotation {
            case .pending:
                throw .credentialRotationInProgress(path: bundle.root.filePath)
            case .started:
                throw .credentialRotationIncomplete(path: bundle.root.filePath)
            case .finished, nil:
                break
            }
            guard let keys = try bundle.pinnedHostKeys(), !keys.isEmpty else {
                throw .invalidBundle(path: bundle.knownHostsFile.filePath, reason: "no Ed25519 host key is pinned")
            }
            knownHosts = try runner.writeKnownHosts(keys, named: "known_hosts")
        } catch {
            runner.removeDirectory()
            throw error
        }
        self.bundle = bundle
        self.runner = runner
    }

    /// Removes the session's temporary directory.
    deinit {
        runner.removeDirectory()
    }

    /// Runs a command in the guest and waits until it ends.
    ///
    /// Each call reads the account file again. If the file changes, later calls use the new
    /// password.
    ///
    /// Cancelling the calling task ends the connection and throws
    /// ``MacpoolError/guestCommandCancelled``. The command in the guest keeps running until it ends
    /// or until it writes to its standard output or standard error. That write ends it. The guest's
    /// state after a cancellation is unknown.
    ///
    /// - Parameters:
    ///   - command: The command line that `/bin/sh` runs in the guest.
    ///   - input: The command's standard input. Pass secrets here rather than in `command`.
    ///   - asRoot: Whether `sudo` runs the command as root. If the password is wrong, `sudo` reads
    ///     the marker and the first line of `input` as further attempts and fails.
    /// - Returns: The command's outputs and exit status. A command that fails is a result rather
    ///   than an error.
    /// - Throws: ``MacpoolError/invalidBundle(path:reason:)`` when the account's user name needs
    ///   shell quoting or, for a root command, its password holds a line break.
    ///   ``MacpoolError/passwordlessSudo(path:)`` when `sudo` runs a root command without the
    ///   password. ``MacpoolError/guestCommand(reason:)`` when `ssh` cannot start or reading its
    ///   output fails, and
    ///   ``MacpoolError/guestCommandCancelled`` when the calling task is cancelled. Another
    ///   ``MacpoolError`` when the account file cannot be read.
    public func run(
        _ command: String,
        input: String = "",
        asRoot: Bool = false,
    ) async throws(MacpoolError) -> GuestCommandResult {
        let accountFile = bundle.guestAccountFile
        let account = try GuestAccount.load(from: accountFile)
        guard CredentialRotation.isPlainUsername(account.username) else {
            throw .invalidBundle(path: accountFile.filePath, reason: "the user name needs shell quoting")
        }
        let quotedCommand = Self.quoted(command)
        var line = "/bin/sh -c \(quotedCommand)"
        var standardInput = input
        var marker = ""
        if asRoot {
            guard !account.password.contains(where: \.isNewline) else {
                throw .invalidBundle(path: accountFile.filePath, reason: "the password holds a line break")
            }
            // -k ignores a cached sudo ticket, so sudo reads the password line whenever its
            // rules require a password.
            marker = "macpool-sudo-\(UUID().uuidString)"
            let script = Self.rootScript(marker: marker)
            line = "/usr/bin/sudo -S -k -p '' -- /bin/sh -c '\(script)' macpool-sudo \(quotedCommand)"
            standardInput = account.password + "\n" + marker + "\n" + input
        }
        let result = try await runner.run(
            line,
            input: standardInput,
            username: account.username,
            accountFile: accountFile,
            knownHosts: knownHosts,
            trustsFirstKey: false,
        )
        let skippedPassword = result.status == .exited(Self.passwordlessSudoStatus)
            && result.errorOutput.contains(Self.passwordlessSudoMessage(marker: marker))
        if asRoot, skippedPassword {
            throw .passwordlessSudo(path: bundle.root.filePath)
        }
        return result
    }

    /// The exit status of the root script when the marker is missing.
    static let passwordlessSudoStatus: Int32 = 125

    /// Returns the message that the root script prints when the marker is missing.
    ///
    /// The message names the call's marker. A command that prints the same text without the marker
    /// does not count as a `sudo` that skipped the password.
    ///
    /// - Parameter marker: The marker that this call sent after the password.
    /// - Returns: One line of text without a line break.
    static func passwordlessSudoMessage(marker: String) -> String {
        "macpool: sudo did not read the password (\(marker))"
    }

    /// Returns the root shell script that checks the marker and then runs the command in its
    /// first argument.
    ///
    /// The script contains no single quote, because the command line wraps it in single quotes.
    ///
    /// - Parameter marker: The marker that this call sends after the password. It must hold no
    ///   single quote or line break.
    /// - Returns: The script on one line.
    static func rootScript(marker: String) -> String {
        """
        IFS= read -r line && [ "$line" = \(marker) ] \
        || { echo "\(passwordlessSudoMessage(marker: marker))" >&2; exit \(passwordlessSudoStatus); }; \
        exec /bin/sh -c "$1"
        """
    }

    /// Quotes text as one word for a POSIX shell.
    ///
    /// - Parameter text: Any text.
    /// - Returns: The text in single quotes, with each single quote inside written as `'\''`.
    static func quoted(_ text: String) -> String {
        "'" + text.replacing("'", with: #"'\''"#) + "'"
    }
}
