import Foundation

/// The state that a host sends to its coordinator in ``PoolRequest/report(_:)``.
///
/// The host computes ``available`` itself. The coordinator places a lease only on a host whose
/// last report has an available slot and offers the requested source.
public struct HostReport: Codable, Sendable, Equatable {
    /// The most sources that one report may name.
    public static let maximumSources = 64

    /// The address of the host's listener, which clients of the coordinator connect to.
    public var address: String

    /// The port of the host's listener.
    public var port: UInt16

    /// The number of VMs that the host runs at once.
    public var slots: Int

    /// The number of leases that hold a slot.
    public var leases: Int

    /// The number of requests that wait in the host's own queue.
    public var queued: Int

    /// The number of leases that the host can start now for the coordinator, 0 or more.
    public var available: Int

    /// The names of the sources that the host offers to paired Macs, in ascending order.
    public var sources: [String]

    /// Creates a report.
    ///
    /// - Parameters:
    ///   - address: The address of the host's listener.
    ///   - port: The port of the host's listener.
    ///   - slots: The number of VMs that the host runs at once.
    ///   - leases: The number of leases that hold a slot.
    ///   - queued: The number of requests in the host's own queue.
    ///   - available: The number of leases that the host can start now for the coordinator.
    ///   - sources: The names of the offered sources.
    public init(
        address: String,
        port: UInt16,
        slots: Int,
        leases: Int,
        queued: Int,
        available: Int,
        sources: [String],
    ) {
        self.address = address
        self.port = port
        self.slots = slots
        self.leases = leases
        self.queued = queued
        self.available = available
        self.sources = sources
    }

    /// Checks that the coordinator can use the report.
    ///
    /// - Throws: ``PoolError/invalidRequest(reason:)`` when the address cannot be part of a pairing
    ///   code, the port is 0, a count is below 0, more leases are available than the host has
    ///   slots, or a source name is not valid or repeats.
    public func validate() throws(PoolError) {
        guard PairingCode.isValidAddress(address), port > 0 else {
            throw .invalidRequest(reason: "the report names no usable address and port of the host's listener")
        }
        guard slots >= 0, leases >= 0, queued >= 0, (0 ... slots).contains(available) else {
            throw .invalidRequest(reason: "the report's counts of slots and leases do not fit together")
        }
        guard sources.count <= Self.maximumSources, Set(sources).count == sources.count else {
            throw .invalidRequest(reason: "a report names at most \(Self.maximumSources) sources, each once")
        }
        guard sources.allSatisfy(Self.isValidSourceName) else {
            throw .invalidRequest(reason: "a source name in the report is not valid")
        }
    }

    /// Reports whether a name can name an offered source.
    ///
    /// - Parameter name: The name.
    /// - Returns: Whether the name is a valid name for a Mac and has no slash.
    public static func isValidSourceName(_ name: String) -> Bool {
        PairedMac.isValidName(name) && !name.utf8.contains(UInt8(ascii: "/"))
    }
}

/// A host that reports to the coordinator, as clients of the coordinator see it.
public struct HostSummary: Codable, Sendable, Equatable {
    /// The name that the host gave for itself when it paired with the coordinator.
    ///
    /// Names are not unique. Show the key's ``KeyFingerprint/shortKey`` next to it.
    public var name: String

    /// The fingerprint of the host's key.
    public var key: KeyFingerprint

    /// The host's last report.
    public var report: HostReport

    /// The seconds since the coordinator received the report.
    public var reportAge: Int

    /// Creates a summary.
    ///
    /// - Parameters:
    ///   - name: The host's name.
    ///   - key: The fingerprint of the host's key.
    ///   - report: The host's last report.
    ///   - reportAge: The seconds since the coordinator received the report.
    public init(name: String, key: KeyFingerprint, report: HostReport, reportAge: Int) {
        self.name = name
        self.key = key
        self.report = report
        self.reportAge = reportAge
    }

    /// The JSON keys of the summary.
    private enum CodingKeys: String, CodingKey {
        /// The `name` key.
        case name
        /// The `key` key.
        case key
        /// The `report` key.
        case report
        /// The `report_age` key.
        case reportAge = "report_age"
    }
}

/// A lease that a coordinator places on a host.
///
/// The host keeps the grant for 60 seconds. While it keeps the grant, the client that the grant
/// names may connect to the host and request one lease of the source. The host admits the client
/// without a record in its list of paired clients, because the host trusts its coordinator.
public struct HostGrant: Codable, Sendable, Equatable {
    /// The number by which the coordinator matches the host's answer to the grant.
    public var ticket: UInt64

    /// The fingerprint of the client's key.
    public var client: KeyFingerprint

    /// The client's name in the coordinator's list of paired clients.
    public var name: String

    /// The name of the offered source that the client leases.
    public var source: String

    /// The highest priority that the client may ask for in its request to the host.
    public var priority: Int

    /// Creates a grant.
    ///
    /// - Parameters:
    ///   - ticket: The number that matches the host's answer.
    ///   - client: The fingerprint of the client's key.
    ///   - name: The client's name.
    ///   - source: The name of the offered source.
    ///   - priority: The highest priority that the client may ask for.
    public init(ticket: UInt64, client: KeyFingerprint, name: String, source: String, priority: Int) {
        self.ticket = ticket
        self.client = client
        self.name = name
        self.source = source
        self.priority = priority
    }
}
