import ArgumentParser
import Foundation
import MacpoolPool

/// Opens an invitation for another Mac and waits until that Mac pairs.
struct HostInviteCommand: AsyncParsableCommand {
    /// The subcommand's name, summary, and discussion.
    static let configuration = CommandConfiguration(
        commandName: "invite",
        abstract: "Prints a code that lets one Mac pair with this Mac and waits until it pairs.",
        discussion: """
        The code works once, for 10 minutes, and only while this command runs. The daemon on \
        this Mac must listen for paired Macs. See macpool daemon install --listen.
        """,
    )

    /// The data directory of this Mac's daemon.
    @OptionGroup var location: PoolOptions

    /// The address that the code gives the other Mac, or `nil` for the address that the daemon
    /// listens on.
    @Option(
        name: .customLong("address"),
        help: """
        The address that the other Mac connects to, such as a DNS name of this Mac. The default is \
        the address that the daemon listens on.
        """,
    )
    var address: String?

    /// The highest priority that the Mac that pairs may ask for.
    @Option(
        name: .customLong("priority-ceiling"),
        help: "The highest priority that the Mac may ask for when it leases.",
    )
    var priorityCeiling = 0

    /// Whether the Mac may report to this Mac's daemon as a host.
    @Flag(
        name: .customLong("may-host"),
        help: """
        Lets the Mac report to this Mac as a host, so that this Mac places leases on it as their \
        coordinator. A Mac that is already paired gains this right too.
        """,
    )
    var mayHost = false

    /// Rejects a negative priority ceiling.
    ///
    /// - Throws: `ValidationError` when the ceiling is below 0.
    func validate() throws {
        guard priorityCeiling >= 0 else {
            throw ValidationError("--priority-ceiling must be 0 or more.")
        }
    }

    /// Opens the invitation, prints its code, and waits until a Mac pairs.
    ///
    /// - Throws: ``CommandError/pool(_:)`` when no daemon answers, the daemon refuses the
    ///   invitation, or the invitation ends without a pairing.
    func run() async throws {
        try await perform(printing: Report.line, warning: Report.warning)
    }

    /// Opens the invitation and reports its progress until a Mac pairs.
    ///
    /// The command prints `code=` and `expires_at=` first. When a Mac pairs, it prints `paired`
    /// with the Mac's short key and name. If the Mac had paired before, the line starts with
    /// `already paired` instead.
    ///
    /// - Parameters:
    ///   - printing: Prints a line on standard output.
    ///   - warning: Prints a warning on standard error.
    /// - Throws: ``CommandError/pool(_:)`` when no daemon answers, the daemon refuses the
    ///   invitation, the invitation expires or another invitation replaces it, or the daemon stops.
    func perform(printing: (String) -> Void, warning: (String) -> Void) async throws(CommandError) {
        let directory = location.directory
        let channel = try await pool { () async throws(PoolError) in try await PoolClient.connect(to: directory) }
        defer { channel.close() }
        let request = PoolRequest.invite(address: address, priorityCeiling: priorityCeiling, mayHost: mayHost)
        try pool { () throws(PoolError) in try channel.send(request) }
        while true {
            let reply = try await pool { () async throws(PoolError) in try await channel.receive(PoolReply.self) }
            switch reply {
            case let .invitation(code, expiresAt)?:
                printing("code=\(code)")
                printing("expires_at=\(LeaseOutput.timestamp(expiresAt))")
            case .wrongCode?:
                warning("A Mac sent a wrong code. The invitation stays open.")
            case let .paired(mac)?:
                printing("paired \(PeerText.name(mac.name, key: mac.key))")
                return
            case let .alreadyPaired(mac)?:
                printing("already paired \(PeerText.name(mac.name, key: mac.key))")
                return
            case let .failure(message)?:
                throw .pool(.daemonRefused(message: message))
            case nil:
                throw .pool(.connectionClosed)
            case .some:
                throw .pool(.malformedMessage(reason: "unexpected reply to an invitation"))
            }
        }
    }
}

/// Blocks a paired Mac and closes its connections.
struct HostRevokeCommand: AsyncParsableCommand {
    /// The subcommand's name, summary, and discussion.
    static let configuration = CommandConfiguration(
        commandName: "revoke",
        abstract: "Blocks a paired Mac and closes its connections.",
        discussion: """
        The Mac's queued requests and its leases with a connection end. Its detached leases run \
        until they expire unless you pass --end-leases. The Mac stays in macpool host list as \
        blocked and can't connect or pair again until macpool host unblock.
        """,
    )

    /// The data directory of this Mac's daemon.
    @OptionGroup var location: PoolOptions

