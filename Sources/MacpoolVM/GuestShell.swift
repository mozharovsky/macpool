import Foundation
import Subprocess
import System

/// How the `ssh` process of a guest command ended.
public enum GuestCommandStatus: Sendable, Hashable, CustomStringConvertible {
    /// `ssh` exited with this code.
    ///
    /// The code is the remote command's exit code. If `ssh` fails itself, or if a signal ends the
    /// remote command, the code is 255.
    case exited(Int32)

    /// A signal with this number ended the local `ssh`. For example, 9 is `SIGKILL`.
    case signaled(Int32)

    /// The status in the form `exited(3)` or `signaled(9)`.
    public var description: String {
        switch self {
        case let .exited(code):
            "exited(\(code))"
        case let .signaled(signal):
            "signaled(\(signal))"
        }
    }
}

/// The result of one command in a guest.
///
/// Each output keeps at most the last 64 KiB that the command wrote. The command still runs to its
/// end when it writes more, and the result keeps its exit status.
public struct GuestCommandResult: Sendable, Equatable {
    /// How `ssh` ended.
    public let status: GuestCommandStatus

    /// The end of the remote command's standard output.
    public let output: String

    /// The end of the standard error of `ssh` and the remote command.
    public let errorOutput: String

    /// Whether ``output`` lost its beginning to the 64 KiB limit.
    public let isOutputTruncated: Bool

    /// Whether ``errorOutput`` lost its beginning to the 64 KiB limit.
    public let isErrorOutputTruncated: Bool

    /// Whether `ssh` and the remote command exited with code zero.
    public var succeeded: Bool {
        status == .exited(0)
    }

    /// The exit status and the last 400 characters of the error output.
    public var failureSummary: String {
        let trimmed = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "ssh \(status) without output" : "ssh \(status): \(trimmed.suffix(400))"
    }

    /// Creates a result from its parts.
    ///
    /// - Parameters:
    ///   - status: How `ssh` ended.
    ///   - output: The end of the standard output.
    ///   - errorOutput: The end of the standard error.
    ///   - isOutputTruncated: Whether the standard output lost its beginning.
    ///   - isErrorOutputTruncated: Whether the standard error lost its beginning.
    init(
        status: GuestCommandStatus,
        output: String,
        errorOutput: String,
        isOutputTruncated: Bool = false,
        isErrorOutputTruncated: Bool = false,
    ) {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
        self.isOutputTruncated = isOutputTruncated
        self.isErrorOutputTruncated = isErrorOutputTruncated
    }
}

/// A way to run commands in a guest that logs in with a stored account's password.
///
/// ``GuestShell`` runs `ssh`, and tests replace it with a scripted runner.
protocol GuestCommandRunner: Sendable {
    /// Writes a `known_hosts` file that pins keys under ``VMBundle/hostKeyAlias``.
    ///
    /// - Parameters:
    ///   - keys: The keys to accept. An empty list makes the file empty.
    ///   - name: The file's name inside the runner's private directory.
    /// - Returns: The file.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the file cannot be
    ///   written.
    func writeKnownHosts(_ keys: [HostKey], named name: String) throws(MacpoolError) -> URL

    /// Runs a command in the guest.
    ///
    /// Cancelling the calling task or reaching the time limit ends the connection. The command in
    /// the guest keeps running until it ends or until it writes to its standard output or standard
    /// error. That write ends it. The guest's state after either event is unknown.
    ///
    /// - Parameters:
    ///   - command: The command line that the account's login shell runs.
    ///   - input: The command's standard input, which keeps secrets out of process listings.
    ///   - username: The account's short user name, which must need no shell quoting.
    ///   - accountFile: The account file whose password the login sends.
    ///   - knownHosts: The `known_hosts` file from ``writeKnownHosts(_:named:)``.
    ///   - trustsFirstKey: Whether an empty `known_hosts` file accepts the key the guest presents.
    ///     A key that differs from a pinned one fails the connection either way.
    ///   - timeLimit: The longest time the call may take, including the login, or `nil` for no
    ///     limit.
    /// - Returns: The command's outputs and exit status.
    /// - Throws: ``MacpoolError/guestCommand(reason:)`` when the command cannot start or reading
    ///   its output fails. ``MacpoolError/guestCommandTimedOut(limit:output:errorOutput:)`` when
    ///   the time limit passes. ``MacpoolError/guestCommandCancelled`` when the calling task is
    ///   cancelled.
    func run(
        _ command: String,
        input: String,
        username: String,
        accountFile: URL,
        knownHosts: URL,
        trustsFirstKey: Bool,
        timeLimit: Duration?,
    ) async throws(MacpoolError) -> GuestCommandResult

