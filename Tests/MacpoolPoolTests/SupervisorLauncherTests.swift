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

    /// Gives a directory the same root through a trailing slash and through a symbolic link.
    @Test func resolvesSpellingsOfOneDirectory() throws {
        let scratch = try ShortDirectory()
        let pool = scratch.url.appending(path: "pool", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pool, withIntermediateDirectories: false)
        let link = scratch.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pool)
        let direct = PoolDirectory(root: pool)
        let path = direct.root.path(percentEncoded: false)
        #expect(!path.hasSuffix("/"))
        #expect(PoolDirectory(root: URL(filePath: path + "/")) == direct)
        #expect(PoolDirectory(root: link) == direct)
        // A directory that does not exist yet keeps its name below the resolved parent.
        let missing = PoolDirectory(root: link.appending(path: "new", directoryHint: .isDirectory))
        #expect(missing.root.path(percentEncoded: false) == path + "/new")
    }

    /// Recognizes a supervisor whose command line spells the data directory differently, and
    /// keeps a directory whose path extends the data directory's path apart.
    @Test func recognizesSupervisorUnderAnySpelling() throws {
        let scratch = try ShortDirectory()
        let pool = scratch.url.appending(path: "pool", directoryHint: .isDirectory)
        let longer = scratch.url.appending(path: "pool2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pool, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: longer, withIntermediateDirectories: false)
        let link = scratch.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pool)
        let id = try #require(LeaseID("0a1b2c3d"))
        let directory = PoolDirectory(root: pool)
        let resolved = directory.root.path(percentEncoded: false)
        func command(_ dataDirectory: String) -> String {
            "/opt/macpool supervise --data-dir \(dataDirectory) --lease 0a1b2c3d --boot-timeout 60\n"
        }
        #expect(ProcessSupervisorLauncher.isSupervisor(command(resolved), of: id, in: directory))
        #expect(ProcessSupervisorLauncher.isSupervisor(command(resolved + "/"), of: id, in: directory))
        #expect(ProcessSupervisorLauncher.isSupervisor(
            command(link.path(percentEncoded: false)),
            of: id,
            in: directory,
        ))
        #expect(!ProcessSupervisorLauncher.isSupervisor(command(resolved + "2"), of: id, in: directory))
        #expect(!ProcessSupervisorLauncher.isSupervisor(command(resolved), of: id, in: PoolDirectory(root: longer)))
        #expect(!ProcessSupervisorLauncher.isSupervisor(command("pool"), of: id, in: directory))
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