    /// The Mac's short key or full key.
    @Argument(help: "The Mac's short key or full key from macpool host list.")
    var key: String

    /// Whether the daemon also ends the Mac's detached leases.
    @Flag(name: .customLong("end-leases"), help: "Also ends the Mac's detached leases.")
    var endLeases = false

    /// Asks the daemon to revoke the Mac and prints the result.
    ///
    /// - Throws: ``CommandError/pool(_:)`` when no daemon answers or the daemon cannot revoke
    ///   the Mac.
    func run() async throws {
        for line in try await lines() {
            Report.line(line)
        }
    }

    /// Asks the daemon to revoke the Mac.
    ///
    /// The command lowercases the key, because the daemon compares it with keys in lowercase.
    ///
    /// - Returns: The line that names the revoked Mac and the connections and leases that ended.
    /// - Throws: ``CommandError/pool(_:)`` when no daemon answers, no paired Mac has the key, a
    ///   short key names more than one Mac, or the daemon cannot save the block.
    func lines() async throws(CommandError) -> [String] {
        let request = PoolRequest.revoke(key: key.lowercased(), endLeases: endLeases)
        let directory = location.directory
        let reply = try await pool { () async throws(PoolError) in try await PoolClient.send(request, to: directory) }
        guard case let .revoked(mac, connections, leases) = reply else {
            throw .pool(.malformedMessage(reason: "unexpected reply to revoke"))
        }
        return ["revoked \(PeerText.name(mac.name, key: mac.key)) connections=\(connections) leases=\(leases)"]
    }
}

/// Lets a revoked Mac connect again.
struct HostUnblockCommand: AsyncParsableCommand {
    /// The subcommand's name, summary, and discussion.
    static let configuration = CommandConfiguration(
        commandName: "unblock",
        abstract: "Lets a revoked Mac connect again.",
        discussion: """
        The Mac keeps its name and priority ceiling. It connects with its key as before and needs \
        no new code.
        """,
    )

    /// The data directory of this Mac's daemon.
    @OptionGroup var location: PoolOptions

    /// The Mac's short key or full key.
    @Argument(help: "The Mac's short key or full key from macpool host list.")
    var key: String

    /// Asks the daemon to unblock the Mac and prints the result.
    ///
    /// - Throws: ``CommandError/pool(_:)`` when no daemon answers or the daemon cannot unblock
    ///   the Mac.
    func run() async throws {
        for line in try await lines() {
            Report.line(line)
        }
    }

    /// Asks the daemon to unblock the Mac.
    ///
    /// The command lowercases the key, because the daemon compares it with keys in lowercase.
    ///
    /// - Returns: The line that names the unblocked Mac.
    /// - Throws: ``CommandError/pool(_:)`` when no daemon answers, no paired Mac has the key, a
    ///   short key names more than one Mac, or the daemon cannot save the list.
    func lines() async throws(CommandError) -> [String] {
        let request = PoolRequest.unblock(key: key.lowercased())
        let directory = location.directory
        let reply = try await pool { () async throws(PoolError) in try await PoolClient.send(request, to: directory) }
        guard case let .unblocked(mac) = reply else {
            throw .pool(.malformedMessage(reason: "unexpected reply to unblock"))
        }
        return ["unblocked \(PeerText.name(mac.name, key: mac.key))"]
    }
}

