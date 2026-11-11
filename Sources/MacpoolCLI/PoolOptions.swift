import ArgumentParser
import Foundation
import MacpoolPool
import Synchronization

/// The option that selects the daemon's data directory.
struct PoolOptions: ParsableArguments {
    /// The data directory, or `nil` for the default.
    @Option(
        name: .customLong("data-dir"),
        help: """
        The daemon's data directory. It must be on the same volume as the source bundles. \
        The default is ~/Library/Application Support/macpool.
        """,
    )
    var dataDirectory: String?

    /// The selected data directory.
    var directory: PoolDirectory {
        dataDirectory.map { PoolDirectory(root: URL(filePath: $0)) } ?? .standard
    }
}

/// The location of the running `macpool` executable.
enum Executable {
    /// Resolves the running executable with its symbolic links.
    ///
    /// The daemon starts supervisors from this file, and the launchd job runs it, so both need the
    /// file itself rather than a link that a later build may move.
    ///
    /// - Returns: The executable's resolved location.
    /// - Throws: ``CommandError/invalidValue(_:)`` when the process cannot locate its executable.
    static func current() throws(CommandError) -> URL {
        guard let url = Bundle.main.executableURL else {
            throw .invalidValue("the running executable cannot be located")
        }
        return url.resolvingSymlinksInPath()
    }
}

/// A flag that any thread can set once and read.
final class StopFlag: Sendable {
    /// Whether the flag is set.
    private let state = Mutex(false)

    /// Sets the flag.
    func set() {
        state.withLock { $0 = true }
    }

    /// Whether the flag is set.
    var isSet: Bool {
        state.withLock { $0 }
    }
}

/// Termination signals delivered as values instead of ending the process.
///
/// While a watch exists, its signals are ignored by default and reach the handler instead.
/// Cancelling the watch restores the default actions.
final class SignalWatch: Sendable {
    /// The dispatch sources that receive the signals.
    private let sources: [any DispatchSourceSignal]

    /// The signals that this watch handles.
    private let numbers: [Int32]

    /// The signals that a watch handles unless its creator names others.
    static let signals = [SIGINT, SIGTERM]

    /// Starts watching signals.
    ///
    /// - Parameters:
    ///   - signals: The signals to handle.
    ///   - handler: The handler. It receives the signal number on a background queue.
    init(signals: [Int32] = SignalWatch.signals, handler: @escaping @Sendable (Int32) -> Void) {
        numbers = signals
        sources = signals.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { handler(number) }
            source.resume()
            return source
        }
    }

    /// Stops watching and restores the default signal actions.
    func cancel() {
        for source in sources {
            source.cancel()
        }
        for number in numbers {
            signal(number, SIG_DFL)
        }
    }
}
