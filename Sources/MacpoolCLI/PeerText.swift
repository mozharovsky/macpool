import MacpoolPool

/// Text that another Mac chose, such as a paired Mac's name, prepared for a terminal.
///
/// A terminal acts on some scalars instead of showing them. An escape character starts a terminal
/// command, a line separator breaks a table's row, and a format character such as U+202E reverses
/// the text after it. Strong right-to-left letters also reorder the columns next to them. Pass
/// every such text through this type before the command line prints it for a person.
///
/// A name can hold text that looks like a short key. Print the real short key before the name,
/// where the name cannot reach it.
enum PeerText {
    /// The First Strong Isolate. It starts text whose direction does not affect the text around it.
    static let isolateStart: Character = "\u{2068}"

    /// The Pop Directional Isolate. It ends the text that ``isolateStart`` started.
    static let isolateEnd: Character = "\u{2069}"

    /// Escapes the scalars that the pairing check refuses in a name.
    ///
    /// Each scalar that `PairedMac.isPrintable(_:)` refuses becomes its code point in hexadecimal,
    /// such as `\u{1B}` for the escape character. These are the controls, format characters, line
    /// and paragraph separators, private-use and unassigned scalars, and default-ignorable scalars
    /// such as variation selectors. A backslash becomes two backslashes, so an escaped scalar
    /// cannot look like a name that contains the same characters.
    ///
    /// - Parameter text: The text from another Mac.
    /// - Returns: The text without those scalars.
    static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if !PairedMac.isPrintable(scalar) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
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

    /// Shows a paired Mac's short key and then its name, for a message of one line.
    ///
    /// Names are not unique, and two names that differ only in trailing spaces look the same.
    ///
    /// - Parameters:
    ///   - name: The name that the paired Mac chose.
    ///   - key: The paired Mac's key.
    /// - Returns: The short key and the isolated name, such as `mzxw-6ytb-oi2d-k3lq runner`.
    static func name(_ name: String, key: KeyFingerprint) -> String {
        "\(key.shortKey) \(isolated(name))"
    }

    /// Escapes the scalars in JSON text that `JSONEncoder` leaves as they are.
    ///
    /// The encoder escapes only U+0000 to U+001F. This function writes every other scalar that
    /// `PairedMac.isPrintable(_:)` refuses as `\uXXXX`, with a surrogate pair above U+FFFF. A JSON
    /// parser reads the same strings back. Outside strings, JSON text has only printable ASCII and
    /// line breaks, so each escape lands inside a string.
    ///
    /// - Parameter json: The encoder's output.
    /// - Returns: The JSON text with those scalars escaped.
    static func escapedJSON(_ json: String) -> String {
        var result = ""
        for scalar in json.unicodeScalars {
            // The encoder already escaped these scalars inside strings. The ones left are the line
            // breaks of pretty printing.
            guard scalar.value > 0x1F, !PairedMac.isPrintable(scalar) else {
                result.unicodeScalars.append(scalar)
                continue
            }
            for unit in String(scalar).utf16 {
                let digits = String(unit, radix: 16, uppercase: true)
                result += "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
            }
        }
        return result
    }
}