/// Pairs this Mac with a host from the code that `macpool host invite` printed on the host.
struct PoolAddCommand: AsyncParsableCommand {
    /// The subcommand's name, summary, and discussion.
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Pairs this Mac with a host from the code of macpool host invite.",
        discussion: """
        Without a code, the command reads it from standard input, so the code stays out of the \
        process list.
        """,
    )

    /// The data directory of this Mac's daemon, which holds this Mac's key and paired hosts.
    @OptionGroup var location: PoolOptions

    /// The code from the host, or `nil` to read it from standard input.
    @Argument(help: "The code that macpool host invite printed on the host.")
    var code: String?

    /// The name that the host shows for this Mac, or `nil` for this Mac's name.
    @Option(
        name: .customLong("name"),
        help: "The name that the host shows for this Mac. The default is this Mac's name.",
    )
    var name: String?

    /// Rejects a name that a host would refuse.
    ///
    /// - Throws: `ValidationError` when the name is not a valid name for a Mac.
    func validate() throws {
        if let name, !PairedMac.isValidName(name) {
            throw ValidationError("--name takes \(PairedMac.nameRule).")
        }
    }

    /// Pairs with the host and prints the host and this Mac's key.
    ///
    /// - Throws: ``CommandError`` when the code is malformed or the pairing fails.
    func run() async throws {
        let text: String
        if let code {
            text = code
        } else {
            guard let line = readLine() else {
                throw CommandError.invalidValue("no code on standard input")
            }
            text = line
        }
        for line in try await lines(pairingWith: text) {
            Report.line(line)
        }
    }

    /// Pairs with the host of a code.
    ///
    /// - Parameter text: The code.
    /// - Returns: The line `paired` with the host's short key and name, and the line `this_mac=`
    ///   with this Mac's short key.
    /// - Throws: ``CommandError/invalidValue(_:)`` when the text is not a pairing code, or
    ///   ``CommandError/pool(_:)`` when the pairing fails. A host's text in the error passes
    ///   through ``HostSelection/escapingPeerText(_:)``.
    func lines(pairingWith text: String) async throws(CommandError) -> [String] {
        guard let code = PairingCode(text) else {
            throw .invalidValue("\(PeerText.escaped(text)) is not a pairing code. macpool host invite prints one")
        }
        let directory = location.directory
        let host: PairedMac
        do {
            host = try await PoolClient.pair(using: code, name: name ?? PairedMac.localName(), directory: directory)
        } catch {
            throw .pool(HostSelection.escapingPeerText(error))
        }
        let key = try pool { () throws(PoolError) in try KeyFingerprint.thisMac(in: directory) }
        return ["paired \(PeerText.name(host.name, key: host.key))", "this_mac=\(key.shortKey)"]
    }
}

/// Ends this Mac's pairing with a host.
struct PoolRemoveCommand: AsyncParsableCommand {
    /// The subcommand's name, summary, and discussion.
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Ends this Mac's pairing with a host.",
        discussion: """
        The command asks the host to forget this Mac and then removes the host from this Mac's \
        list. With --local, it only removes the host from this Mac's list, and the host keeps \
        this Mac's record.
        """,
    )

    /// The data directory of this Mac's daemon, which holds this Mac's key and paired hosts.
    @OptionGroup var location: PoolOptions

    /// The host's name or key.
    @Argument(help: "The host's name or short key from macpool pool list.")
    var host: String

    /// Whether the host also ends this Mac's leases.
    @Flag(name: .customLong("end-leases"), help: "Ends this Mac's leases on the host.")
    var endLeases = false

    /// Whether the command skips the host.
    @Flag(
        name: .customLong("local"),
        help: "Removes the host from this Mac's list without asking the host, for example when the host is gone.",
    )
    var local = false

    /// Rejects `--end-leases` together with `--local`.
    ///
    /// - Throws: `ValidationError` when both flags are set.
    func validate() throws {
        guard !(endLeases && local) else {
            throw ValidationError("--end-leases needs the host, so it doesn't work with --local.")
        }
    }

    /// Ends the pairing and prints the result.
    ///
    /// - Throws: ``CommandError`` when the host is unknown, the host does not forget this Mac,
    ///   or the list cannot be saved.
    func run() async throws {
        for line in try await lines() {
            Report.line(line)
        }
    }

    /// Asks the host to forget this Mac, unless `--local` is set, and removes the host from the
    /// list.
    ///
    /// - Returns: The line `removed` with the host's short key and name. Without `--local`, the
    ///   line ends with the number of this Mac's leases that the host ended.
    /// - Throws: ``CommandError/pool(_:)`` when no host or more than one host matches or the list
    ///   cannot be read or saved, or ``CommandError/hostKeptPairing(host:reason:)`` when the host
    ///   cannot be reached or refuses. A host's text in the error passes through
    ///   ``HostSelection/escapingPeerText(_:)``.
    func lines() async throws(CommandError) -> [String] {
        let directory = location.directory
        let paired: TrustedHost
        do {
            paired = try TrustedHost.named(host, in: directory)
        } catch {
            throw .pool(HostSelection.escapingPeerText(error))
        }
        let shown = PeerText.name(paired.name, key: paired.key)
        var line = "removed \(shown)"
        if !local {
            let reply: PoolReply
            do {
                reply = try await PoolClient.send(.forget(endLeases: endLeases), to: paired, directory: directory)
            } catch {
                throw .hostKeptPairing(host: shown, reason: HostSelection.escapingPeerText(error).description)
            }
            guard case let .forgotten(leases) = reply else {
                throw .pool(.malformedMessage(reason: "unexpected reply to a request to forget this Mac"))
            }
            line += " leases=\(leases)"
        }
        try pool { () throws(PoolError) in try TrustedHost.remove(paired.key, from: directory) }
        return [line]
    }
}