    /// Removes the runner's private directory and the `known_hosts` files in it.
    func removeDirectory()
}

/// An SSH client for one guest that logs in with the password of a stored account file.
///
/// The client ignores the user's SSH configuration and agent, so no identity leaves the host. It
/// gives `ssh` the password through an askpass script in a private temporary directory. The script
/// reads the account file that a call names, so the directory itself never holds a password.
///
/// Every connection looks the host key up under ``VMBundle/hostKeyAlias`` in a `known_hosts` file
/// that the caller writes with ``writeKnownHosts(_:named:)``, and accepts only Ed25519 keys. Call
/// ``removeDirectory()`` when the client is no longer needed.
///
/// A process that ends by a signal leaves the directory in the temporary directory. It holds only
/// the askpass script and public keys.
struct GuestShell: GuestCommandRunner {
    /// The most bytes that a result keeps from the end of each output stream.
    static let outputLimit = 1 << 16

    /// The guest's IPv4 address.
    let address: String

    /// The private temporary directory with the askpass script and the `known_hosts` files.
    let directory: URL

    /// Creates a client and its private temporary directory.
    ///
    /// - Parameter address: The guest's IPv4 address.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the directory or the
    ///   askpass script cannot be created.
    init(address: String) throws(MacpoolError) {
        let template = FileManager.default.temporaryDirectory.appending(path: "macpool-ssh-XXXXXX").filePath
        var buffer = Array(template.utf8CString)
        guard mkdtemp(&buffer) != nil else {
            throw .systemCall("creating a directory for SSH", URL(filePath: template))
        }
        // mkdtemp creates the directory with owner-only permissions and writes its name in place.
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        self.address = address
        directory = URL(filePath: path, directoryHint: .isDirectory)
        let script = "#!/bin/sh\nexec /usr/bin/plutil -extract password raw -o - \"$MACPOOL_ACCOUNT_FILE\"\n"
        do {
            try FileSystem.createNewFile(at: askpass, contents: Data(script.utf8), permissions: 0o700)
        } catch {
            removeDirectory()
            throw error
        }
    }

    /// The askpass script, which prints the password of the file in `MACPOOL_ACCOUNT_FILE`.
    var askpass: URL {
        directory.appending(path: "askpass")
    }

    /// Writes a `known_hosts` file in the client's directory.
    ///
    /// - Parameters:
    ///   - keys: The keys to accept. An empty list makes the file empty.
    ///   - name: The file's name inside the client's directory.
    /// - Returns: The file.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the file cannot be
    ///   written.
    func writeKnownHosts(_ keys: [HostKey], named name: String) throws(MacpoolError) -> URL {
        let file = directory.appending(path: name)
        let text = keys.map { $0.knownHostsLine(alias: VMBundle.hostKeyAlias) + "\n" }.joined()
        try FileSystem.replacePrivateFile(at: file, contents: Data(text.utf8), for: "writing known hosts")
        return file
    }

