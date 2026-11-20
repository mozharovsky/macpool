import ArgumentParser
import Foundation
import MacpoolPool
import MacpoolVM
import Subprocess
import System

/// Logs in to a lease's guest with `ssh` through `macpool connect`.
///
/// The command first asks the daemon for the guest's account and pinned host keys. The daemon
/// reads them from the lease's bundle and connects to no guest. The command then runs
/// `/usr/bin/ssh` with `macpool connect` as its `ProxyCommand`, so `ssh` reaches the guest through
/// a stream. `ssh` accepts only the pinned keys and ignores your SSH configuration and agent.
///
/// `ssh` reads the password through an askpass script from a named pipe that this command serves.
/// The password appears in no file, process argument, or environment variable.
///
/// The command exits with the status of `ssh`. That is the status of the command in the guest, or
/// 255 when `ssh` fails.
struct SshCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Logs in to a lease's guest with ssh through macpool connect.",
    )

    /// The data directory of this Mac's daemon, which also holds this Mac's key and paired hosts.
    @OptionGroup var location: PoolOptions

    /// The paired host that holds the lease, if any.
    @OptionGroup var selection: HostSelection

    /// The lease whose guest to log in to.
    @Argument(help: "The lease whose guest to log in to.")
    var lease: String

    /// A command to run in the guest instead of a shell.
    @Argument(
        parsing: .postTerminator,
        help: "A command to run in the guest after --. Without one, ssh opens a shell.",
    )
    var command: [String] = []

    /// Runs `ssh` and exits with its status.
    ///
    /// - Throws: ``CommandError`` when the identifier is malformed, the daemon or host refuses the
    ///   access, or `ssh` cannot start. Throws `ExitCode` with the status of `ssh` when it is not
    ///   zero.
    func run() async throws {
        let status = try await perform()
        if status != 0 {
            throw ExitCode(status)
        }
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Returns: The exit status of `ssh`.
    /// - Throws: ``CommandError`` when the identifier is malformed, the daemon or host refuses the
    ///   access, or `ssh` cannot start.
    private func perform() async throws(CommandError) -> Int32 {
        let id = try LeaseID.parse(lease)
        let access = try await selection.guestAccess(to: id, in: location.directory)
        let proxy = try ProxyCommand(
            executable: Executable.current(),
            dataDirectory: location.dataDirectory,
            host: access.host,
            lease: id,
        )
        let login = try GuestLogin(access: access.guest)
        let status: Result<Int32, CommandError>
        do throws(CommandError) {
            status = try await .success(login.run(command, through: proxy))
        } catch {
            status = .failure(error)
        }
        await login.remove()
        return try status.get()
    }
}

/// The access to a lease's guest and the host that gave it.
struct HostAccess {
    /// The account and the pinned host keys that log in to the guest.
    let guest: GuestAccess

    /// The paired host's key, or `nil` for the daemon on this Mac.
    let host: KeyFingerprint?
}

/// The request for the access to a lease's guest on the selected daemon.
extension HostSelection {
    /// Asks the selected daemon for the account and the pinned host keys of a lease's guest.
    ///
    /// - Parameters:
    ///   - lease: The lease.
    ///   - directory: This Mac's data directory.
    /// - Returns: The access and the key of the paired host that gave it.
    /// - Throws: ``CommandError/pool(_:)`` when the host is unknown, the connection fails, or the
    ///   daemon refuses the request. A paired host's error passes through
    ///   ``escapingPeerText(_:)``.
    func guestAccess(to lease: LeaseID, in directory: PoolDirectory) async throws(CommandError) -> HostAccess {
        guard let host else {
            let guest = try await pool { () async throws(PoolError) in
                try await PoolClient.guestAccess(to: lease, in: directory)
            }
            return HostAccess(guest: guest, host: nil)
        }
        do {
            let paired = try TrustedHost.named(host, in: directory)
            let guest = try await PoolClient.guestAccess(to: lease, on: paired, directory: directory)
            return HostAccess(guest: guest, host: paired.key)
        } catch {
            throw .pool(Self.escapingPeerText(error))
        }
    }
}

/// The `ProxyCommand` of `ssh` that reaches a lease's guest through `macpool connect`.
///
/// `ssh` parses quotes and backslashes in the option, expands `%` tokens in the command, and runs
/// it with the shell in `SHELL`. The line is therefore fixed, and the shell reads each word from
/// an environment variable that ``GuestLogin`` sets for `ssh`. ``GuestLogin`` also sets `SHELL` to
/// `/bin/sh`.
struct ProxyCommand: Equatable {
    /// The value of the `ProxyCommand` option.
    let line: String

