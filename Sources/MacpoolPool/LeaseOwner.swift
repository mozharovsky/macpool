/// The SHA-256 digest of a public key's SubjectPublicKeyInfo, in 64 lowercase hexadecimal digits.
///
/// A paired Mac proves its key when it connects, and the daemon names that Mac by the key's
/// fingerprint.
public struct KeyFingerprint: Hashable, Sendable, CustomStringConvertible {
    /// The number of hexadecimal digits in a fingerprint.
    static let length = 64

    /// The fingerprint's text.
    public let rawValue: String

    /// Checks a fingerprint's text.
    ///
    /// - Parameter rawValue: The text.
    /// - Returns: `nil` when the text is not 64 lowercase hexadecimal digits.
    public init?(_ rawValue: String) {
        let isHex = rawValue.utf8.allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
        }
        guard rawValue.utf8.count == Self.length, isHex else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// The fingerprint's text.
    public var description: String {
        rawValue
    }
}

/// Who holds a lease and may act on it.
///
/// A client on the daemon's own socket acts for the user who runs the daemon. It may see and
/// change every lease. A paired client from another Mac may see and change only the leases that it
/// requested, and it cannot tell another lease from one that does not exist.
///
/// The state file stores the local user as `local` and a paired client as its key's fingerprint.
/// A new kind of owner needs a new format version of the file. An earlier build takes an owner
/// that it does not know for a malformed file and sets the file aside.
public enum LeaseOwner: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The user who runs the daemon, through its socket.
    case local

    /// A paired client, named by the fingerprint of its key.
    ///
    /// - Parameter fingerprint: The fingerprint of the key that the client proved.
    case client(KeyFingerprint)

    /// The stored text of the local user.
    private static let localText = "local"

    /// Decodes an owner from its text.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError.dataCorrupted` when the text is neither `local` nor a fingerprint.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        if text == Self.localText {
            self = .local
        } else if let fingerprint = KeyFingerprint(text) {
            self = .client(fingerprint)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a lease owner: \(text)")
        }
    }

    /// Encodes the owner as its text.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An error when the encoder rejects the value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .local:
            try container.encode(Self.localText)
        case let .client(fingerprint):
            try container.encode(fingerprint.rawValue)
        }
    }

    /// The owner for logs, with a paired client's fingerprint shortened to 16 digits.
    public var description: String {
        switch self {
        case .local:
            Self.localText
        case let .client(fingerprint):
            "client \(fingerprint.rawValue.prefix(16))"
        }
    }

    /// Reports whether this owner may see and change a lease.
    ///
    /// - Parameter lease: The owner of the lease.
    /// - Returns: `true` for the local user and for the client that holds the lease.
    func mayAct(on lease: LeaseOwner) -> Bool {
        self == .local || self == lease
    }
}
