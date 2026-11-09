public import Logging
import Foundation

/// The replacement of the guest password and SSH host keys that a clone inherits from its source.
///
/// A clone's disk holds its source's account and host keys, and its bundle holds the source's
/// account file and `known_hosts`. ``rotate(bundle:address:logger:)`` runs once on the clone's
/// first boot, as soon as SSH answers. It logs in with the inherited account, checks that the
/// guest presents the inherited host key, and replaces both in the guest over that connection.
///
/// The guest generates its own host keys, so no private key leaves it. The host learns the new
/// Ed25519 public key over the connection whose old key it verified, pins it under
/// ``VMBundle/hostKeyAlias``, and then logs in again with the new password and only the new key.
/// The bundle's account file and `known_hosts` change only after that second login succeeds.
///
/// The rotation records its progress in ``BundleSettings/credentialRotation``. It records
/// ``CredentialRotationState/started`` just before the guest starts to change, and a failure from
/// then on leaves that record, which commands refuse. A failure of the first login leaves
/// ``CredentialRotationState/pending``, so the next run tries again.
///
/// Until the rotation runs, the clone accepts the inherited password and presents the inherited
/// host key, like its source and every sibling that has not rotated yet.
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

    /// The shell script that replaces the credentials as root in the guest.
    ///
    /// The script reads the old password, the new password, and the encoded auto-login password
    /// from standard input, so none of them appears in the SSH command line. The guest tools that
    /// change the password take both passwords as arguments, which other guest processes can see
    /// for about a second. The script's only argument is the account's user name. It prints the
    /// new Ed25519 host key last.
    ///
    /// The host keys go first. `sshd` starts once per connection on macOS, so the next connection
    /// presents the new keys without a restart. `dscl -passwd` with the old password changes the
    /// password the way the account itself would, which keeps the account's secure token. The
    /// login keychain and `/etc/kcpassword` then follow, so automatic login and the keychain keep
    /// working on later boots. `sysadminctl -autologin set` would write the same file, but it needs
    /// the console user's session agent and reports success without it.
    ///
    /// The script contains no single quote, because the command line wraps it in single quotes.
    static let rootScript = """
    set -eu
    IFS= read -r old
    IFS= read -r new
    IFS= read -r autologin
    user=$1
    home=$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory | /usr/bin/sed "s/^NFSHomeDirectory: //")
    /bin/rm -f /etc/ssh/ssh_host_*
    /usr/bin/ssh-keygen -q -A
    /usr/bin/dscl . -passwd "/Users/$user" "$old" "$new"
    keychain="$home/Library/Keychains/login.keychain-db"
    if [ -f "$keychain" ]; then
        /usr/bin/sudo -u "$user" /usr/bin/security set-keychain-password -o "$old" -p "$new" "$keychain"
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
    /// ``CredentialRotationState/pending`` and hold the inherited account. When its `known_hosts`
    /// holds Ed25519 keys, the first connection must present one of them. Without any, the first
    /// connection trusts the key the guest presents, and the call logs a warning.
    ///
    /// On success the bundle's account file holds the new password with owner-only permissions,
    /// its `known_hosts` pins only the new key, and its settings record
    /// ``CredentialRotationState/finished``.
    ///
    /// - Parameters:
    ///   - bundle: The clone's bundle, which the caller holds locked while its VM runs.
    ///   - address: The guest's IPv4 address.
    ///   - logger: The logger for progress and the trust warning.
    /// - Returns: The guest's new Ed25519 host key.
    /// - Throws: ``MacpoolError/credentialRotation(step:reason:)`` when no rotation is pending, the
    ///   user name is unusable, a login fails, or the guest script fails. Other ``MacpoolError``
    ///   values report bundle files that cannot be read or written.
    public static func rotate(bundle: VMBundle, address: String, logger: Logger) async throws(MacpoolError) -> HostKey {
        var settings = try bundle.settings()
        guard settings.credentialRotation == .pending else {
            throw .credentialRotation(step: "starting", reason: "the bundle has no pending rotation")
        }
        let inherited = try GuestAccount.load(from: bundle.guestAccountFile)
        guard isPlainUsername(inherited.username) else {
            throw .credentialRotation(step: "starting", reason: "the user name \(inherited.username) needs quoting")
        }
        let pinned = HostKey
            .pinnedKeys(inKnownHosts: (try? String(contentsOf: bundle.knownHostsFile, encoding: .utf8)) ?? "")
        if pinned.isEmpty {
            logger.warning("The source pins no host key, so the rotation trusts the key the clone presents first")
        }
        let shell = try GuestShell(address: address, username: inherited.username)
        defer { shell.removeDirectory() }
        let inheritedHosts = try shell.writeKnownHosts(pinned, named: "inherited_known_hosts")

        logger.info("Logging in with the inherited account")
        try await waitForLogin(
            shell,
            step: "logging in with the inherited account",
            accountFile: bundle.guestAccountFile,
            knownHosts: inheritedHosts,
            trustsFirstKey: pinned.isEmpty,
        )

        let next = inherited.withNewPassword()
        try next.write(to: bundle.rotatingGuestAccountFile)
        settings.credentialRotation = .started
        try bundle.writeSettings(settings)

        logger.info("Replacing the guest password and host keys")
        var generator = SystemRandomNumberGenerator()
        let autoLogin = autoLoginData(for: next.password, using: &generator).map { hexDigits($0) }.joined()
        let replaced = try await shell.run(
            "/usr/bin/sudo -S -p '' /bin/sh -c '\(rootScript)' \(scriptName) \(inherited.username)",
            input: [inherited.password, inherited.password, next.password, autoLogin].map { $0 + "\n" }.joined(),
            accountFile: bundle.guestAccountFile,
            knownHosts: inheritedHosts,
            trustsFirstKey: pinned.isEmpty,
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
        try await waitForLogin(
            shell,
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

    /// Logs in with an account until the guest accepts it, up to ``loginAttempts`` times.
    ///
    /// Each attempt runs `/usr/bin/true`, so repeating it changes nothing in the guest.
    ///
    /// - Parameters:
    ///   - shell: The client for the guest.
    ///   - step: The step's description for the error.
    ///   - accountFile: The account file whose password the login uses.
    ///   - knownHosts: The `known_hosts` file with the keys to accept.
    ///   - trustsFirstKey: Whether the connection accepts an unpinned key.
    /// - Throws: ``MacpoolError/credentialRotation(step:reason:)`` when every attempt fails.
    private static func waitForLogin(
        _ shell: GuestShell,
        step: String,
        accountFile: URL,
        knownHosts: URL,
        trustsFirstKey: Bool,
    ) async throws(MacpoolError) {
        var failure = ""
        for attempt in 1 ... loginAttempts {
            let result = try await shell.run(
                "/usr/bin/true",
                input: "",
                accountFile: accountFile,
                knownHosts: knownHosts,
                trustsFirstKey: trustsFirstKey,
            )
            if result.succeeded {
                return
            }
            failure = result.failureSummary
            if attempt < loginAttempts {
                try? await Task.sleep(for: loginRetryInterval)
            }
        }
        throw .credentialRotation(step: step, reason: failure)
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

    /// Reports whether a user name can appear unquoted in a shell command line.
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
}
