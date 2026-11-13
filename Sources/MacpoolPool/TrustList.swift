public import Foundation

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
///
/// The host keeps these records in `clients.json` in the trust directory.
///
/// The client chose its name. The pool checks names only when Macs pair, and a list that someone
/// edited may hold any text. Escape the name before a terminal shows it.
public struct TrustedClient: TrustRecord {
    /// The file of the host's list.
    static let fileName = "clients.json"

    /// The list's description in error messages.
    static let listName = "the list of paired clients"

    /// The fingerprint of the client's key.
    public var key: KeyFingerprint

    /// The name that the client gave for itself when it paired.
    ///
    /// Names are not unique. Show the key's ``KeyFingerprint/shortKey`` next to it.
    public var name: String

    /// When the client paired.
    public var pairedAt: Date

    /// Whether the host refuses the client.
    ///
    /// A blocked client opens no new connection, and its open connections close at their next
    /// request. The record stays. A person then sees which key the host refuses.
    public var isBlocked: Bool

    /// The highest priority that the client may ask for, 0 or more.
    ///
    /// The field only widens what a client may do. A build that does not know the field reads the
    /// record with a ceiling of 0. The field therefore needs no new format version of the list.
    public var priorityCeiling = 0

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
        /// The highest priority that the client may ask for.
        case priorityCeiling = "priority_ceiling"
    }
}

/// The decoding of a client record. It also reads records from before priority ceilings.
public extension TrustedClient {
    /// Decodes a record. A record without a ceiling gets a ceiling of 0.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when a field is missing or malformed, or when the ceiling is
    ///   below 0.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let priorityCeiling = try container.decodeIfPresent(Int.self, forKey: .priorityCeiling) ?? 0
        // A build that does not know the field would read a negative ceiling as 0 and widen what
        // the client may do.
        guard priorityCeiling >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .priorityCeiling,
                in: container,
                debugDescription: "The priority ceiling \(priorityCeiling) is below 0.",
            )
        }
        try self.init(
            key: container.decode(KeyFingerprint.self, forKey: .key),
            name: container.decode(String.self, forKey: .name),
            pairedAt: container.decode(Date.self, forKey: .pairedAt),
            isBlocked: container.decode(Bool.self, forKey: .isBlocked),
            priorityCeiling: priorityCeiling,
        )
    }
}

/// A host that this Mac may lease VMs from.
///
/// A client keeps these records in `hosts.json` in the trust directory.
///
/// The host chose its name and the address in the pairing code. Escape both before a terminal
/// shows them.
public struct TrustedHost: TrustRecord {
    /// The file of the client's list.
    static let fileName = "hosts.json"

    /// The list's description in error messages.
    static let listName = "the list of paired hosts"

    /// The fingerprint of the host's key.
    public var key: KeyFingerprint

    /// The name by which this Mac's commands refer to the host.
    ///
    /// Names are not unique. Show the key's ``KeyFingerprint/shortKey`` next to it.
    public var name: String

    /// The host's address, such as `example.local`.
    public var address: String

    /// The host's TCP port.
    public var port: UInt16

    /// When this Mac paired with the host.
    public var pairedAt: Date

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
///
/// A new field that restricts a paired Mac raises ``formatVersion``. A build that reads the old
/// version skips unknown fields and would admit the Mac without the restriction.
struct TrustList<Record: TrustRecord>: Sendable, Equatable {
    /// The format version that this build reads and writes.
    static var formatVersion: Int {
        1
    }

    /// The most bytes that a list's file may have.
    ///
    /// The host reads the list of paired clients during every handshake. The limit bounds the
    /// work that one connection causes.
    static var byteLimit: Int {
        256 * 1024
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

    /// Removes the record of a key, if the list has one.
    ///
    /// - Parameter key: The fingerprint of a paired Mac's key.
    mutating func remove(_ key: KeyFingerprint) {
        records.removeAll { $0.key == key }
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
    ///   ``PrivateFile/read(at:name:limit:refusal:)``, holds no list, has another format version, or
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
        guard let data = try PrivateFile.read(at: file, name: Record.listName, limit: byteLimit, refusal: refusal)
        else {
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
    /// - Throws: ``PoolError/unusableTrustList(path:reason:)`` when the encoded list has more
    ///   than ``byteLimit`` bytes, the errors of ``PoolDirectory/prepareTrustDirectory()``, or
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
        guard data.count <= Self.byteLimit else {
            throw .unusableTrustList(
                path: file.path(percentEncoded: false),
                reason: "it would have \(data.count) bytes, and the pool reads at most \(Self.byteLimit)",
            )
        }
        try PrivateFile.replace(at: file, contents: data, name: Record.listName)
    }

    /// Reports whether the list holds a record as a save of that record would store it.
    ///
    /// A save keeps dates in whole seconds. The comparison therefore encodes and decodes `record`
    /// as a save and a load do.
    ///
    /// - Parameter record: The record to look for.
    /// - Returns: `true` when the list's record of the same key equals the stored form of `record`.
    ///   `false` when the records differ, when the list has no record of the key, or when
    ///   `record` cannot be encoded.
    func holds(_ record: Record) -> Bool {
        guard let data = try? MessageCoding.encoder.encode(record),
              let stored = try? MessageCoding.decoder.decode(Record.self, from: data)
        else {
            return false
        }
        return self[record.key] == stored
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

    /// Marks a client as blocked and keeps the other fields of its record.
    ///
    /// - Parameter key: The client's fingerprint. If the list has no record of it, the call does
    ///   nothing.
    mutating func block(_ key: KeyFingerprint) {
        if let index = records.firstIndex(where: { $0.key == key }) {
            records[index].isBlocked = true
        }
    }
}

/// The public reading of the host's list.
public extension TrustedClient {
    /// Reads the clients that this host paired with, in the order they were added.
    ///
    /// The call neither creates nor changes a file, and it needs no running daemon.
    ///
    /// - Parameter directory: The data directory.
    /// - Returns: The records. If `clients.json` does not exist, the array is empty.
    /// - Throws: ``PoolError/insecureDirectory(path:reason:)`` when other users can change the data
    ///   directory or reach the trust directory, ``PoolError/unusableTrustList(path:reason:)``
    ///   when the file is open to other users, too large, or holds no list that this build reads,
    ///   or ``PoolError/fileSystem(operation:path:reason:)`` when it cannot be read.
    static func paired(in directory: PoolDirectory) throws(PoolError) -> [TrustedClient] {
        try TrustList<Self>.load(from: directory).records
    }
}

/// The public reading of the client's list.
public extension TrustedHost {
    /// Reads the hosts that this Mac paired with, in the order they were added.
    ///
    /// The call neither creates nor changes a file, and it needs no running daemon.
    ///
    /// - Parameter directory: The data directory.
    /// - Returns: The records. If `hosts.json` does not exist, the array is empty.
    /// - Throws: ``PoolError/insecureDirectory(path:reason:)`` when other users can change the data
    ///   directory or reach the trust directory, ``PoolError/unusableTrustList(path:reason:)``
    ///   when the file is open to other users, too large, or holds no list that this build reads,
    ///   or ``PoolError/fileSystem(operation:path:reason:)`` when it cannot be read.
    static func paired(in directory: PoolDirectory) throws(PoolError) -> [TrustedHost] {
        try TrustList<Self>.load(from: directory).records
    }
}
