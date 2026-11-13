import ArgumentParser
import MacpoolPool

/// Shows the Macs that paired with this Mac as clients.
struct HostCommand: ParsableCommand {
    /// The subcommand's name, summary, and subcommands.
    static let configuration = CommandConfiguration(
        commandName: "host",
        abstract: "Shows the Macs that may lease VMs from this Mac.",
        subcommands: [HostListCommand.self],
    )
}

/// Prints the clients in this Mac's `clients.json` without asking the daemon.
struct HostListCommand: ParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Prints the Macs that paired with this Mac as clients.",
    )

    /// The data directory that holds the list.
    @OptionGroup var location: PoolOptions

    /// Whether to print the records as JSON.
    @Flag(help: "Prints the clients as one JSON array with the exact names.")
    var json = false

    /// Reads the list and prints it.
    ///
    /// - Throws: ``CommandError/pool(_:)`` when the list cannot be read.
    func run() throws {
        for line in try lines() {
            Report.line(line)
        }
    }

    /// Reads the list and formats it.
    ///
    /// - Returns: The lines to print without line breaks.
    /// - Throws: ``CommandError/pool(_:)`` when the list cannot be read.
    func lines() throws(CommandError) -> [String] {
        let directory = location.directory
        let clients = try readList { () throws(PoolError) in try TrustedClient.paired(in: directory) }
        if json {
            return try [LeaseOutput.json(clients, describing: "the list of paired clients")]
        }
        guard !clients.isEmpty else {
            return ["no paired clients"]
        }
        return LeaseOutput.aligned([["PAIRED", "BLOCKED", "CEILING", "KEY", "CLIENT"]] + clients.map { client in
            [
                LeaseOutput.timestamp(client.pairedAt),
                client.isBlocked ? "yes" : "no",
                String(client.priorityCeiling),
                client.key.shortKey,
                PeerText.isolated(client.name),
            ]
        })
    }
}

/// Shows the hosts that this Mac paired with as a client.
struct PoolCommand: ParsableCommand {
    /// The subcommand's name, summary, and subcommands.
    static let configuration = CommandConfiguration(
        commandName: "pool",
        abstract: "Shows the Macs that this Mac may lease VMs from.",
        subcommands: [PoolListCommand.self],
    )
}

/// Prints the hosts in this Mac's `hosts.json` without asking the daemon.
struct PoolListCommand: ParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Prints the hosts that this Mac paired with.",
    )

    /// The data directory that holds the list.
    @OptionGroup var location: PoolOptions

    /// Whether to print the records as JSON.
    @Flag(help: "Prints the hosts as one JSON array with the exact names and addresses.")
    var json = false

    /// Reads the list and prints it.
    ///
    /// - Throws: ``CommandError/pool(_:)`` when the list cannot be read.
    func run() throws {
        for line in try lines() {
            Report.line(line)
        }
    }

    /// Reads the list and formats it.
    ///
    /// - Returns: The lines to print without line breaks.
    /// - Throws: ``CommandError/pool(_:)`` when the list cannot be read.
    func lines() throws(CommandError) -> [String] {
        let directory = location.directory
        let hosts = try readList { () throws(PoolError) in try TrustedHost.paired(in: directory) }
        if json {
            return try [LeaseOutput.json(hosts, describing: "the list of paired hosts")]
        }
        guard !hosts.isEmpty else {
            return ["no paired hosts"]
        }
        return LeaseOutput.aligned([["PAIRED", "ADDRESS", "PORT", "KEY", "HOST"]] + hosts.map { host in
            [
                LeaseOutput.timestamp(host.pairedAt),
                PeerText.isolated(host.address),
                String(host.port),
                host.key.shortKey,
                PeerText.isolated(host.name),
            ]
        })
    }
}

/// Reads a list of paired Macs and wraps its error for the command line.
///
/// The reason of an unusable list can quote text from the file, which someone may have edited.
/// The reason therefore passes through ``PeerText/escaped(_:)``.
///
/// - Parameter read: The read of the list.
/// - Returns: The records.
/// - Throws: ``CommandError/pool(_:)`` with the read's error.
private func readList<Record>(_ read: () throws(PoolError) -> [Record]) throws(CommandError) -> [Record] {
    do {
        return try read()
    } catch let .unusableTrustList(path, reason) {
        throw .pool(.unusableTrustList(path: path, reason: PeerText.escaped(reason)))
    } catch {
        throw .pool(error)
    }
}
