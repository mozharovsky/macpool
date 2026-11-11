/// Base32 text from RFC 4648 in lowercase and without padding.
///
/// People read and type this text. Its alphabet leaves out 0, 1, and 8 because people confuse
/// them with O, I, and B.
enum Base32 {
    /// The 32 characters, in the order of their values.
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    /// Encodes bytes, five bits per character.
    ///
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
}
