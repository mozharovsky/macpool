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
        let clients = try pool { () throws(PoolError) in try TrustedClient.paired(in: directory) }
        if json {
            return try [LeaseOutput.json(clients, describing: "the list of paired clients")]
        }
        guard !clients.isEmpty else {
            return ["no paired clients"]
        }
        return LeaseOutput.aligned([["PAIRED", "BLOCKED", "CEILING", "CLIENT"]] + clients.map { client in
            [
                LeaseOutput.timestamp(client.pairedAt),
                client.isBlocked ? "yes" : "no",
                String(client.priorityCeiling),
                PeerText.name(client.name, key: client.key),
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
        let hosts = try pool { () throws(PoolError) in try TrustedHost.paired(in: directory) }
        if json {
            return try [LeaseOutput.json(hosts, describing: "the list of paired hosts")]
        }
        guard !hosts.isEmpty else {
            return ["no paired hosts"]
        }
        return LeaseOutput.aligned([["PAIRED", "ADDRESS", "PORT", "HOST"]] + hosts.map { host in
            [
                LeaseOutput.timestamp(host.pairedAt),
                PeerText.isolated(host.address),
                String(host.port),
                PeerText.name(host.name, key: host.key),
            ]
        })
    }
}
