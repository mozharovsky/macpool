import Foundation

/// A paired Mac in a ``TrustList``.
protocol TrustRecord: Codable, Sendable, Equatable {
    /// The name of the list's file in the trust directory.
    static var fileName: String { get }

    /// What the list holds, for error messages, such as `the list of paired clients`.
    static var listName: String { get }

    /// The fingerprint of the paired Mac's key.
    var key: KeyFingerprint { get }
}

/// A Mac that may lease VMs from this host.
struct TrustedClient: TrustRecord {
    /// The file of the host's list.
    static let fileName = "clients.json"

    /// The list's description in error messages.
    static let listName = "the list of paired clients"

    /// The fingerprint of the client's key.
    var key: KeyFingerprint

    /// The name that the client gave for itself when it paired.
    var name: String

    /// When the client paired.
    var pairedAt: Date

    /// Whether the host refuses the client.
    ///
    /// A blocked client opens no new connection. The record stays, so a person sees which key
    /// the host refuses.
    var isBlocked: Bool

    /// The JSON keys of a record.
    private enum CodingKeys: String, CodingKey {
        /// The key's fingerprint.
        case key
        /// The client's name.
        case name
        /// The time of the pairing.
        case pairedAt = "paired_at"
        /// Whether the host refuses the client.
        case isBlocked = "blocked"
    }
}

/// A host that this Mac may lease VMs from.
struct TrustedHost: TrustRecord {
    /// The file of the client's list.
    static let fileName = "hosts.json"

    /// The list's description in error messages.
    static let listName = "the list of paired hosts"

    /// The fingerprint of the host's key.
    var key: KeyFingerprint

    /// The name by which this Mac's commands refer to the host.
    var name: String

    /// The host's address, such as `studio.local`.
    var address: String

    /// The host's TCP port.
    var port: UInt16

    /// When this Mac paired with the host.
    var pairedAt: Date

    /// The JSON keys of a record.
    private enum CodingKeys: String, CodingKey {
        /// The key's fingerprint.
        case key
        /// The host's name.
        case name
        /// The host's address.
        case address
        /// The host's port.
        case port
        /// The time of the pairing.
        case pairedAt = "paired_at"
    }
}

/// A list of paired Macs in a file of the trust directory.
///
/// The host keeps its clients in `clients.json`, and a client keeps its hosts in `hosts.json`.
/// Each file holds JSON with a format version and the records, such as
/// `{"macs":[…],"version":1}`. The list holds at most one record per key.
///
/// Only the current user may read the file, and its directory gets the checks of
/// ``PoolDirectory/checkTrustDirectory()``. A save replaces the whole file, so a reader sees the
/// old list or the new one.
struct TrustList<Record: TrustRecord>: Sendable, Equatable {
    /// The format version that this build reads and writes.
    static var formatVersion: Int {
        1
    }

    /// The paired Macs in the order they were added.
    private(set) var records: [Record] = []

    /// Creates an empty list.
    init() {}

    /// Returns the record of a key.
    ///
    /// - Parameter key: The fingerprint of a paired Mac's key.
    /// - Returns: The record, or `nil` when the list has no record of the key.
    subscript(key: KeyFingerprint) -> Record? {
        records.first { $0.key == key }
    }

    /// Adds a record, or replaces the record with the same key.
    ///
    /// - Parameter record: The record to store. If the list has a record with the same key, the
    ///   new record takes its place in the order.
    mutating func insert(_ record: Record) {
        if let index = records.firstIndex(where: { $0.key == record.key }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    /// Returns the list's file.
    ///
    /// - Parameter directory: The data directory.
    /// - Returns: The file in the trust directory.
    static func file(in directory: PoolDirectory) -> URL {
        directory.trustDirectory.appending(path: Record.fileName)
    }

    /// Reports whether the list's file exists.
    ///
    /// - Parameter directory: The data directory.
    /// - Returns: `false` only when nothing exists at the file's path. A path that cannot be
    ///   inspected counts as existing.
    static func exists(in directory: PoolDirectory) -> Bool {
        var status = stat()
        return lstat(file(in: directory).path(percentEncoded: false), &status) == 0 || errno != ENOENT
    }

    /// Reads the list.
    ///
    /// - Parameter directory: The data directory.
    /// - Returns: The list. If its file does not exist, the list is empty.
    /// - Throws: ``PoolError/insecureDirectory(path:reason:)`` when the trust directory fails the
    ///   checks of ``PoolDirectory/checkTrustDirectory()``,
    ///   ``PoolError/unusableTrustList(path:reason:)`` when the file fails a check of
    ///   ``PrivateFile/read(at:name:refusal:)``, holds no list, has another format version, or
    ///   lists a key twice, or ``PoolError/fileSystem(operation:path:reason:)`` when it cannot
    ///   be read.
    static func load(from directory: PoolDirectory) throws(PoolError) -> TrustList {
        guard exists(in: directory) else {
            return TrustList()
        }
        try directory.checkTrustDirectory()
        let file = file(in: directory)
        let path = file.path(percentEncoded: false)
        let refusal = { (reason: String) in PoolError.unusableTrustList(path: path, reason: reason) }
        guard let data = try PrivateFile.read(at: file, name: Record.listName, refusal: refusal) else {
            return TrustList()
        }
        let header: StoredHeader
        do {
            header = try MessageCoding.decoder.decode(StoredHeader.self, from: data)
        } catch {
            throw refusal("it holds no list with a format version: \(error)")
        }
        guard header.version == formatVersion else {
            throw refusal("it has format version \(header.version), and this build reads only version \(formatVersion)")
        }
        let stored: StoredList
        do {
            stored = try MessageCoding.decoder.decode(StoredList.self, from: data)
        } catch {
            throw refusal("\(error)")
        }
        var list = TrustList()
        for record in stored.macs {
            guard list[record.key] == nil else {
                throw refusal("it lists the key \(record.key) twice")
            }
            list.records.append(record)
        }
        return list
    }

    /// Replaces the list's file with this list.
    ///
    /// - Parameter directory: The data directory.
    /// - Throws: The errors of ``PoolDirectory/prepareTrustDirectory()``, or
    ///   ``PoolError/fileSystem(operation:path:reason:)`` when the list cannot be encoded or the
    ///   file cannot be replaced.
    func save(to directory: PoolDirectory) throws(PoolError) {
        try directory.prepareTrustDirectory()
        let file = Self.file(in: directory)
        let encoder = MessageCoding.encoder
        encoder.outputFormatting.insert(.prettyPrinted)
        let data: Data
        do {
            data = try encoder.encode(StoredList(version: Self.formatVersion, macs: records)) + Data("\n".utf8)
        } catch {
            throw .fileSystem("encoding \(Record.listName) for", file, error)
        }
        try PrivateFile.replace(at: file, contents: data, name: Record.listName)
    }

    /// The format version of a stored list, read before the records.
    private struct StoredHeader: Decodable {
        /// The format version.
        var version: Int
    }

    /// The contents of a list's file.
    private struct StoredList: Codable {
        /// The format version.
        var version: Int

        /// The records in the order of the file.
        var macs: [Record]
    }
}

/// The keys that the host admits.
extension TrustList where Record == TrustedClient {
    /// The keys of the clients that are not blocked.
    var admittedKeys: Set<KeyFingerprint> {
        Set(records.filter { !$0.isBlocked }.map(\.key))
    }
}
