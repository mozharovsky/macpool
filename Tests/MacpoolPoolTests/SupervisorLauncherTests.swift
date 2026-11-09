import Foundation
@testable import MacpoolPool
import Subprocess
import System
import Testing

/// Tests of the launcher that starts and signals supervisor processes.
@Suite(.timeLimit(.minutes(1)))
struct SupervisorLauncherTests {
    /// Signals only a process whose command line names the data directory and the lease.
    @Test func signalsOnlyTheLeaseSupervisor() async throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        let id = try #require(LeaseID("0a1b2c3d"))
        let other = try #require(LeaseID("1a2b3c4d"))
        let launcher = ProcessSupervisorLauncher(executable: URL(filePath: "/usr/bin/false"))
        // The shell runs a loop instead of replacing itself, so its command line keeps the
        // supervisor's arguments.
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: [
                "-c", "while :; do sleep 1; done",
                "supervise", "--data-dir", directory.root.path(percentEncoded: false), "--lease", id.rawValue,
                "--boot-timeout", "60",
            ],
            input: .none,
            output: .discarded,
            error: .discarded,
        ) { execution in
            let processID = execution.processIdentifier.value
            await launcher.signal(.terminate, processID: processID, of: other, in: directory)
            // The parent of the data directory is a prefix of its path and must not match.
            await launcher.signal(.kill, processID: processID, of: id, in: PoolDirectory(root: root.url))
            try? await Task.sleep(for: .milliseconds(300))
            let survived = kill(processID, 0) == 0
            await launcher.signal(.terminate, processID: processID, of: id, in: directory)
            return survived
        }
        #expect(result.closureResult)
        guard case let .signaled(signal) = result.terminationStatus else {
            Issue.record("unexpected status \(result.terminationStatus)")
            return
        }
        #expect(signal == SIGTERM)
    }
}
