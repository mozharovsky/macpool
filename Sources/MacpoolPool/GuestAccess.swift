public import MacpoolVM

/// The account and the pinned host keys that log in to a lease's guest over SSH.
///
/// The daemon sends the access only to the lease's owner and only in reply to
/// ``PoolRequest/access(_:)``. Pin ``hostKeys`` for the SSH client and accept no other key.
///
/// The user name holds only ASCII letters, digits, `.`, `_`, and `-`, and does not start with
/// `-`. The password holds no line break and no NUL, because `ssh` reads a password from an
/// askpass program only up to the first of them.
///
/// The description and the reflection of an access leave the password out. A log line or an
/// error message that contains a reply therefore shows no password.
public struct GuestAccess: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// The account's short user name.
    public let username: String

    /// The account's password.
    public let password: String

    /// The guest's Ed25519 host keys. A guest has one key, and the list is never empty.
    public let hostKeys: [HostKey]

    /// The JSON keys of an access.
    private enum CodingKeys: String, CodingKey {
        /// The user name.
        case username
        /// The password.
        case password
        /// The base64 blobs of the host keys.
        case hostKeys = "host_keys"
    }

    /// Creates an access from its values.
    ///
    /// - Parameters:
    ///   - username: The account's short user name.
    ///   - password: The account's password.
    ///   - hostKeys: The guest's pinned host keys.
    /// - Returns: The access, or `nil` when the user name or the password breaks the rules in the
    ///   type's overview or the list of keys is empty.
    public init?(username: String, password: String, hostKeys: [HostKey]) {
        guard Self.accepts(username: username, password: password), !hostKeys.isEmpty else {
            return nil
        }
        self.username = username
        self.password = password
        self.hostKeys = hostKeys
    }

    /// Decodes an access.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when a field is missing, the user name or the password breaks
    ///   the rules in the type's overview, the list of keys is empty, or a key is not an Ed25519
    ///   key blob.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        guard Self.accepts(username: username, password: password) else {
            throw DecodingError.dataCorruptedError(
                forKey: .username,
                in: container,
                debugDescription: "the guest's account cannot log in over SSH",
            )
        }
        let blobs = try container.decode([String].self, forKey: .hostKeys)
        let keys = blobs.compactMap { HostKey(base64: $0) }
        guard !keys.isEmpty, keys.count == blobs.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .hostKeys,
                in: container,
                debugDescription: "the guest's host keys must be one or more Ed25519 key blobs",
            )
        }
        hostKeys = keys
    }

    /// Encodes the access.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An error when the encoder rejects a value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
        try container.encode(hostKeys.map(\.base64), forKey: .hostKeys)
    }

    /// The user name and the fingerprints of the host keys, without the password.
    public var description: String {
        "GuestAccess(username: \(username), hostKeys: \(hostKeys.map(\.fingerprint)))"
    }

    /// Reports whether `ssh` can log in with a user name and a password.
    ///
    /// - Parameters:
    ///   - username: The account's short user name.
    ///   - password: The account's password.
    /// - Returns: Whether both follow the rules in the type's overview.
    private static func accepts(username: String, password: String) -> Bool {
        CredentialRotation.isPlainUsername(username)
            && !password.unicodeScalars.contains { "\n\r\0".unicodeScalars.contains($0) }
    }

    /// The same text as ``description``.
    public var debugDescription: String {
        description
    }

    /// The user name and the host keys, without the password.
    public var customMirror: Mirror {
        Mirror(self, children: ["username": username, "hostKeys": hostKeys.map(\.fingerprint)], displayStyle: .struct)
    }
}
