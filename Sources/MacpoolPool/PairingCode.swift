import Foundation

/// The text that a client Mac uses once to pair with a host.
///
/// A code reads `macpool1:studio.local:7373:` followed by 52 base32 characters. The characters
/// carry the first 128 bits of the digest of the host's key and a secret of 128 bits. The client
/// connects to the address and port and accepts only a host key with that digest. The host then
/// accepts the client's key only with the secret.
///
/// A code works once and expires after 10 minutes. Anyone who has the code can pair in place of
/// the client. Pass it only to the person who pairs the client.
public struct PairingCode: Sendable, Equatable, Codable, CustomStringConvertible {
    /// The text before the first colon. It names the format.
    static let scheme = "macpool1"

    /// The number of bytes of the host key's digest in a code.
    static let hostKeyBytes = 16

    /// The number of bytes of a secret.
    static let secretBytes = 16

    /// The host's address, such as `example.local` or `192.0.2.20`.
    public let address: String

    /// The TCP port on which the host listens for paired Macs.
    public let port: UInt16

    /// The first bytes of the digest that names the host's key.
    let hostKeyPrefix: [UInt8]

    /// The one-time secret that the host checks.
    let secret: [UInt8]

    /// Creates a code for a host.
    ///
    /// - Parameters:
    ///   - address: The address that clients connect to. It must not be empty.
    ///   - port: The host's port.
    ///   - hostKey: The fingerprint of the host's key.
    ///   - secret: The secret, ``secretBytes`` bytes long.
    init(address: String, port: UInt16, hostKey: KeyFingerprint, secret: [UInt8]) {
        self.address = address
        self.port = port
        hostKeyPrefix = hostKey.leadingBytes(Self.hostKeyBytes)
        self.secret = secret
    }

    /// Reads a code.
    ///
    /// The address may contain colons, such as an IPv6 address, because the port and the key
    /// characters follow the last two colons.
    ///
    /// - Parameter text: The code. Spaces and line breaks around it are ignored.
    /// - Returns: `nil` when the text is not a code of this format. The address must have 1 to 253
    ///   ASCII letters, digits, dots, hyphens, colons, or percent signs.
    public init?(_ text: String) {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count >= 4, fields.first == Substring(Self.scheme),
              let port = UInt16(fields[fields.count - 2]), port != 0,
              let bytes = Base32.decode(String(fields[fields.count - 1])),
              bytes.count == Self.hostKeyBytes + Self.secretBytes else {
            return nil
        }
        let address = fields[1 ..< fields.count - 2].joined(separator: ":")
        // Error messages and the list of hosts show the address. A code therefore must not carry
        // terminal escapes in it.
        guard Self.isValidAddress(address) else {
            return nil
        }
        self.address = address
        self.port = port
        hostKeyPrefix = Array(bytes.prefix(Self.hostKeyBytes))
        secret = Array(bytes.suffix(Self.secretBytes))
    }

    /// Decodes a code from its text.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError.dataCorrupted` when the text is not a code.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let code = PairingCode(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a pairing code: \(text)")
        }
        self = code
    }

    /// Encodes the code as its text.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An error when the encoder rejects the value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Reports whether an address can be part of a code.
    ///
    /// - Parameter address: A host name or an IP address.
    /// - Returns: Whether the address has 1 to 253 characters, all of them ASCII letters, digits,
    ///   dots, hyphens, colons, or percent signs.
    static func isValidAddress(_ address: String) -> Bool {
        (1 ... 253).contains(address.utf8.count) && address.utf8.allSatisfy { byte in
            (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte | 0x20)
                || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                || Array(".-:%".utf8).contains(byte)
        }
    }

    /// Reports whether a host key matches the code.
    ///
    /// - Parameter key: The fingerprint of the key that the host presents.
    /// - Returns: Whether the key's digest starts with the bytes in the code.
    func matches(_ key: KeyFingerprint) -> Bool {
        key.leadingBytes(Self.hostKeyBytes) == hostKeyPrefix
    }

    /// The code's text.
    public var description: String {
        "\(Self.scheme):\(address):\(port):\(Base32.encode(hostKeyPrefix + secret))"
    }
}
