public import Logging
import Foundation

/// The replacement of the guest password and SSH host keys that a clone inherits from its source.
///
/// A clone's disk holds its source's account and host keys, and its bundle holds the source's
/// account file and `known_hosts`. ``rotate(bundle:address:timeout:logger:)`` runs once on the
/// clone's first boot, as soon as SSH answers. It logs in with the inherited account, checks that
/// the guest presents the inherited host key, and replaces both in the guest over that connection.
///
/// The guest generates its own host keys, so no private key leaves it. The host learns the new
/// Ed25519 public key over the connection whose old key it verified, pins it under
/// ``VMBundle/hostKeyAlias``, and then logs in again with the new password and only the new key.
/// The bundle's account file and `known_hosts` change only after that second login succeeds.
///
/// The rotation records its progress in ``BundleSettings/credentialRotation``. It records
/// ``CredentialRotationState/started`` just before the guest starts to change, and a failure,
/// timeout, or cancellation from then on leaves that record, which commands refuse. A failure of
/// the first login leaves ``CredentialRotationState/pending``, so the next run tries again.
///
/// Until the rotation ends, the clone accepts the inherited password and presents the inherited
/// host key, like its source and every sibling that has not rotated yet. The inherited key
/// therefore identifies the source image rather than the clone. Any guest or host process that
/// knows the inherited password can log in during that window and leave access that the rotation
/// does not remove, so a finished rotation does not prove that nobody else logged in.
public enum CredentialRotation {
    /// The number of attempts of each login check before the rotation gives up.
    ///
    /// SSH can answer a moment before the guest accepts passwords, and a guest under load right
    /// after its boot can drop a connection, so single attempts may fail. A rejected password
    /// costs the guest's authentication delay of several seconds per attempt, so a wrong password
    /// fails the rotation after about half a minute.
    static let loginAttempts = 5

    /// The pause between login attempts.
    static let loginRetryInterval = Duration.seconds(2)

    /// The program name that the guest's root shell receives as `$0`.
    static let scriptName = "macpool-rotate-credentials"

    /// The last line of the script's standard input, which proves that the lines arrived in order.
    static let inputEndMarker = "end-of-rotation-input"

    /// The shell script that replaces the credentials as root in the guest.
    ///
    /// `sudo -S` consumes the first line of standard input. The script then reads the old
    /// password, the new password, the encoded automatic login password, and
    /// ``inputEndMarker``, and refuses to change anything when the layout differs. Its only argument
    /// is the account's user name. It prints the new Ed25519 host key last.
    ///
    /// The passwords reach `dscl` and `security` on their standard input, so they never appear in
    /// a guest command line. `dscl` reads commands from standard input and exits with status zero
    /// even when a command fails, so the script also treats an error in either tool's output as a
    /// failure.
    ///
    /// `ssh-keygen` writes the new host keys under a staging directory in `/etc/ssh`, and each file
    /// then replaces its old version with a rename. `sshd` starts once per connection on macOS and
    /// generates missing keys first, so the keys are never missing and a connection sees either
    /// the old file or the new one. `dscl` changes the password with the old one, which keeps the
    /// account's secure token. The login keychain and `/etc/kcpassword` follow, so automatic login
    /// and the keychain keep working on later boots. `sysadminctl -autologin set` would write the
    /// same file, but it needs the console user's session agent and reports success without it.
    ///
    /// The script contains no single quote, because the command line wraps it in single quotes.
    static let rootScript = """
    set -eu
    fail() { echo "\(scriptName): $1" >&2; exit 1; }
    IFS= read -r old || fail "standard input ended early"
    IFS= read -r new || fail "standard input ended early"
    IFS= read -r autologin || fail "standard input ended early"
    IFS= read -r marker || fail "standard input ended early"
    [ "$marker" = "\(inputEndMarker)" ] || fail "standard input has an unexpected layout"
    [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ] || fail "the passwords are empty or equal"
    case $autologin in "" | *[!0-9a-f]*) fail "the auto-login data is not hexadecimal" ;; esac
    user=$1
    for tool in /usr/bin/dscl /usr/bin/security /usr/bin/ssh-keygen /usr/bin/xxd /usr/bin/plutil /usr/bin/sudo; do
        [ -x "$tool" ] || fail "$tool is missing"
    done
    home=$(/usr/bin/dscl -plist . -read "/Users/$user" NFSHomeDirectory \\
        | /usr/bin/plutil -extract "dsAttrTypeStandard:NFSHomeDirectory.0" raw -o - -) \\
        || fail "the home directory of $user is unknown"
    [ -d "$home" ] || fail "the home directory $home is missing"
    keychain="$home/Library/Keychains/login.keychain-db"
    if [ -f /etc/kcpassword ] && [ ! -f "$keychain" ]; then
        fail "the automatic login account has no login keychain"
    fi
    stage=$(/usr/bin/mktemp -d /etc/ssh/.macpool-host-keys.XXXXXX)
    trap "/bin/rm -rf $stage" EXIT
    /bin/mkdir -p "$stage/etc/ssh"
    /usr/bin/ssh-keygen -q -A -f "$stage"
    [ -f "$stage/etc/ssh/ssh_host_ed25519_key.pub" ] || fail "ssh-keygen wrote no Ed25519 key"
    for key in "$stage"/etc/ssh/ssh_host_*; do
        /bin/mv -f "$key" /etc/ssh/
    done
    result=$(printf "passwd /Users/%s %s %s\\n" "$user" "$old" "$new" | /usr/bin/dscl . 2>&1) \\
        || fail "dscl failed"
    case $result in *rror*) fail "dscl did not change the password" ;; esac
    if [ -f "$keychain" ]; then
        result=$(printf "set-keychain-password -o %s -p %s %s\\n" "$old" "$new" "$keychain" \\
            | /usr/bin/sudo -u "$user" /usr/bin/security -i 2>&1) || fail "security failed"
        case $result in *rror*) fail "security did not change the keychain password" ;; esac
    fi
    if [ -f /etc/kcpassword ]; then
        (umask 077 && printf "%s" "$autologin" | /usr/bin/xxd -r -p > /etc/kcpassword.new)
        /bin/mv /etc/kcpassword.new /etc/kcpassword
    fi
    /bin/sync
    /bin/cat /etc/ssh/ssh_host_ed25519_key.pub
    """

