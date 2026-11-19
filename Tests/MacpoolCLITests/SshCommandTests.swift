import ArgumentParser
import Foundation
@testable import MacpoolCLI
import MacpoolPool
import MacpoolVM
import Subprocess
import System
import Testing

/// Tests of `macpool ssh`, its `ProxyCommand`, and the files that let `ssh` log in.
@Suite(.timeLimit(.minutes(1)))
struct SshCommandTests {
    /// Parses the lease, the paired host, the data directory, and the command after `--`.
    @Test func parsesSshOptions() throws {
        let remote = try #require(
            try Macpool.parseAsRoot(["ssh", "--data-dir", "/pool", "--pool", "lab", "0a1b2c3d", "--", "uname", "-a"])
                as? SshCommand,
        )
        #expect(remote.lease == "0a1b2c3d")
        #expect(remote.selection.host == "lab")
        #expect(remote.location.dataDirectory == "/pool")
        #expect(remote.command == ["uname", "-a"])
        let local = try #require(try Macpool.parseAsRoot(["ssh", "0a1b2c3d"]) as? SshCommand)
        #expect(local.selection.host == nil)
        #expect(local.command.isEmpty)
    }

    /// Keeps the words of the `ProxyCommand` out of its line, so that `ssh` and `/bin/sh` give
    /// `macpool connect` the words unchanged.
    @Test func passesTheProxyWordsThroughTheEnvironment() async throws {
        let directory = try ScratchDirectory()
        let printer = directory.url.appending(path: "print words")
        try Data("#!/bin/sh\nfor word in \"$0\" \"$@\"; do printf '%s\\n' \"$word\"; done\n".utf8).write(to: printer)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: printer.path(percentEncoded: false),
        )
        let lease = try #require(LeaseID("0a1b2c3d"))
        let dataDirectory = #"/Volumes/it's 100% "data"\"#
        let proxy = ProxyCommand(
            executable: printer,
            dataDirectory: dataDirectory,
            host: "lab's $HOME %h",
            lease: lease,
        )
        #expect(proxy.line == #""$MACPOOL_PROXY_EXECUTABLE" connect "--data-dir=$MACPOOL_PROXY_DATA_DIR" "#
            + #""--pool=$MACPOOL_PROXY_POOL" "$MACPOOL_PROXY_LEASE""#)

        let printed = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "exec " + proxy.line],
            environment: .inherit.updating(proxy.environment.mapValues { Optional($0) }),
            output: .string(limit: 4096),
        )
        #expect(printed.terminationStatus == .exited(0))
        let words = [
            printer.path(percentEncoded: false),
            "connect",
            "--data-dir=" + dataDirectory,
            "--pool=lab's $HOME %h",
            "0a1b2c3d",
        ]
        #expect(printed.standardOutput == words.joined(separator: "\n") + "\n")
    }

    /// Passes the options through the parser of `ssh`, which reads the path of the pinned keys
    /// and the words of the `ProxyCommand` from the environment.
    @Test func passesTheOptionsThroughSsh() async throws {
        let lease = try #require(LeaseID("0a1b2c3d"))
        let proxy = ProxyCommand(
            executable: URL(filePath: "/usr/local/bin/macpool"),
            dataDirectory: #"/Volumes/data\"#,
            host: "lab",
            lease: lease,
        )
        try await Self.withLogin(Self.access()) { login in
            let printed = try await Subprocess.run(
                .path("/usr/bin/ssh"),
                arguments: Arguments(["-G"] + login.arguments(for: [], through: proxy)),
                environment: .inherit.updating(login.environment(for: proxy)),
                output: .string(limit: 64 * 1024),
                error: .string(limit: 4096),
            )
            #expect(printed.terminationStatus == .exited(0), "\(printed.standardError)")
            let lines = printed.standardOutput.split(separator: "\n").map(String.init)
            #expect(lines.contains("userknownhostsfile \(login.knownHosts.path(percentEncoded: false))"))
            #expect(lines.contains("proxycommand \(proxy.line)"))
        }
    }

    /// Pins the guest's keys under the alias, refuses any other key, and keeps the password out
    /// of the arguments and the directory's regular files.
    @Test func pinsTheGuestsKeysWithoutThePassword() async throws {
        let access = try Self.access()
        let lease = try #require(LeaseID("0a1b2c3d"))
        let proxy = ProxyCommand(
            executable: URL(filePath: "/usr/local/bin/macpool"),
            dataDirectory: nil,
            host: nil,
            lease: lease,
        )
        let directory = try await Self.withLogin(access) { login in
            let arguments = login.arguments(for: ["uname", "-a"], through: proxy)
            let environment = login.environment(for: proxy)
            let knownHosts = try String(contentsOf: login.knownHosts, encoding: .utf8)
            #expect(knownHosts == access.hostKeys.map { "macpool-guest ssh-ed25519 \($0.base64)\n" }.joined())
            #expect(arguments.contains("UserKnownHostsFile=${MACPOOL_KNOWN_HOSTS}"))
            #expect(environment["MACPOOL_KNOWN_HOSTS"] == login.knownHosts.path(percentEncoded: false))
            #expect(arguments.contains("StrictHostKeyChecking=yes"))
            #expect(arguments.contains("HostKeyAlias=macpool-guest"))
            #expect(arguments.contains("HostKeyAlgorithms=ssh-ed25519"))
            #expect(arguments.contains("ProxyCommand=\(proxy.line)"))
            #expect(Array(arguments.suffix(6)) == ["-l", "macpool", "--", "macpool-guest", "uname", "-a"])
            #expect(!arguments.contains { $0.contains(access.password) })
            #expect(!environment.values.contains { $0?.contains(access.password) == true })
            for name in ["known_hosts", "askpass"] {
                let text = try String(contentsOf: login.directory.appending(path: name), encoding: .utf8)
                #expect(!text.contains(access.password))
            }
            let mode = try FileManager.default
                .attributesOfItem(atPath: login.directory.path(percentEncoded: false))[.posixPermissions]
            #expect(mode as? Int == 0o700)
            return login.directory
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }

    /// Hands the password once to each reader of the pipe, also to a reader that waits before it
    /// reads, and stops whether or not a reader came.
    @Test func servesThePasswordToEachReader() async throws {
        let directory = try ScratchDirectory()
        let pipe = try PasswordPipe(at: directory.url.appending(path: "password"), password: "s3cret")
        #expect(await Self.read(pipe.file) == Data("s3cret\n".utf8))
        #expect(await Self.read(pipe.file, after: 0.3) == Data("s3cret\n".utf8))
        #expect(await Self.read(pipe.file) == Data("s3cret\n".utf8))
        await pipe.stop()

        let unread = try PasswordPipe(at: directory.url.appending(path: "unread"), password: "s3cret")
        await unread.stop()
    }

    /// Runs `ssh` with the askpass script and with the shell and the words that the
    /// `ProxyCommand` needs, and returns the exit status of `ssh`.
    @Test func runsSshWithTheAskpassScript() async throws {
        let access = try Self.access()
        let output = try ScratchDirectory()
        let fake = output.url.appending(path: "ssh")
        let script = """
        #!/bin/sh
        "$SSH_ASKPASS" "password:" > '\(output.url.path(percentEncoded: false))/password'
        printf '%s\\n' "$SHELL" > '\(output.url.path(percentEncoded: false))/shell'
        printf '%s\\n' "$MACPOOL_PROXY_EXECUTABLE" "$MACPOOL_PROXY_POOL" "$MACPOOL_PROXY_LEASE" \\
            > '\(output.url.path(percentEncoded: false))/proxy'
        for word in "$@"; do printf '%s\\n' "$word"; done > '\(output.url.path(percentEncoded: false))/arguments'
        exit 3
        """
        try Data(script.utf8).write(to: fake)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fake.path(percentEncoded: false),
        )
        let lease = try #require(LeaseID("0a1b2c3d"))
        let proxy = ProxyCommand(
            executable: URL(filePath: "/usr/local/bin/macpool"),
            dataDirectory: nil,
            host: "lab",
            lease: lease,
        )

        let (status, arguments) = try await Self.withLogin(access) { login in
            let status = try await login.run(
                ["true"],
                through: proxy,
                executable: FilePath(fake.path(percentEncoded: false)),
            )
            return (status, login.arguments(for: ["true"], through: proxy))
        }
        #expect(status == 3)
        let read = { (name: String) in try String(contentsOf: output.url.appending(path: name), encoding: .utf8) }
        #expect(try read("password") == access.password + "\n")
        #expect(try read("shell") == "/bin/sh\n")
        #expect(try read("proxy") == "/usr/local/bin/macpool\nlab\n0a1b2c3d\n")
        #expect(try read("arguments") == arguments.joined(separator: "\n") + "\n")
    }

    /// Creates a login, passes it to a body, and removes it, also when the body throws.
    ///
    /// - Parameters:
    ///   - access: The access for the login.
    ///   - body: The work with the login.
    /// - Returns: The body's result.
    /// - Throws: An error when the login cannot be created, or the body's error.
    private static func withLogin<Value>(
        _ access: GuestAccess,
        _ body: (GuestLogin) async throws -> Value,
    ) async throws -> Value {
        let login = try GuestLogin(access: access)
        do {
            let result = try await body(login)
            await login.remove()
            return result
        } catch {
            await login.remove()
            throw error
        }
    }

    /// Returns an access with two keys whose bytes all hold one value.
    ///
    /// - Returns: The access.
    /// - Throws: An error when a test key is not a valid Ed25519 key blob.
    private static func access() throws -> GuestAccess {
        let keys = try [3, 4].map { (byte: UInt8) in
            let name = Data(HostKey.algorithm.utf8)
            let blob = Data([0, 0, 0, UInt8(name.count)]) + name + Data([0, 0, 0, 32]) + Data(
                repeating: byte,
                count: 32,
            )
            return try #require(HostKey(base64: blob.base64EncodedString()))
        }
        return GuestAccess(username: "macpool", password: "pipe-only-password", hostKeys: keys)
    }

    /// Reads at most 64 bytes from a named pipe on a dispatch queue, stopping early at its end.
    ///
    /// If no writer serves the reader within 10 seconds, the call opens the pipe for writing
    /// itself. The reader's open then returns, and the read ends without bytes.
    ///
    /// - Parameters:
    ///   - file: The pipe.
    ///   - delay: How long the reader holds the pipe open before it reads, in seconds.
    /// - Returns: The bytes, or `nil` when the pipe cannot be opened.
    private static func read(_ file: URL, after delay: TimeInterval = 0) async -> Data? {
        let path = file.path(percentEncoded: false)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            let writer = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 {
                close(writer)
            }
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard let descriptor = try? FileDescriptor.open(FilePath(file.path(percentEncoded: false)), .readOnly)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                Thread.sleep(forTimeInterval: delay)
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 64)
                while data.count < 64,
                      let count = try? buffer.withUnsafeMutableBytes({ try descriptor.read(into: $0) }), count > 0 {
                    data.append(contentsOf: buffer.prefix(min(count, 64 - data.count)))
                }
                try? descriptor.close()
                continuation.resume(returning: data)
            }
        }
    }
}

/// A temporary directory that a test removes with its last reference.
private final class ScratchDirectory {
    /// The directory.
    let url: URL

    /// Creates an empty directory in the temporary directory.
    ///
    /// - Throws: An error when the directory cannot be created.
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "mp-ssh-" + UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Removes the directory.
    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
