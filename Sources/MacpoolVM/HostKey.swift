import CryptoKit
import Foundation

/// A guest's Ed25519 SSH host key and the `known_hosts` lines that pin it.
///
/// A bundle's `known_hosts` file names its guest by ``VMBundle/hostKeyAlias`` instead of an
/// address. The guest's DHCP address can change between boots and can later belong to another
/// guest, while the bundle and its key stay together. `Scripts/ssh.sh` passes the same alias to
/// `ssh` and accepts only Ed25519 host keys, so a pinned key is checked on every connection.
public struct HostKey: Sendable, Hashable {
    /// The key type that macpool pins.
    public static let algorithm = "ssh-ed25519"

    /// The public key blob in base64, as the second field of an OpenSSH public key line.
    public let base64: String

    /// Creates a key from its base64 blob.
    ///
    /// - Parameter base64: The public key blob in base64. It must decode to a complete Ed25519
    ///   key blob.
    /// - Returns: `nil` when the text is not an Ed25519 key blob.
    public init?(base64: some StringProtocol) {
        guard let blob = Data(base64Encoded: String(base64)), Self.isEd25519Blob(blob) else {
            return nil
        }
        self.base64 = String(base64)
    }

    /// Parses an OpenSSH public key line such as the contents of `ssh_host_ed25519_key.pub`.
    ///
    /// - Parameter line: The line with the key type, the base64 blob, and an optional comment.
    /// - Returns: The key, or `nil` when the line holds no Ed25519 key.
    public init?(publicKeyLine line: some StringProtocol) {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == Self.algorithm else {
            return nil
        }
        self.init(base64: fields[1])
    }

    /// The key's SHA-256 fingerprint in the form that `ssh-keygen -l` prints.
    ///
    /// The value reads `SHA256:` followed by the unpadded base64 digest of the key blob.
    public var fingerprint: String {
        let blob = Data(base64Encoded: base64) ?? Data()
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacing("=", with: "")
    }

    /// The `known_hosts` line that pins this key under an alias.
    ///
    /// - Parameter alias: The name that `ssh` looks up through its `HostKeyAlias` option.
    /// - Returns: The line without a line break.
    public func knownHostsLine(alias: String) -> String {
        "\(alias) \(Self.algorithm) \(base64)"
    }

    /// Collects the Ed25519 keys of a `known_hosts` file.
    ///
    /// The host names are ignored, because a bundle's file only ever holds keys of its own guest.
    /// Older bundles name the guest by its address, and later ones by ``VMBundle/hostKeyAlias``.
    /// Comments, marked lines such as `@revoked`, and keys of other types are skipped.
    ///
    /// - Parameter text: The file's contents.
    /// - Returns: The distinct keys in file order.
    public static func pinnedKeys(inKnownHosts text: String) -> [HostKey] {
        var keys: [HostKey] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, !fields[0].hasPrefix("#"), !fields[0].hasPrefix("@"), fields[1] == algorithm,
                  let key = HostKey(base64: fields[2]), !keys.contains(key) else {
                continue
            }
            keys.append(key)
        }
        return keys
    }

    /// Reports whether a decoded blob is a complete Ed25519 public key.
    ///
    /// An OpenSSH Ed25519 key blob holds the type name and the 32-byte key, each as a string with
    /// a four-byte big-endian length, which makes 51 bytes.
    ///
    /// - Parameter blob: The decoded key blob.
    /// - Returns: `true` when the blob names `ssh-ed25519` and holds exactly one 32-byte key.
    private static func isEd25519Blob(_ blob: Data) -> Bool {
        let name = Data(algorithm.utf8)
        let prefix = Data([0, 0, 0, UInt8(name.count)]) + name + Data([0, 0, 0, 32])
        return blob.count == prefix.count + 32 && blob.prefix(prefix.count) == prefix
    }
}
