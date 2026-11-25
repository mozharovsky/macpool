import ArgumentParser
import Foundation
import MacpoolPool

/// The options that make the daemon listen for paired Macs.
///
/// Without `--listen` the daemon serves only its local socket. `daemon install` writes the
/// options into the launchd job with ``arguments``, so `daemon run` parses them again at each
/// start of the job.
struct ListenOptions: ParsableArguments {
    /// The address and port to listen on, or `nil` when the daemon serves only its local socket.
    @Option(
        name: .customLong("listen"),
        help: ArgumentHelp(
            """
            Listens for paired Macs on a numeric IP address of this Mac, such as 192.0.2.20 or \
            [2001:db8::20]:7373. The default port is \(ListenAddress.defaultPort).
            """,
            valueName: "address[:port]",
        ),
        transform: ListenAddress.init(parsing:),
    )
    var address: ListenAddress?

    /// The name that a Mac receives for this host when it pairs, or `nil` for this Mac's name in
    /// Sharing settings.
    @Option(
        name: .customLong("host-name"),
        help: "The name that a Mac sees for this host when it pairs. The default is this Mac's name. Needs --listen.",
    )
    var hostName: String?

    /// The sources that paired Macs may lease, in the order of the command line.
    @Option(
        name: .customLong("offer"),
        help: ArgumentHelp(
            "A stopped source that paired Macs may lease by its name. Repeat it for more sources. Needs --listen.",
            valueName: "name=bundle",
        ),
        transform: OfferedSource.init(parsing:),
    )
    var offers: [OfferedSource] = []

    /// The ranges of addresses that may connect, in the order of the command line.
    @Option(
        name: .customLong("allow-from"),
        help: ArgumentHelp(
            """
            A range of addresses that may connect, such as 100.64.0.0/10 or 192.0.2.30. Repeat it \
            for more ranges. The default lets every address connect. Needs --listen.
            """,
            valueName: "cidr",
        ),
        transform: ListenOptions.range(parsing:),
    )
    var allowedSources: [AddressRange] = []

    /// Rejects options that need `--listen` without it, an invalid host name, and a source name
    /// that appears twice.
    ///
    /// - Throws: `ValidationError` for each of these cases.
    func validate() throws {
        guard address != nil || (hostName == nil && offers.isEmpty && allowedSources.isEmpty) else {
            throw ValidationError("--host-name, --offer, and --allow-from need --listen.")
        }
        if let hostName, !PairedMac.isValidName(hostName) {
            throw ValidationError("--host-name takes \(PairedMac.nameRule).")
        }
        var names: Set<String> = []
        for offer in offers where !names.insert(offer.name).inserted {
            throw ValidationError("--offer names the source \(offer.name) twice.")
        }
    }

    /// The listener's settings for the daemon, or `nil` without `--listen`.
    var settings: PeerSettings? {
        address.map {
            PeerSettings(name: hostName, address: $0.address, port: $0.port, allowedSources: allowedSources)
        }
    }

    /// The absolute paths of the offered sources, keyed by their names.
    var offeredSources: [String: String] {
        Dictionary(offers.map { ($0.name, $0.path) }) { first, _ in first }
    }

    /// The options in the form that `daemon run` parses, with absolute paths.
    ///
    /// Each option and its value form one argument, such as `--host-name=lab`. A value that starts
    /// with `-` would otherwise read as another option.
    var arguments: [String] {
        guard let address else {
            return []
        }
        var arguments = ["--listen=\(address)"]
        if let hostName {
            arguments.append("--host-name=\(hostName)")
        }
        for offer in offers {
            arguments.append("--offer=\(offer.name)=\(offer.path)")
        }
        for range in allowedSources {
            arguments.append("--allow-from=\(range)")
        }
        return arguments
    }

    /// Reads a range of `--allow-from`.
    ///
    /// - Parameter text: The range in CIDR notation, or one address.
    /// - Returns: The range.
    /// - Throws: `ValidationError` when `AddressRange.init(_:)` refuses the text.
    static func range(parsing text: String) throws -> AddressRange {
        guard let range = AddressRange(text) else {
            throw ValidationError("""
            --allow-from \(text) needs a numeric address with an optional prefix length, such as \
            100.64.0.0/10. The bits after the prefix must be zero.
            """)
        }
        return range
    }
}