    /// The key that macOS applies to the automatic login password in `/etc/kcpassword`.
    ///
    /// The file holds the password, a zero byte, and padding to a multiple of 12 bytes, each byte
    /// combined by exclusive or with this key repeated.
    static let autoLoginKey: [UInt8] = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]

    /// Replaces a clone's inherited password and SSH host keys and pins the new host key.
    ///
    /// The guest must have booted from the clone's disk and answer on SSH. The bundle must record
    /// ``CredentialRotationState/pending`` and hold the inherited account. Its user name may hold
    /// ASCII letters, digits, `.`, `_`, and `-`, and its password only ASCII letters and digits,
    /// as generated passwords do. When its `known_hosts` holds Ed25519 keys,
    /// the first connection must present one of them. Without the file, the first connection
    /// trusts the key the guest presents, and the call logs a warning.
    ///
    /// On success the bundle's account file holds the new password with owner-only permissions,
    /// its `known_hosts` pins only the new key, and its settings record
    /// ``CredentialRotationState/finished``. Cancelling the calling task ends the running `ssh`
    /// and fails the rotation like a timeout.
    ///
    /// - Parameters:
    ///   - bundle: The clone's bundle, which the caller holds locked while its VM runs.
    ///   - address: The guest's IPv4 address.
    ///   - timeout: The longest time for the whole rotation, including every login.
    ///   - logger: The logger for progress and the trust warning.
    /// - Returns: The guest's new Ed25519 host key.
    /// - Throws: ``MacpoolError/credentialRotation(step:reason:)`` when no rotation is pending, the
    ///   account is unusable, a login fails, the guest script fails, the time runs out, or the task
    ///   is cancelled. Other ``MacpoolError`` values report bundle files that cannot be read or
    ///   written, including a `known_hosts` file that exists and cannot be read.
    public static func rotate(
        bundle: VMBundle,
        address: String,
        timeout: Duration,
        logger: Logger,
    ) async throws(MacpoolError) -> HostKey {
        let shell = try GuestShell(address: address)
        defer { shell.removeDirectory() }
        return try await rotate(bundle: bundle, timeout: timeout, logger: logger, shell: shell)
    }

    /// Replaces a clone's credentials through a command runner.
    ///
    /// - Parameters:
    ///   - bundle: The clone's bundle.
    ///   - timeout: The longest time for the whole rotation.
    ///   - logger: The logger for progress and the trust warning.
    ///   - shell: The runner that reaches the guest.
    ///   - retryInterval: The pause between login attempts.
    /// - Returns: The guest's new Ed25519 host key.
    /// - Throws: ``MacpoolError`` as ``rotate(bundle:address:timeout:logger:)`` describes.
    static func rotate(
        bundle: VMBundle,
        timeout: Duration,
        logger: Logger,
        shell: some GuestCommandRunner,
        retryInterval: Duration = loginRetryInterval,
    ) async throws(MacpoolError) -> HostKey {
        let deadline = ContinuousClock.now + timeout
        var settings = try bundle.settings()
        guard settings.credentialRotation == .pending else {
            throw .credentialRotation(step: "starting", reason: "the bundle has no pending rotation")
        }
        let inherited = try GuestAccount.load(from: bundle.guestAccountFile)
        guard isPlainUsername(inherited.username), isPlainPassword(inherited.password) else {
            throw .credentialRotation(
                step: "starting",
                reason: "the account's user name or password has unsupported characters",
            )
        }
        let pinned = try inheritedKeys(of: bundle)
        if pinned == nil {
            logger.warning("The source pins no host key, so the rotation trusts the key the clone presents first")
        }
        let inheritedHosts = try shell.writeKnownHosts(pinned ?? [], named: "inherited_known_hosts")
        let login = Login(shell: shell, username: inherited.username, deadline: deadline, retryInterval: retryInterval)

        logger.info("Logging in with the inherited account")
        try await login.check(
            step: "logging in with the inherited account",
            accountFile: bundle.guestAccountFile,
            knownHosts: inheritedHosts,
            trustsFirstKey: pinned == nil,
        )

        let next = inherited.withNewPassword()
        try next.write(to: bundle.rotatingGuestAccountFile)
        settings.credentialRotation = .started
        try bundle.writeSettings(settings)

        logger.info("Replacing the guest password and host keys")
        var generator = SystemRandomNumberGenerator()
        let autoLogin = autoLoginData(for: next.password, using: &generator).map { hexDigits($0) }.joined()
        let input = [inherited.password, inherited.password, next.password, autoLogin, inputEndMarker]
        let replaced = try await login.run(
            "/usr/bin/sudo -S -p '' /bin/sh -c '\(rootScript)' \(scriptName) \(inherited.username)",
            step: "replacing the credentials in the guest",
            input: input.map { $0 + "\n" }.joined(),
            accountFile: bundle.guestAccountFile,
            knownHosts: inheritedHosts,
            trustsFirstKey: pinned == nil,
        )
        guard replaced.succeeded else {
            throw .credentialRotation(step: "replacing the credentials in the guest", reason: replaced.failureSummary)
        }
        let lines = replaced.output.split(whereSeparator: \.isNewline)
        guard let key = lines.last.flatMap({ HostKey(publicKeyLine: $0) }) else {
            throw .credentialRotation(step: "reading the new host key", reason: "the guest printed no Ed25519 key")
        }

        logger.info("Logging in with the new account", metadata: ["host_key": "\(key.fingerprint)"])
        let rotatedHosts = try shell.writeKnownHosts([key], named: "rotated_known_hosts")
        try await login.check(
            step: "logging in with the new account",
            accountFile: bundle.rotatingGuestAccountFile,
            knownHosts: rotatedHosts,
            trustsFirstKey: false,
        )

        let knownHosts = Data((key.knownHostsLine(alias: VMBundle.hostKeyAlias) + "\n").utf8)
        try FileSystem.replacePrivateFile(at: bundle.knownHostsFile, contents: knownHosts, for: "pinning the host key")
        guard rename(bundle.rotatingGuestAccountFile.filePath, bundle.guestAccountFile.filePath) == 0 else {
            throw .systemCall("storing the new guest account", bundle.guestAccountFile)
        }
        settings.credentialRotation = .finished
        try bundle.writeSettings(settings)
        return key
    }

    /// Reads the Ed25519 keys that the clone's copied `known_hosts` pins.
    ///
    /// - Parameter bundle: The clone's bundle.
    /// - Returns: The pinned keys, or `nil` when the file does not exist.
    /// - Throws: ``MacpoolError`` when the file exists and cannot be read or is not UTF-8.
    static func inheritedKeys(of bundle: VMBundle) throws(MacpoolError) -> [HostKey]? {
        let file = bundle.knownHostsFile
        guard let data = try FileSystem.readIfPresent(file, for: "reading the inherited host keys") else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw .invalidBundle(path: file.filePath, reason: "not UTF-8 text")
        }
        return HostKey.pinnedKeys(inKnownHosts: text)
    }

    /// Encodes a password for `/etc/kcpassword`.
    ///
    /// - Parameters:
    ///   - password: The automatic login password.
    ///   - generator: The source of the padding bytes.
    /// - Returns: The file's bytes, a multiple of 12 long.
    static func autoLoginData(for password: String, using generator: inout some RandomNumberGenerator) -> [UInt8] {
        var bytes = Array(password.utf8) + [0]
        while !bytes.count.isMultiple(of: 12) {
            bytes.append(UInt8.random(in: .min ... .max, using: &generator))
        }
        return bytes.enumerated().map { index, byte in byte ^ autoLoginKey[index % autoLoginKey.count] }
    }

    /// Formats a byte as two lowercase hexadecimal digits.
    ///
    /// - Parameter byte: The byte to format.
    /// - Returns: The digits, such as `0a`.
    private static func hexDigits(_ byte: UInt8) -> String {
        let digits = String(byte, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
    }

    /// Reports whether a user name can appear unquoted in a shell command line and in the command
    /// readers of `dscl` and `security`.
    ///
    /// - Parameter username: The account's short user name.
    /// - Returns: `true` when the name is non-empty and holds only ASCII letters, digits, `.`, `_`,
    ///   and `-`, and does not start with `-`.
    static func isPlainUsername(_ username: String) -> Bool {
        guard let first = username.first, first != "-" else {
            return false
        }
        return username.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
        }
    }

    /// Reports whether a password can pass through the command readers of `dscl` and `security`,
    /// which split their input at spaces and quotes.
    ///
    /// Generated passwords always qualify.
    ///
    /// - Parameter password: The account's password.
    /// - Returns: `true` when the password is non-empty and holds only ASCII letters and digits.
    static func isPlainPassword(_ password: String) -> Bool {
        !password.isEmpty && password.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// The logins of one rotation, bounded by the rotation's deadline.
private struct Login<Shell: GuestCommandRunner> {
    /// The runner that reaches the guest.
    let shell: Shell

    /// The account's short user name.
    let username: String

    /// The time after which every command fails.
    let deadline: ContinuousClock.Instant

    /// The pause between login attempts.
    let retryInterval: Duration

    /// Logs in until the guest accepts the account, up to ``CredentialRotation/loginAttempts``
    /// times.
    ///
    /// Each attempt runs `/usr/bin/true`, so repeating it changes nothing in the guest.
    ///
    /// - Parameters:
    ///   - step: The step's description for the error.
    ///   - accountFile: The account file whose password the login uses.
    ///   - knownHosts: The `known_hosts` file with the keys to accept.
    ///   - trustsFirstKey: Whether the connection accepts an unpinned key.
    /// - Throws: ``MacpoolError/credentialRotation(step:reason:)`` when every attempt fails, the
    ///   deadline passes, or the task is cancelled.
    func check(step: String, accountFile: URL, knownHosts: URL, trustsFirstKey: Bool) async throws(MacpoolError) {
        var failure = ""
        for attempt in 1 ... CredentialRotation.loginAttempts {
            let result = try await run(
                "/usr/bin/true",
                step: step,
                input: "",
                accountFile: accountFile,
                knownHosts: knownHosts,
                trustsFirstKey: trustsFirstKey,
            )
            if result.succeeded {
                return
            }
            failure = result.failureSummary
            if attempt < CredentialRotation.loginAttempts {
                try? await Task.sleep(for: retryInterval)
            }
        }
        throw .credentialRotation(step: step, reason: failure)
    }

    /// Runs one command in the guest within the time that remains before the deadline.
    ///
    /// - Parameters:
    ///   - command: The command line.
    ///   - step: The step's description for the error.
    ///   - input: The command's standard input.
    ///   - accountFile: The account file whose password the login uses.
    ///   - knownHosts: The `known_hosts` file with the keys to accept.
    ///   - trustsFirstKey: Whether the connection accepts an unpinned key.
    /// - Returns: The command's result.
    /// - Throws: ``MacpoolError/credentialRotation(step:reason:)`` when the deadline passes, the
    ///   task is cancelled, or the command cannot start.
    func run(
        _ command: String,
        step: String,
        input: String,
        accountFile: URL,
        knownHosts: URL,
        trustsFirstKey: Bool,
    ) async throws(MacpoolError) -> GuestCommandResult {
        let remaining = deadline - ContinuousClock.now
        guard !Task.isCancelled else {
            throw .credentialRotation(step: step, reason: "the rotation was cancelled")
        }
        guard remaining > .zero else {
            throw .credentialRotation(step: step, reason: "the rotation's time limit ran out")
        }
        let outcome = await withTaskGroup(of: TimedOutcome.self) { group in
            group.addTask { [shell, username] in
                do throws(MacpoolError) {
                    return try await .finished(shell.run(
                        command,
                        input: input,
                        username: username,
                        accountFile: accountFile,
                        knownHosts: knownHosts,
                        trustsFirstKey: trustsFirstKey,
                    ))
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: remaining)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? .cancelled
            // Cancelling the group terminates the other child, including a running ssh.
            group.cancelAll()
            return first
        }
        // A cancelled command can still report its own exit before the timer notices.
        guard !Task.isCancelled else {
            throw .credentialRotation(step: step, reason: "the rotation was cancelled")
        }
        switch outcome {
        case let .finished(result):
            return result
        case let .failed(error):
            throw error
        case .timedOut:
            throw .credentialRotation(step: step, reason: "the rotation's time limit ran out")
        case .cancelled:
            throw .credentialRotation(step: step, reason: "the rotation was cancelled")
        }
    }
}

/// The first of a command's result and its time limit.
private enum TimedOutcome: Sendable {
    /// The command finished.
    case finished(GuestCommandResult)
    /// The command could not run.
    case failed(MacpoolError)
    /// The time limit passed first.
    case timedOut
    /// The waiting task was cancelled.
    case cancelled
}
