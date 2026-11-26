/// The hosts that report to this daemon as their coordinator.
///
/// The registry holds each host's last report while the host's connection stays open. A host
/// has at most one entry, and a report on a newer connection moves the entry to that connection.
/// The registry keeps no state on disk. After a restart of the coordinator, the hosts connect
/// again and report within one interval.
struct HostRegistry {
    /// A host and its last report.
    struct Entry: Equatable {
        /// The fingerprint of the host's key.
        let key: KeyFingerprint

        /// The host's name in the coordinator's list of paired clients.
        var name: String

        /// The connection on which the host reports.
        var client: ClientID

        /// The host's last report.
        var report: HostReport

        /// When the coordinator received the report, on a clock that stops while it sleeps.
        var receivedAt: SuspendingClock.Instant
    }

    /// The hosts by the fingerprints of their keys.
    private(set) var entries: [KeyFingerprint: Entry] = [:]

    /// Records a host's report.
    ///
    /// - Parameters:
    ///   - report: The report, which the caller already validated.
    ///   - key: The fingerprint of the host's key.
    ///   - name: The host's name in the list of paired clients.
    ///   - client: The connection that carried the report.
    ///   - awake: The current time on a clock that stops while this Mac sleeps.
    /// - Returns: Whether the host had no entry before.
    @discardableResult
    mutating func record(
        _ report: HostReport,
        from key: KeyFingerprint,
        name: String,
        client: ClientID,
        at awake: SuspendingClock.Instant,
    ) -> Bool {
        let isNew = entries[key] == nil
        entries[key] = Entry(key: key, name: name, client: client, report: report, receivedAt: awake)
        return isNew
    }

    /// Removes the host that reports on a connection.
    ///
    /// - Parameter client: A connection that ended.
    /// - Returns: The removed entry, or `nil` when no host reports on the connection.
    @discardableResult
    mutating func remove(client: ClientID) -> Entry? {
        guard let entry = entries.values.first(where: { $0.client == client }) else {
            return nil
        }
        entries[entry.key] = nil
        return entry
    }

    /// Describes the hosts for clients.
    ///
    /// - Parameter awake: The current time on the clock of ``Entry/receivedAt``.
    /// - Returns: The hosts ordered by name and then by key.
    func summaries(at awake: SuspendingClock.Instant) -> [HostSummary] {
        entries.values
            .sorted { ($0.name, $0.key.rawValue) < ($1.name, $1.key.rawValue) }
            .map { entry in
                HostSummary(
                    name: entry.name,
                    key: entry.key,
                    report: entry.report,
                    reportAge: Int(entry.receivedAt.duration(to: awake) / .seconds(1)),
                )
            }
    }
}
