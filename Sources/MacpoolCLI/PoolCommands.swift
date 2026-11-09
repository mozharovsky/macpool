import ArgumentParser
import Foundation
import MacpoolPool

/// Ends a lease, which stops its VM and deletes its clone.
struct ReleaseCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Ends a lease, which stops its VM and deletes its clone.",
    )

    /// The daemon's data directory.
    @OptionGroup var location: PoolOptions

    /// The lease to end.
    @Argument(help: "The lease to end.")
    var lease: String

    /// Asks the daemon to end the lease.
    ///
    /// - Throws: ``CommandError`` when the identifier is malformed, no daemon answers, or the
    ///   daemon knows no such lease.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when the identifier is malformed, no daemon answers, or the
    ///   daemon knows no such lease.
    private func perform() async throws(CommandError) {
        let id = try LeaseID.parse(lease)
        let directory = location.directory
        _ = try await pool { () async throws(PoolError) in try await PoolClient.send(.release(id), to: directory) }
        Report.line("released \(id)")
    }
}

/// Moves a lease's expiry to its time to live after now.
struct RenewCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "renew",
        abstract: "Moves a lease's expiry to its time to live after now.",
    )

    /// The daemon's data directory.
    @OptionGroup var location: PoolOptions

    /// The lease to renew.
    @Argument(help: "The lease to renew.")
    var lease: String

    /// Asks the daemon to renew the lease and prints the new expiry.
    ///
    /// - Throws: ``CommandError`` when the identifier is malformed, no daemon answers, or the
    ///   lease is unknown or ending.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when the identifier is malformed, no daemon answers, or the
    ///   lease is unknown or ending.
    private func perform() async throws(CommandError) {
        let id = try LeaseID.parse(lease)
        let directory = location.directory
        let reply = try await pool { () async throws(PoolError) in
            try await PoolClient.send(.renew(id), to: directory)
        }
        guard case let .renewed(summary) = reply else {
            throw .pool(.malformedMessage(reason: "unexpected reply to renew"))
        }
        Report.line("expires_at=\(summary.expiresAt.map(LeaseOutput.timestamp) ?? "after the VM is ready")")
    }
}

/// Prints the daemon's slots, leases, and queue.
struct ListCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Prints the daemon's slots, leases, and queue.",
    )

    /// The daemon's data directory.
    @OptionGroup var location: PoolOptions

    /// Whether to print the pool as JSON.
    @Flag(help: "Prints the pool as one JSON object.")
    var json = false

    /// Asks the daemon for its state and prints it.
    ///
    /// - Throws: ``CommandError`` when no daemon answers.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when no daemon answers.
    private func perform() async throws(CommandError) {
        let directory = location.directory
        let reply = try await pool { () async throws(PoolError) in try await PoolClient.send(.status, to: directory) }
        guard case let .status(summary) = reply else {
            throw .pool(.malformedMessage(reason: "unexpected reply to list"))
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(summary) else {
                throw .pool(.malformedMessage(reason: "the pool summary cannot be encoded"))
            }
            Report.line(String(decoding: data, as: UTF8.self))
        } else {
            for line in LeaseOutput.table(summary) {
                Report.line(line)
            }
        }
    }
}

/// Parsing of lease identifiers from the command line.
extension LeaseID {
    /// Parses an identifier that a person typed.
    ///
    /// - Parameter text: The identifier.
    /// - Returns: The identifier.
    /// - Throws: ``CommandError/invalidValue(_:)`` when the text is not a lease identifier.
    static func parse(_ text: String) throws(CommandError) -> LeaseID {
        guard let id = LeaseID(text) else {
            throw .invalidValue("\(text) is not a lease identifier")
        }
        return id
    }
}

/// The text that the pool commands print.
enum LeaseOutput {
    /// Formats a time as ISO 8601 in UTC.
    ///
    /// - Parameter date: The time.
    /// - Returns: The time, such as `2026-11-09T18:20:00Z`.
    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Formats the pool as a table with one row per lease and one line per queued request.
    ///
    /// - Parameter pool: The pool.
    /// - Returns: The lines without line breaks.
    static func table(_ pool: PoolSummary) -> [String] {
        var lines = ["slots \(pool.slots), leases \(pool.leases.count), queued \(pool.queue.count)"]
        if !pool.leases.isEmpty {
            let rows = [["LEASE", "PHASE", "ADDRESS", "EXPIRES", "RESTARTS", "SOURCE"]] + pool.leases.map { lease in
                [
                    lease.id.rawValue,
                    lease.phase.rawValue,
                    lease.address ?? "-",
                    lease.expiresAt.map(timestamp) ?? "-",
                    String(lease.restarts),
                    lease.source,
                ]
            }
            let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
            for row in rows {
                let cells = row.indices.map { column in
                    column == row.count - 1 ? row[column] : row[column].padding(
                        toLength: widths[column],
                        withPad: " ",
                        startingAt: 0,
                    )
                }
                lines.append(cells.joined(separator: "  "))
            }
        }
        for request in pool.queue {
            let since = timestamp(request.since)
            lines.append("queued \(request.position): priority \(request.priority), since \(since), \(request.source)")
        }
        return lines
    }
}
