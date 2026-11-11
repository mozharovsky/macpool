import Foundation
@testable import MacpoolVM
import Testing

/// Tests of the `ssh` arguments and of how a command's input, outputs, and status are collected.
///
/// The time limit turns a collection that never ends into a failure.
@Suite(.timeLimit(.minutes(1)))
struct GuestShellTests {
    /// Builds arguments that ignore the user's configuration and agent and pin the host key.
    @Test(arguments: [false, true])
    func buildsArguments(trustsFirstKey: Bool) {
        let arguments = GuestShell.arguments(
            command: "-oProxyCommand=x",
            username: "macpool",
            address: "192.0.2.1",
            knownHosts: URL(filePath: "/tmp/a b/known_hosts"),
            trustsFirstKey: trustsFirstKey,
        )
        #expect(arguments == [
            "-F", "/dev/null",
            "-o", "ForwardAgent=no",
            "-o", "IdentityAgent=none",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "UserKnownHostsFile=\"/tmp/a b/known_hosts\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlias=macpool-guest",
            "-o", "HostKeyAlgorithms=ssh-ed25519",
            "-o", "StrictHostKeyChecking=\(trustsFirstKey ? "accept-new" : "yes")",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=6",
            "--",
            "macpool@192.0.2.1",
            "-oProxyCommand=x",
        ])
    }

    /// Passes input through and keeps short outputs whole.
    @Test func keepsShortOutputs() async throws {
        let result = try await GuestShell.collect(
            executable: "/bin/sh",
            arguments: ["-c", "cat; printf err >&2"],
            input: "in\n",
        )
        #expect(result == GuestCommandResult(status: .exited(0), output: "in\n", errorOutput: "err"))
    }

    /// Lets a command that writes past the limit run to its end and keeps its exit code.
    @Test func keepsEndOfLongOutput() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.url.appending(path: "finished")
        let script = #"head -c 200000 /dev/zero | tr '\0' a; echo end; head -c 200000 /dev/zero >&2; "#
            + #"touch "$1"; exit 3"#
        let result = try await GuestShell.collect(
            executable: "/bin/sh",
            arguments: ["-c", script, "sh", marker.filePath],
            input: "",
        )
        #expect(result.status == .exited(3))
        #expect(result.isOutputTruncated)
        #expect(result.output.utf8.count == GuestShell.outputLimit)
        #expect(result.output.hasSuffix("aaend\n"))
        #expect(result.isErrorOutputTruncated)
        #expect(result.errorOutput.utf8.count == GuestShell.outputLimit)
        #expect(FileManager.default.fileExists(atPath: marker.filePath))
    }

    /// Returns normally when the command exits without reading a large input.
    ///
    /// Without `F_SETNOSIGPIPE` on the input pipe, the late write raises SIGPIPE in this process.
    @Test func survivesUnreadInput() async throws {
        let input = String(repeating: "x", count: 4 << 20)
        let result = try await GuestShell.collect(executable: "/usr/bin/true", arguments: [], input: input)
        #expect(result.status == .exited(0))
    }

    /// Reports a command that a signal ends.
    @Test func reportsSignal() async throws {
        let result = try await GuestShell.collect(executable: "/bin/sh", arguments: ["-c", "kill -9 $$"], input: "")
        #expect(result.status == .signaled(9))
        #expect(!result.succeeded)
        #expect(result.failureSummary == "ssh signaled(9) without output")
    }

    /// Throws for a cancelled call instead of returning the terminated process's status.
    @Test func throwsWhenCancelled() async throws {
        let started = ContinuousClock.now
        let task = Task {
            try await GuestShell.collect(executable: "/bin/sleep", arguments: ["60"], input: "")
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: MacpoolError.guestCommandCancelled) {
            try await task.value
        }
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    /// Ends a process that outlasts its time limit and keeps the output it wrote before.
    @Test func throwsWhenTimeLimitPasses() async {
        let started = ContinuousClock.now
        await #expect(throws: MacpoolError.guestCommandTimedOut(
            limit: .seconds(2),
            output: "started\n",
            errorOutput: "warning\n",
        )) {
            try await GuestShell.collect(
                executable: "/bin/sh",
                // exec leaves no child that would hold the output streams open after the kill.
                arguments: ["-c", "echo started; echo warning >&2; exec /bin/sleep 60"],
                input: "",
                timeLimit: .seconds(2),
            )
        }
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    /// Returns at once when the process ends before its time limit.
    @Test func returnsBeforeTimeLimit() async throws {
        let started = ContinuousClock.now
        let result = try await GuestShell.collect(
            executable: "/bin/sh",
            arguments: ["-c", "echo done"],
            input: "",
            timeLimit: .seconds(40),
        )
        #expect(result == GuestCommandResult(status: .exited(0), output: "done\n", errorOutput: ""))
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    /// Keeps the status of a process that another signal ends before the time limit.
    @Test func keepsForeignKillBeforeTimeLimit() async throws {
        let result = try await GuestShell.collect(
            executable: "/bin/sh",
            arguments: ["-c", "kill -9 $$"],
            input: "",
            timeLimit: .seconds(40),
        )
        #expect(result.status == .signaled(9))
    }

    /// Describes a time limit with the end of the error output.
    @Test func describesTimeLimit() {
        let quiet = MacpoolError.guestCommandTimedOut(limit: .seconds(5), output: "x", errorOutput: " \n")
        let message = "the guest command did not finish within 5.0 seconds, and it may still run in the guest"
        #expect(quiet.description == message)
        let error = MacpoolError.guestCommandTimedOut(limit: .seconds(5), output: "", errorOutput: "a\nlast\n")
        #expect(error.description == message + ": a\nlast")
    }

    /// Throws when the program cannot start.
    @Test func throwsWhenProgramIsMissing() async {
        await #expect {
            try await GuestShell.collect(executable: "/nonexistent/program", arguments: [], input: "")
        } throws: { error in
            guard case .guestCommand = error as? MacpoolError else {
                return false
            }
            return true
        }
    }
}