    /// The variables that hold the words of the command, keyed by name.
    let environment: [Environment.Key: String]

    /// Creates the command for a lease.
    ///
    /// - Parameters:
    ///   - executable: The `macpool` executable.
    ///   - dataDirectory: The data directory as the person typed it, or `nil` for the default. A
    ///     relative path becomes absolute.
    ///   - host: The paired host's key, or `nil` for the daemon on this Mac. The full key names one
    ///     host, so `connect` reaches the host that gave the access.
    ///   - lease: The lease.
    init(executable: URL, dataDirectory: String?, host: KeyFingerprint?, lease: LeaseID) {
        var line = #""$MACPOOL_PROXY_EXECUTABLE" connect"#
        var environment: [Environment.Key: String] = [
            "MACPOOL_PROXY_EXECUTABLE": executable.path(percentEncoded: false),
            "MACPOOL_PROXY_LEASE": lease.rawValue,
        ]
        if let dataDirectory {
            line += #" "--data-dir=$MACPOOL_PROXY_DATA_DIR""#
            environment["MACPOOL_PROXY_DATA_DIR"] = URL(filePath: dataDirectory).absoluteURL.path(percentEncoded: false)
        }
        if let host {
            line += #" "--pool=$MACPOOL_PROXY_POOL""#
            environment["MACPOOL_PROXY_POOL"] = host.rawValue
        }
        line += #" "$MACPOOL_PROXY_LEASE""#
        self.line = line
        self.environment = environment
    }
}

/// A private temporary directory that lets `ssh` log in to a guest with the daemon's access.
///
/// The directory holds a `known_hosts` file that pins the guest's keys under the alias
/// `macpool-guest`, an askpass script, and the named pipe of a ``PasswordPipe``. Call ``remove()``
/// once `ssh` exited.
///
/// A process that `SIGKILL` ends leaves the directory in the temporary directory. It holds no
/// password.
final class GuestLogin: Sendable {
    /// The directory, which only its owner can open.
    let directory: URL

    /// The account and the keys to pin.
    let access: GuestAccess

    /// The pipe that hands `ssh` the password.
    private let pipe: PasswordPipe