    /// Runs a command in the guest through `ssh`.
    ///
    /// Cancelling the calling task or reaching the time limit terminates `ssh`. The command in the
    /// guest keeps running until it ends or until it writes to its standard output or standard
    /// error. That write ends it. The guest's state after either event is unknown.
    ///
    /// - Parameters:
    ///   - command: The command line that the account's login shell runs.
    ///   - input: The command's standard input, which keeps secrets out of process listings.
    ///   - username: The account's short user name, which must need no shell quoting.
    ///   - accountFile: The account file whose password `ssh` sends.
    ///   - knownHosts: The `known_hosts` file from ``writeKnownHosts(_:named:)``.
    ///   - trustsFirstKey: Whether an empty `known_hosts` file accepts the key the guest presents.
    ///     A key that differs from a pinned one fails the connection either way.
    ///   - timeLimit: The longest time the call may take, including the login, or `nil` for no
    ///     limit.
    /// - Returns: The command's outputs and exit status.
    /// - Throws: ``MacpoolError/guestCommand(reason:)`` when `ssh` cannot start or reading its
    ///   output fails. ``MacpoolError/guestCommandTimedOut(limit:output:errorOutput:)`` when the
    ///   time limit passes. ``MacpoolError/guestCommandCancelled`` when the calling task is
    ///   cancelled.
    func run(
        _ command: String,
        input: String,
        username: String,
        accountFile: URL,
        knownHosts: URL,
        trustsFirstKey: Bool,
        timeLimit: Duration?,
    ) async throws(MacpoolError) -> GuestCommandResult {
        try await Self.collect(
            executable: "/usr/bin/ssh",
            arguments: Self.arguments(
                command: command,
                username: username,
                address: address,
                knownHosts: knownHosts,
                trustsFirstKey: trustsFirstKey,
            ),
            environment: Environment.inherit.updating([
                "SSH_ASKPASS": askpass.filePath,
                "SSH_ASKPASS_REQUIRE": "force",
                "MACPOOL_ACCOUNT_FILE": accountFile.filePath,
            ]),
            input: input,
            timeLimit: timeLimit,
        )
    }

    /// Builds the `ssh` arguments for one command.
    ///
    /// - Parameters:
    ///   - command: The command line that the account's login shell runs.
    ///   - username: The account's short user name. It must need no shell quoting.
    ///   - address: The guest's IPv4 address.
    ///   - knownHosts: The `known_hosts` file with the keys to accept.
    ///   - trustsFirstKey: Whether an empty `known_hosts` file accepts the key the guest presents.
    /// - Returns: The arguments. The last three are `--`, the destination, and the command.
    static func arguments(
        command: String,
        username: String,
        address: String,
        knownHosts: URL,
        trustsFirstKey: Bool,
    ) -> [String] {
        [
            "-F", "/dev/null",
            "-o", "ForwardAgent=no",
            "-o", "IdentityAgent=none",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
            // ssh splits this value on spaces, so the path is quoted inside it.
            "-o", "UserKnownHostsFile=\"\(knownHosts.filePath)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlias=\(VMBundle.hostKeyAlias)",
            "-o", "HostKeyAlgorithms=\(HostKey.algorithm)",
            "-o", "StrictHostKeyChecking=\(trustsFirstKey ? "accept-new" : "yes")",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=6",
            // Without the separator, a command that starts with -o would set an ssh option.
            "--",
            "\(username)@\(address)",
            command,
        ]
    }

