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
        let request = PoolRequest.invite(address: address, priorityCeiling: priorityCeiling)
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
        blocked and can't pair again.
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
