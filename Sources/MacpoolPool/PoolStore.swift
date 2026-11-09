import Foundation

/// Reads and writes the pool's durable state.
///
/// The state is one small JSON file that only the daemon writes, under the daemon's lock. Each
/// write goes to a temporary file that reaches the disk before it replaces the old one by rename,
/// so a crash or a power loss leaves either the old state or the new one.
struct PoolStore {
    /// The state file.
    let file: URL

    /// Reads the stored state.
    ///
    /// - Returns: The state, or an empty state when the file does not exist.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the file exists and cannot
    ///   be read, or ``PoolError/invalidState(path:reason:)`` when it is malformed or has another
    ///   format version.
    func load() throws(PoolError) -> PoolState {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return .empty
        } catch {
            throw .fileSystem("reading the pool state", file, error)
        }
        let state: PoolState
        do {
            state = try MessageCoding.decoder.decode(PoolState.self, from: data)
        } catch {
            throw .invalidState(path: file.path(percentEncoded: false), reason: "\(error)")
        }
        guard state.version == PoolState.currentVersion else {
            throw .invalidState(
                path: file.path(percentEncoded: false),
                reason: "format version \(state.version) instead of \(PoolState.currentVersion)",
            )
        }
        return state
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