    /// Runs a process with input and collects the end of each output stream.
    ///
    /// The process may exit before it reads all of its input. The rest of the input is then
    /// dropped, and the result reports the exit status.
    ///
    /// When the time limit passes, the call sends `SIGKILL` to the process. The output streams end
    /// when no other process holds them open.
    ///
    /// - Parameters:
    ///   - executable: The absolute path of the program.
    ///   - arguments: The program's arguments.
    ///   - environment: The program's environment.
    ///   - input: The program's standard input.
    ///   - timeLimit: The longest time the process may run, or `nil` for no limit.
    /// - Returns: The exit status and at most the last ``outputLimit`` bytes of each stream.
    /// - Throws: ``MacpoolError/guestCommand(reason:)`` when the process cannot start or reading its
    ///   output fails. ``MacpoolError/guestCommandTimedOut(limit:output:errorOutput:)`` when the
    ///   time limit passes. ``MacpoolError/guestCommandCancelled`` when the calling task is
    ///   cancelled.
    static func collect(
        executable: String,
        arguments: [String],
        environment: Environment = .inherit,
        input: String,
        timeLimit: Duration? = nil,
    ) async throws(MacpoolError) -> GuestCommandResult {
        let pipe: (readEnd: FileDescriptor, writeEnd: FileDescriptor)
        do {
            // Both ends close on exec, so a process that the caller spawns meanwhile cannot hold
            // them open. Subprocess clears the flag on the child's standard input when it moves
            // the read end there.
            pipe = try FileDescriptor.pipe(options: .closeOnExec)
        } catch {
            throw .guestCommand(reason: "creating the input pipe failed: \(error)")
        }
        // A write after the process exits then fails with EPIPE. SIGPIPE would end this process.
        _ = fcntl(pipe.writeEnd.rawValue, F_SETNOSIGPIPE, 1)
        let writer = Task { await write(Array(input.utf8), to: pipe.writeEnd) }

        var result: GuestCommandResult?
        var failure: (any Error)?
        var isTimedOut = false
        do {
            let execution = try await Subprocess.run(
                .path(FilePath(executable)),
                arguments: Arguments(arguments),
                environment: environment,
                input: .fileDescriptor(pipe.readEnd, closeAfterSpawningProcess: false),
                output: .sequence,
                error: .sequence,
            ) { execution in
                let timer = Task { () -> Bool in
                    guard let timeLimit else {
                        return false
                    }
                    do {
                        try await Task.sleep(for: timeLimit)
                    } catch {
                        return false
                    }
                    try? execution.send(signal: .kill)
                    return true
                }
                defer { timer.cancel() }
                let errorStream = execution.standardError
                async let errorTail = OutputTail(collecting: errorStream)
                let outputTail = try await OutputTail(collecting: execution.standardOutput)
                let tails = try await (outputTail, errorTail)
                timer.cancel()
                return await (tails.0, tails.1, timer.value)
            }
            let (outputTail, errorTail, sentKill) = execution.closureResult
            // The timer can fire after the process exited on its own. Its status then stands.
            isTimedOut = sentKill && execution.terminationStatus == .signaled(SIGKILL)
            result = GuestCommandResult(
                status: status(of: execution.terminationStatus),
                output: outputTail.text,
                errorOutput: errorTail.text,
                isOutputTruncated: outputTail.isTruncated,
                isErrorOutputTruncated: errorTail.isTruncated,
            )
        } catch {
            failure = error
        }
        // The process held the only other copy of the read end. Closing this one makes a write
        // that waits for a reader fail, so the writer ends.
        try? pipe.readEnd.close()
        await writer.value

        guard !Task.isCancelled else {
            throw .guestCommandCancelled
        }
        guard let result else {
            throw .guestCommand(reason: "\(failure.map { "\($0)" } ?? "no result")")
        }
        if let timeLimit, isTimedOut {
            throw .guestCommandTimedOut(limit: timeLimit, output: result.output, errorOutput: result.errorOutput)
        }
        return result
    }

    /// Converts a process's termination status.
    ///
    /// - Parameter status: The status that Subprocess reports.
    /// - Returns: The same status as a ``GuestCommandStatus``.
    private static func status(of status: TerminationStatus) -> GuestCommandStatus {
        switch status {
        case let .exited(code):
            .exited(code)
        case let .signaled(signal):
            .signaled(signal)
        }
    }

    /// Writes bytes to a pipe on a dispatch queue and closes the pipe.
    ///
    /// The blocking writes stay off the concurrency pool's threads.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - descriptor: The pipe's write end. The call closes it.
    private static func write(_ bytes: [UInt8], to descriptor: FileDescriptor) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // A failed write means the reader exited early. Its exit status tells why.
                _ = try? descriptor.writeAll(bytes)
                try? descriptor.close()
                continuation.resume()
            }
        }
    }

    /// Removes the client's temporary directory.
    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The end of one output stream, at most ``GuestShell/outputLimit`` bytes.
private struct OutputTail: Sendable {
    /// The last bytes of the stream.
    let bytes: [UInt8]

    /// Whether the stream was longer than ``bytes``.
    let isTruncated: Bool

    /// The bytes as UTF-8 text. Invalid sequences become replacement characters.
    var text: String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Reads a stream to its end and keeps its last bytes.
    ///
    /// - Parameter stream: The stream to read.
    /// - Throws: The stream's read error.
    init(collecting stream: SubprocessOutputSequence) async throws {
        let limit = GuestShell.outputLimit
        var tail: [UInt8] = []
        var isTruncated = false
        for try await buffer in stream {
            buffer.withUnsafeBytes { tail.append(contentsOf: $0) }
            // Trimming only past twice the limit keeps the copying linear in the stream's length.
            if tail.count > 2 * limit {
                tail.removeFirst(tail.count - limit)
                isTruncated = true
            }
        }
        if tail.count > limit {
            tail.removeFirst(tail.count - limit)
            isTruncated = true
        }
        bytes = tail
        self.isTruncated = isTruncated
    }
}
