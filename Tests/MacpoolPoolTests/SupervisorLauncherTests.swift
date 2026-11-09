import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the launcher that starts and signals supervisor processes.
///
/// The tests start no processes. A process that starts while another test closes a lock file
/// briefly holds that file's lock, so a spawn here could make a daemon test fail at random.
struct SupervisorLauncherTests {
    /// Recognizes only a command line that names the data directory and the lease.
    @Test func recognizesOnlyTheLeaseSupervisor() throws {
        let directory = PoolDirectory(root: URL(filePath: "/Users/me/pool", directoryHint: .isDirectory))
        let id = try #require(LeaseID("0a1b2c3d"))
        let other = try #require(LeaseID("1a2b3c4d"))
        let launcher = ProcessSupervisorLauncher(executable: URL(filePath: "/opt/macpool"))
        let arguments = launcher.arguments(for: SupervisorLaunch(
            lease: id,
            directory: directory,
            sharedDirectory: nil,
            bootTimeout: 60,
        ))
        let command = "/opt/macpool " + arguments.joined(separator: " ") + "\n"
        #expect(ProcessSupervisorLauncher.isSupervisor(command, of: id, in: directory))
        #expect(!ProcessSupervisorLauncher.isSupervisor(command, of: other, in: directory))
        // The parent of the data directory is a prefix of its path.
        let parent = PoolDirectory(root: URL(filePath: "/Users/me", directoryHint: .isDirectory))
        #expect(!ProcessSupervisorLauncher.isSupervisor(command, of: id, in: parent))
        #expect(!ProcessSupervisorLauncher.isSupervisor("sleep 600\n", of: id, in: directory))
    }

    /// Sends no signal for the process identifier 0, which `kill` would apply to the test's whole
    /// process group.
    @Test func ignoresUnrecordedProcess() async throws {
        let launcher = ProcessSupervisorLauncher(executable: URL(filePath: "/opt/macpool"))
        let directory = PoolDirectory(root: URL(filePath: "/Users/me/pool", directoryHint: .isDirectory))
        let id = try #require(LeaseID("0a1b2c3d"))
        await launcher.signal(.kill, processID: 0, of: id, in: directory)
    }
}
