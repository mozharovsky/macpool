import MacpoolPool

/// Text that another Mac chose, such as a paired Mac's name, prepared for a terminal.
///
/// A terminal acts on some scalars instead of showing them. An escape character starts a terminal
/// command, a line separator breaks a table's row, and a format character such as U+202E reverses
/// the text after it. Strong right-to-left letters also reorder the columns next to them. Pass
/// every such text through this type before the command line prints it for a person. JSON output
/// keeps the exact text for the programs that read it.
enum PeerText {
    /// The First Strong Isolate. It starts text whose direction does not affect the text around it.
    static let isolateStart: Character = "\u{2068}"

    /// The Pop Directional Isolate. It ends the text that ``isolateStart`` started.
    static let isolateEnd: Character = "\u{2069}"

    /// Escapes the scalars that change how a terminal shows text.
    ///
    /// Each scalar in the general categories Cc, Cf, Zl, and Zp becomes its code point in
    /// hexadecimal, such as `\u{1B}` for the escape character. A backslash becomes two backslashes,
    /// so an escaped scalar cannot look like a name that contains the same characters.
    ///
    /// - Parameter text: The text from another Mac.
    /// - Returns: The text without those scalars.
    static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                result += scalar == "\\" ? "\\\\" : String(scalar)
            }
        }
        return result
    }

    /// Escapes text and isolates its direction from the text around it.
    ///
    /// - Parameter text: The text from another Mac.
    /// - Returns: The escaped text between ``isolateStart`` and ``isolateEnd``.
    static func isolated(_ text: String) -> String {
        "\(isolateStart)\(escaped(text))\(isolateEnd)"
    }

    /// Shows a paired Mac's name with the short key that tells it apart.
    ///
    /// Names are not unique, and two names that differ only in trailing spaces look the same.
    ///
    /// - Parameters:
    ///   - name: The name that the paired Mac chose.
    ///   - key: The paired Mac's key.
    /// - Returns: The isolated name and the short key, such as `runner (mzxw-6ytb-oi2d-k3lq)`.
    static func name(_ name: String, key: KeyFingerprint) -> String {
        "\(isolated(name)) (\(key.shortKey))"
    }
}