    /// Creates the directory with the `known_hosts` file, the askpass script, and the pipe.
    ///
    /// - Parameter access: The access from the daemon's reply.
    /// - Throws: ``CommandError/library(_:)`` when a file cannot be created.
    init(access: GuestAccess) throws(CommandError) {
        let template = FileManager.default.temporaryDirectory.appending(path: "macpool-ssh-XXXXXX")
        var buffer = Array(template.path(percentEncoded: false).utf8CString)
        guard mkdtemp(&buffer) != nil else {
            throw Self.failure("creating a directory for ssh", template)
        }
        // mkdtemp creates the directory with owner-only permissions and writes its name in place.
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let directory = URL(filePath: path, directoryHint: .isDirectory)
        self.directory = directory
        self.access = access
        let knownHosts = access.hostKeys.map { $0.knownHostsLine(alias: VMBundle.hostKeyAlias) + "\n" }.joined()
        let script = "#!/bin/sh\nexec /bin/cat \"$MACPOOL_PASSWORD_PIPE\"\n"
        do throws(CommandError) {
            try Self.create(directory.appending(path: "known_hosts"), contents: knownHosts, permissions: 0o600)
            try Self.create(directory.appending(path: "askpass"), contents: script, permissions: 0o700)
            pipe = try PasswordPipe(at: directory.appending(path: "password"), password: access.password)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The `known_hosts` file that pins the guest's keys.
    var knownHosts: URL {
        directory.appending(path: "known_hosts")
    }

    /// The askpass script, which prints what it reads from the pipe in `MACPOOL_PASSWORD_PIPE`.
    var askpass: URL {
        directory.appending(path: "askpass")
    }

    /// Builds the `ssh` arguments.
    ///
    /// - Parameters:
    ///   - command: The words of the command to run in the guest, or an empty array for a shell.
    ///     `ssh` joins them with spaces, and the guest's shell splits them again.
    ///   - proxy: The command that connects `ssh` to the guest.
    /// - Returns: The arguments. The destination and the command follow `--`.
    func arguments(for command: [String], through proxy: ProxyCommand) -> [String] {
        [
            "-F", "/dev/null",
            "-o", "ForwardAgent=no",
            "-o", "IdentityAgent=none",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
            // ssh parses quotes and expands % tokens in the option, but not in the variable's value.
            "-o", "UserKnownHostsFile=${MACPOOL_KNOWN_HOSTS}",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlias=\(VMBundle.hostKeyAlias)",
            "-o", "HostKeyAlgorithms=\(HostKey.algorithm)",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UpdateHostKeys=no",
            "-o", "ProxyCommand=\(proxy.line)",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=6",
            "-l", access.username,
            "--",
            VMBundle.hostKeyAlias,
        ] + command
    }

    /// Returns the variables that `ssh` needs in addition to this process's environment.
    ///
    /// - Parameter proxy: The command that connects `ssh` to the guest.
    /// - Returns: The askpass script, the pipe of the password, the `known_hosts` file, the shell
    ///   for the `ProxyCommand`, and the words of the `ProxyCommand`.
    func environment(for proxy: ProxyCommand) -> [Environment.Key: String?] {
        var environment: [Environment.Key: String?] = [
            "SSH_ASKPASS": askpass.path(percentEncoded: false),
            "SSH_ASKPASS_REQUIRE": "force",
            "MACPOOL_PASSWORD_PIPE": pipe.file.path(percentEncoded: false),
            "MACPOOL_KNOWN_HOSTS": knownHosts.path(percentEncoded: false),
            "SHELL": "/bin/sh",
        ]
        environment.merge(proxy.environment.mapValues { Optional($0) }) { $1 }
        return environment
    }

    /// Runs `ssh` with this process's standard input, output, and error.
    ///
    /// `SIGHUP`, `SIGINT`, and `SIGTERM` end `ssh` with `SIGTERM`, and with `SIGKILL` 10 seconds
    /// later.
    ///
    /// - Parameters:
    ///   - command: The words of the command to run in the guest, or an empty array for a shell.
    ///   - proxy: The command that connects `ssh` to the guest.
    ///   - executable: The `ssh` program.
    /// - Returns: The exit status of `ssh`. When `ssh` ends by a signal, or a signal interrupts
    ///   the call, the status is 128 plus the signal's number.
    /// - Throws: ``CommandError/tool(_:reason:)`` when `ssh` cannot start.
    func run(
        _ command: [String],
        through proxy: ProxyCommand,
        executable: FilePath = "/usr/bin/ssh",
    ) async throws(CommandError) -> Int32 {
        let (signals, sink) = AsyncStream.makeStream(of: Int32.self)
        let watch = SignalWatch(signals: [SIGHUP, SIGINT, SIGTERM]) { sink.yield($0) }
        defer { watch.cancel() }
        let arguments = Arguments(arguments(for: command, through: proxy))
        let environment = Environment.inherit.updating(environment(for: proxy))
        var options = PlatformOptions()
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(10))]
        let running = Task { [options] in
            try await Subprocess.run(
                .path(executable),
                arguments: arguments,
                environment: environment,
                platformOptions: options,
                input: .currentStandardInput,
                output: .currentStandardOutput,
                error: .currentStandardError,
            ).terminationStatus
        }
        let interrupting = Task { () -> Int32? in
            for await number in signals {
                running.cancel()
                return number
            }
            return nil
        }
        let result = await running.result
        sink.finish()
        if let interruption = await interrupting.value {
            return 128 + interruption
        }
        switch result {
        case let .success(.exited(code)):
            return code
        case let .success(.signaled(signal)):
            return 128 + signal
        case let .failure(error):
            throw .tool("ssh", reason: "\(error)")
        }
    }

