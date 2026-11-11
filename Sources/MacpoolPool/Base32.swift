/// Base32 text from RFC 4648 in lowercase and without padding.
///
/// People read and type this text. Its alphabet leaves out 0, 1, and 8 because people confuse
/// them with O, I, and B.
enum Base32 {
    /// The 32 characters, in the order of their values.
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    /// Encodes bytes, five bits per character.
    ///
    /// - Parameter bytes: The data, encoded from the most significant bit of the first byte.
    /// - Returns: The text. If the bit count is not a multiple of five, the last character
    ///   carries zero bits after the data.
    static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var text: [UInt8] = []
        var buffer: UInt32 = 0
        var bufferedBits = 0
        for byte in bytes {
            buffer = buffer << 8 | UInt32(byte)
            bufferedBits += 8
            while bufferedBits >= 5 {
                bufferedBits -= 5
                text.append(alphabet[Int(buffer >> UInt32(bufferedBits) & 0x1F)])
            }
        }
        if bufferedBits > 0 {
            text.append(alphabet[Int(buffer << UInt32(5 - bufferedBits) & 0x1F)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// Decodes text from ``encode(_:)``.
    ///
    /// Uppercase letters decode like lowercase ones, because people may type either.
    ///
    /// - Parameter text: The text, without padding.
    /// - Returns: The bytes, or `nil` when the text has a character outside the alphabet, a
    ///   length that no byte count encodes to, or bits other than zero after the data.
    static func decode(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var bufferedBits = 0
        for character in text.utf8 {
            guard let value = alphabet.firstIndex(of: lowercase(character)) else {
                return nil
            }
            buffer = buffer << 5 | UInt32(value)
            bufferedBits += 5
            if bufferedBits >= 8 {
                bufferedBits -= 8
                bytes.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bufferedBits)))
            }
        }
        // A complete encoding leaves fewer than five bits, and they are zero.
        guard bufferedBits < 5, buffer & (1 << UInt32(bufferedBits) - 1) == 0 else {
            return nil
        }
        return bytes
    }

    /// Converts an uppercase ASCII letter to lowercase and leaves other bytes alone.
    ///
    /// - Parameter character: A UTF-8 byte.
    /// - Returns: The byte of the lowercase letter, or `character`.
    private static func lowercase(_ character: UInt8) -> UInt8 {
        (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(character) ? character + 32 : character
    }
}
