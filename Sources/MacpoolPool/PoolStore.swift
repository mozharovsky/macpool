import Foundation

/// Reads and writes the pool's durable state.
///
/// The state is one small JSON file that only the daemon writes, under the daemon's lock. Each
/// write goes to a temporary file that replaces the old one by rename, so a crash leaves either
/// the old state or the new one.
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
        do {
            try (encoder.encode(state) + Data("\n".utf8)).write(to: file, options: .atomic)
        } catch {
            throw .fileSystem("writing the pool state", file, error)
        }
    }
}