/// A numeric IP address and a TCP port for the listener for paired Macs.
struct ListenAddress: Equatable, CustomStringConvertible {
    /// The port that `--listen` takes when the text names none.
    ///
    /// Clients keep the port from the pairing code, so the port stays the same across restarts.
    static let defaultPort: UInt16 = 7373

    /// The numeric address, without brackets.
    let address: String

    /// The port, from 1 to 65535.
    let port: UInt16

    /// Creates an address and a port that a caller checked.
    ///
    /// - Parameters:
    ///   - address: A numeric address that `PeerSettings.isValidAddress(_:)` accepts.
    ///   - port: The port.
    init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }

    /// Reads an address with an optional port.
    ///
    /// An IPv4 address takes the port after a colon, such as `192.0.2.20:7373`. An IPv6 address
    /// with a port goes in brackets, such as `[2001:db8::20]:7373`.
    ///
    /// - Parameter text: The text of `--listen`.
    /// - Throws: `ValidationError` when the text is not a numeric address that the listener can
    ///   bind to, the port is not a number from 1 to 65535, or an IPv4 address has brackets.
    init(parsing text: String) throws {
        let host: Substring
        let portText: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else {
                throw ValidationError("\(text) has no closing bracket.")
            }
            host = text[text.index(after: text.startIndex) ..< close]
            let rest = text[text.index(after: close)...]
            guard host.contains(":"), rest.isEmpty || rest.hasPrefix(":") else {
                throw ValidationError("Brackets hold only an IPv6 address, and only :port may follow them.")
            }
            portText = rest.isEmpty ? nil : rest.dropFirst()
        } else if text.count(where: { $0 == ":" }) == 1, let colon = text.firstIndex(of: ":") {
            host = text[..<colon]
            portText = text[text.index(after: colon)...]
        } else {
            host = text[...]
            portText = nil
        }
        guard PeerSettings.isValidAddress(String(host)) else {
            throw ValidationError("""
            \(text) needs a numeric IP address of this Mac, such as 192.0.2.20 or [2001:db8::20]:7373. \
            A host name, 0.0.0.0, ::, and a zone such as %en0 don't work.
            """)
        }
        address = String(host)
        if let portText {
            guard let port = UInt16(portText), port > 0 else {
                throw ValidationError("The port in \(text) must be a number from 1 to 65535.")
            }
            self.port = port
        } else {
            port = Self.defaultPort
        }
    }

    /// The address and the port, with an IPv6 address in brackets.
    var description: String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}

/// A source that paired Macs may lease by its name.
struct OfferedSource: Equatable {
    /// The name that a paired Mac passes to `--from`.
    let name: String

    /// The absolute path of the stopped source bundle.
    let path: String

    /// Reads a source in the form `name=bundle`.
    ///
    /// A relative bundle path resolves against the current directory, because the launchd job
    /// runs in the root directory.
    ///
    /// - Parameter text: The text of `--offer`.
    /// - Throws: `ValidationError` when the text has no `=`, the bundle is empty, or the name is
    ///   not a valid name for a Mac or contains `/`.
    init(parsing text: String) throws {
        guard let equals = text.firstIndex(of: "=") else {
            throw ValidationError("--offer takes name=bundle, such as base=.cache/vms/base.")
        }
        let name = String(text[..<equals])
        let bundle = String(text[text.index(after: equals)...])
        // A slash and a combining mark after it form one Character, so the check reads bytes.
        guard PairedMac.isValidName(name), !name.utf8.contains(UInt8(ascii: "/")) else {
            throw ValidationError("The name in --offer takes \(PairedMac.nameRule), without /.")
        }
        guard !bundle.isEmpty else {
            throw ValidationError("--offer \(text) names no bundle.")
        }
        var path = URL(filePath: bundle).standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        self.name = name
        self.path = path
    }
}
