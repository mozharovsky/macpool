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

/// Prints the daemon's slots, leases, queue, and images.
struct ListCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Prints the daemon's slots, leases, queue, and images.",
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
            try Report.line(LeaseOutput.json(summary, describing: "the pool summary"))
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

    /// Encodes a value as JSON with sorted keys and ISO 8601 times.
    ///
    /// Strings keep their exact text. Scalars that a terminal would act on appear as escapes. See
    /// ``PeerText/escapedJSON(_:)``.
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    ///   - name: What the value holds, for the error message, such as `the pool summary`.
    /// - Returns: The JSON text.
    /// - Throws: ``CommandError/pool(_:)`` when the value cannot be encoded.
    static func json(_ value: some Encodable, describing name: String) throws(CommandError) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else {
            throw .pool(.malformedMessage(reason: "\(name) cannot be encoded"))
        }
        return PeerText.escapedJSON(String(decoding: data, as: UTF8.self))
    }

    /// Formats the pool as tables of leases and images, with one line per queued request.
    ///
    /// - Parameter pool: The pool.
    /// - Returns: The lines without line breaks.
    static func table(_ pool: PoolSummary) -> [String] {
        var lines = [
            "slots \(pool.slots), leases \(pool.leases.count), queued \(pool.queue.count), images \(pool.images.count)",
        ]
        if !pool.leases.isEmpty {
            let header = ["LEASE", "PHASE", "ADDRESS", "EXPIRES", "RESTARTS", "SOURCE"]
            lines += aligned([header] + pool.leases.map { lease in
                [
                    lease.id.rawValue,
                    lease.phase.rawValue,
                    lease.address ?? "-",
                    lease.expiresAt.map(timestamp) ?? "-",
                    String(lease.restarts),
                    lease.source,
                ]
            })
        }
        for request in pool.queue {
            let since = timestamp(request.since)
            lines.append("queued \(request.position): priority \(request.priority), since \(since), \(request.source)")
        }
        if !pool.images.isEmpty {
            lines += aligned([["IMAGE", "READY", "BUILDS"]] + pool.images.map { image in
                let builds = image.builds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                let detail = image.problem ?? (builds.isEmpty ? "-" : builds.joined(separator: ", "))
                return [image.name, image.isReady ? "yes" : "no", detail]
            })
        }
        return lines
    }

    /// Pads every column but the last to its widest cell.
    ///
    /// The isolates of ``PeerText`` take no room in a terminal and add nothing to a width.
    ///
    /// - Parameter rows: The rows, each with the same number of cells.
    /// - Returns: One line per row, with two spaces between columns.
    static func aligned(_ rows: [[String]]) -> [String] {
        // String.padding(toLength:) counts UTF-16 units and would cut a name with an emoji.
        let width = { (cell: String) in
            cell.count { $0 != PeerText.isolateStart && $0 != PeerText.isolateEnd }
        }
        let widths = rows[0].indices.map { column in rows.map { width($0[column]) }.max() ?? 0 }
        return rows.map { row in
            row.indices.map { column in
                column == row.count - 1 ? row[column]
                    : row[column] + String(repeating: " ", count: widths[column] - width(row[column]))
            }.joined(separator: "  ")
        }
    }
}
