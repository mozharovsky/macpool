import Foundation

/// Reads and writes the pool's durable state.
///
/// The state is one small JSON file that only the daemon writes, under the daemon's lock. Each
/// write goes to a temporary file that reaches the disk before it replaces the old one by rename,
/// so a crash or a power loss leaves either the old state or the new one.
struct PoolStore {
    /// The part of the state file that every format version shares.
    private struct Header: Decodable {
        /// The format version.
        let version: Int
    }

    /// A state file in version 1, whose leases have no owner.
    private struct UnownedState: Decodable {
        /// The stored leases.
        let leases: [UnownedLease]
    }

    /// A version 1 lease, which belongs to the local user.
    private struct UnownedLease: Decodable {
        /// The lease with the local user as its owner.
        let record: LeaseRecord

        /// Decodes a lease without an owner.
        ///
        /// - Parameter decoder: The decoder to read from.
        /// - Throws: `DecodingError` when a field is missing or malformed.
        init(from decoder: any Decoder) throws {
            record = try LeaseRecord(from: decoder, defaultOwner: .local)
        }
    }

    /// The state file.
    let file: URL

    /// Reads the stored state.
    ///
    /// The call reads the format version before the rest, so a file in another build's format
    /// never counts as malformed. A version 1 file loads with the local user as the owner of
    /// every lease. The daemon saves the state as soon as it starts, so its first start rewrites
    /// the file in the current version.
    ///
    /// - Returns: The state in the current version, or an empty state when the file does not
    ///   exist.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the file exists and cannot
    ///   be read, ``PoolError/unsupportedStateVersion(path:version:)`` when it has another format
    ///   version, or ``PoolError/invalidState(path:reason:)`` when it is malformed or lists a lease
    ///   more than once.
    func load() throws(PoolError) -> PoolState {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return .empty
        } catch {
            throw .fileSystem("reading the pool state", file, error)
        }
        let header = try decode(Header.self, from: data)
        let state: PoolState
        switch header.version {
        case PoolState.currentVersion:
            state = try decode(PoolState.self, from: data)
        case PoolState.unownedVersion:
            let earlier = try decode(UnownedState.self, from: data)
            state = PoolState(version: PoolState.currentVersion, leases: earlier.leases.map(\.record))
        default:
            throw .unsupportedStateVersion(path: file.path(percentEncoded: false), version: header.version)
        }
        // The daemon writes each lease once, so a repeated lease means the file was damaged.
        var seen: Set<LeaseID> = []
        for lease in state.leases where !seen.insert(lease.id).inserted {
            throw .invalidState(
                path: file.path(percentEncoded: false),
                reason: "it lists lease \(lease.id) more than once",
            )
        }
        return state
    }

    /// Decodes the state file's contents.
    ///
    /// - Parameters:
    ///   - type: The type to decode.
    ///   - data: The file's contents.
    /// - Returns: The decoded value.
    /// - Throws: ``PoolError/invalidState(path:reason:)`` when the contents do not match the type.
    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws(PoolError) -> Value {
        do {
            return try MessageCoding.decoder.decode(type, from: data)
        } catch {
            throw .invalidState(path: file.path(percentEncoded: false), reason: "\(error)")
        }
    }

    /// Replaces the stored state.
    ///
    /// - Parameter state: The state to store.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the file cannot be written.
    func save(_ state: PoolState) throws(PoolError) {
        let encoder = MessageCoding.encoder
        encoder.outputFormatting.insert(.prettyPrinted)
        let temporary = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).new")
        do {
            let data = try encoder.encode(state) + Data("\n".utf8)
            guard FileManager.default.createFile(
                atPath: temporary.path(percentEncoded: false),
                contents: nil,
                attributes: [.posixPermissions: 0o600],
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            // Without the flush a power loss can leave the renamed file empty.
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw .fileSystem("writing the pool state", temporary, error)
        }
        guard rename(temporary.path(percentEncoded: false), file.path(percentEncoded: false)) == 0 else {
            let failure = PoolError.systemCall("replacing the pool state with", temporary)
            try? FileManager.default.removeItem(at: temporary)
            throw failure
        }
    }

    /// Moves an unreadable state file aside so that the daemon can start without it.
    ///
    /// - Parameter date: The time that names the moved file.
    /// - Returns: The moved file, which is the state file's name with `.invalid-` and the time in
    ///   seconds since 1970.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the file cannot be moved.
    func quarantine(at date: Date) throws(PoolError) -> URL {
        let seconds = Int(date.timeIntervalSince1970)
        let destination = file.deletingLastPathComponent()
            .appending(path: "\(file.lastPathComponent).invalid-\(seconds)")
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            throw .fileSystem("moving the unusable pool state aside", file, error)
        }
        return destination
    }
}