    /// Stops serving the password and removes the directory.
    func remove() async {
        await pipe.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Creates a file that must not exist yet.
    ///
    /// - Parameters:
    ///   - file: The file.
    ///   - contents: The text to write.
    ///   - permissions: The file's mode.
    /// - Throws: ``CommandError/library(_:)`` when the file cannot be created or written.
    private static func create(_ file: URL, contents: String, permissions: mode_t) throws(CommandError) {
        let descriptor = open(file.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard descriptor >= 0 else {
            throw failure("creating a file for ssh", file)
        }
        let handle = FileDescriptor(rawValue: descriptor)
        do {
            // A failed close must not lead to a second close of a number that another file may
            // already hold.
            _ = try handle.closeAfter { try handle.writeAll(Array(contents.utf8)) }
        } catch {
            throw .library(.fileSystem(
                operation: "writing a file for ssh",
                path: file.path(percentEncoded: false),
                reason: "\(error)",
            ))
        }
    }

    /// Describes a failed system call with the reason in `errno`.
    ///
    /// - Parameters:
    ///   - operation: What the call did.
    ///   - file: The file that it acted on.
    /// - Returns: The error.
    private static func failure(_ operation: String, _ file: URL) -> CommandError {
        .library(.fileSystem(
            operation: operation,
            path: file.path(percentEncoded: false),
            reason: String(cString: strerror(errno)),
        ))
    }
}

/// A named pipe that hands a password to the first processes that open it for reading.
///
/// A thread waits for a reader, writes the password and a line break, and closes its end. Before
/// it closes, it replaces the pipe's file with a new pipe. The reader then sees the end after one
/// line, and the next reader opens the new pipe. After ``readerLimit`` readers, the thread removes
/// the file instead, so a later reader finds no pipe. The password therefore stays in this process
/// until a reader takes it. Call ``stop()`` once, before removing the pipe's file.
final class PasswordPipe: Sendable {
    /// The number of readers that receive the password.
    ///
    /// `ssh` asks once for password authentication and once for keyboard-interactive
    /// authentication.
    static let readerLimit = 2

    /// The pipe's file.
    let file: URL

    /// Whether ``stop()`` began.
    private let stopping = StopFlag()

    /// The signal that the serving thread ended.
    private let ended = DispatchSemaphore(value: 0)

    /// Creates the pipe with owner-only permissions and starts serving the password.
    ///
    /// - Parameters:
    ///   - file: The pipe's file, which must not exist.
    ///   - password: The password.
    /// - Throws: ``CommandError/library(_:)`` when the pipe cannot be created.
    init(at file: URL, password: String) throws(CommandError) {
        self.file = file
        let path = file.path(percentEncoded: false)
        guard mkfifo(path, 0o600) == 0 else {
            throw .library(.fileSystem(
                operation: "creating a pipe for the password",
                path: path,
                reason: String(cString: strerror(errno)),
            ))
        }
        let line = Array((password + "\n").utf8)
        let stopping = stopping
        let ended = ended
        Thread {
            Self.serve(line, at: path, until: stopping)
            ended.signal()
        }.start()
    }

    /// Writes a line to each reader of a pipe until ``readerLimit`` readers took it, a flag is set,
    /// or the pipe cannot be replaced.
    ///
    /// - Parameters:
    ///   - line: The bytes to write.
    ///   - path: The pipe's path.
    ///   - stopping: The flag that ends the loop.
    private static func serve(_ line: [UInt8], at path: String, until stopping: StopFlag) {
        var served = 0
        while served < readerLimit {
            // The open returns once a reader opens the pipe.
            let descriptor = open(path, O_WRONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno == EINTR {
                    continue
                }
                return
            }
            let writer = FileDescriptor(rawValue: descriptor)
            guard !stopping.isSet else {
                try? writer.close()
                return
            }
            // A reader that leaves early then fails the write instead of ending the process.
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            _ = try? writer.writeAll(line)
            served += 1
            let isReplaced: Bool
            if served < readerLimit {
                // While the reader holds the old pipe open, a new open of the same pipe would
                // return at once and write the line to that reader again. The rename replaces the
                // pipe in one step, so a reader never finds the name missing.
                let next = path + ".next"
                isReplaced = mkfifo(next, 0o600) == 0 && rename(next, path) == 0
            } else {
                // Removing the name before the close keeps a later reader from opening this pipe.
                _ = unlink(path)
                isReplaced = false
            }
            try? writer.close()
            guard isReplaced else {
                return
            }
        }
    }

    /// Stops serving and waits up to 5 seconds until the serving thread ended.
    func stop() async {
        stopping.set()
        let path = file.path(percentEncoded: false)
        let ended = ended
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // Opening the read end wakes the thread when its open waits for a reader. The
                // thread may be replacing the pipe meanwhile, so the call tries again.
                for _ in 0 ..< 50 {
                    let reader = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
                    let hasEnded = ended.wait(timeout: .now() + .milliseconds(100)) == .success
                    if reader >= 0 {
                        close(reader)
                    }
                    if hasEnded {
                        break
                    }
                }
                continuation.resume()
            }
        }
    }
}
