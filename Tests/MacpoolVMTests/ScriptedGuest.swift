import Foundation
@testable import MacpoolVM
import Synchronization

/// A guest that answers commands with scripted replies and records every call.
final class ScriptedGuest: GuestCommandRunner {
    /// A scripted answer to one command.
    enum Reply: Sendable {
        /// The command finishes with this result.
        case result(GuestCommandResult)
        /// The command runs until its task is cancelled.
        case hang
        /// The runner throws this error.
        case failure(MacpoolError)
        /// The command finishes with the result that the closure builds from the call.
        case respond(@Sendable (Call) -> GuestCommandResult)

        /// A successful command that printed the given output.
        ///
        /// - Parameter output: The command's standard output.
        /// - Returns: The reply.
        static func success(_ output: String) -> Reply {
            .result(GuestCommandResult(status: .exited(0), output: output, errorOutput: ""))
        }
    }

    /// One recorded command.
    struct Call: Sendable {
        /// The command line.
        let command: String
        /// The command's standard input.
        let input: String
        /// The login's user name.
        let username: String
        /// The account file whose password the login used.
        let accountFile: URL
        /// The contents of the `known_hosts` file at the time of the call.
        let knownHosts: String
        /// Whether the login trusted an unpinned key.
        let trustsFirstKey: Bool
        /// The call's time limit, or `nil` for none.
        let timeLimit: Duration?
    }

    /// The guest's mutable record.
    private struct Record {
        /// The replies that the next calls receive, in order.
        var replies: [Reply]
        /// The calls so far.
        var calls: [Call] = []
        /// The number of calls that ended by cancellation.
        var cancelledCalls = 0
    }

    /// The directory for the `known_hosts` files.
    let directory: URL

    /// The replies and the calls.
    private let record: Mutex<Record>

    /// Creates a guest with its replies.
    ///
    /// - Parameters:
    ///   - directory: The test's directory, which receives a subdirectory for `known_hosts` files.
    ///   - replies: The replies, one per expected call.
    /// - Throws: An error when the subdirectory cannot be created.
    init(directory: TemporaryDirectory, replies: [Reply]) throws {
        self.directory = directory.url.appending(path: "guest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false)
        record = Mutex(Record(replies: replies))
    }

    /// The calls so far.
    var calls: [Call] {
        record.withLock { $0.calls }
    }

    /// The number of calls that ended by cancellation.
    var cancelledCalls: Int {
        record.withLock { $0.cancelledCalls }
    }

    /// Whether ``removeDirectory()`` removed the guest's directory.
    var isDirectoryRemoved: Bool {
        !FileManager.default.fileExists(atPath: directory.filePath)
    }

    /// Writes a `known_hosts` file as ``GuestShell`` does.
    ///
    /// - Parameters:
    ///   - keys: The keys to accept.
    ///   - name: The file's name.
    /// - Returns: The file.
    /// - Throws: ``MacpoolError`` when the file cannot be written.
    func writeKnownHosts(_ keys: [HostKey], named name: String) throws(MacpoolError) -> URL {
        let file = directory.appending(path: name)
        let text = keys.map { $0.knownHostsLine(alias: VMBundle.hostKeyAlias) + "\n" }.joined()
        try FileSystem.replacePrivateFile(at: file, contents: Data(text.utf8), for: "writing known hosts")
        return file
    }

    /// Records a command and answers with the next reply.
    ///
    /// - Parameters:
    ///   - command: The command line.
    ///   - input: The command's standard input.
    ///   - username: The login's user name.
    ///   - accountFile: The account file.
    ///   - knownHosts: The `known_hosts` file.
    ///   - trustsFirstKey: Whether the login trusts an unpinned key.
    ///   - timeLimit: The call's time limit. The guest records it and does not enforce it.
    /// - Returns: The scripted result.
    /// - Throws: ``MacpoolError/credentialRotation(step:reason:)`` when no reply is left.
    func run(
        _ command: String,
        input: String,
        username: String,
        accountFile: URL,
        knownHosts: URL,
        trustsFirstKey: Bool,
        timeLimit: Duration?,
    ) async throws(MacpoolError) -> GuestCommandResult {
        let pins = (try? String(contentsOf: knownHosts, encoding: .utf8)) ?? ""
        let call = Call(
            command: command,
            input: input,
            username: username,
            accountFile: accountFile,
            knownHosts: pins,
            trustsFirstKey: trustsFirstKey,
            timeLimit: timeLimit,
        )
        let reply = record.withLock { record -> Reply? in
            record.calls.append(call)
            return record.replies.isEmpty ? nil : record.replies.removeFirst()
        }
        switch reply {
        case let .result(result):
            return result
        case .hang:
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            record.withLock { $0.cancelledCalls += 1 }
            return GuestCommandResult(status: .signaled(15), output: "", errorOutput: "")
        case let .failure(error):
            throw error
        case let .respond(build):
            return build(call)
        case nil:
            throw .credentialRotation(step: "test", reason: "no scripted reply left")
        }
    }

    /// Removes the directory of the `known_hosts` files.
    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}
