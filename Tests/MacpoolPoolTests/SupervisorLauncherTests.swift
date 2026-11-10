import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the launcher that starts and signals supervisor processes.
///
/// The tests start no processes and read only the test process's own arguments. A process that
/// starts while another test closes a lock file briefly holds that file's lock, so a spawn here
/// could make a daemon test fail at random.
struct SupervisorLauncherTests {
    /// Recognizes only arguments that name the data directory and the lease.
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
        let command = ["/opt/macpool"] + arguments
        #expect(ProcessSupervisorLauncher.isSupervisor(command, of: id, in: directory))
        #expect(!ProcessSupervisorLauncher.isSupervisor(command, of: other, in: directory))
        // The parent of the data directory is a prefix of its path.
        let parent = PoolDirectory(root: URL(filePath: "/Users/me", directoryHint: .isDirectory))
        #expect(!ProcessSupervisorLauncher.isSupervisor(command, of: id, in: parent))
        #expect(!ProcessSupervisorLauncher.isSupervisor(["sleep", "600"], of: id, in: directory))
    }

    /// Passes the shared directory and its read-only flag to the supervisor.
    @Test func passesReadOnlyShare() throws {
        let directory = PoolDirectory(root: URL(filePath: "/Users/me/pool", directoryHint: .isDirectory))
        let launcher = ProcessSupervisorLauncher(executable: URL(filePath: "/opt/macpool"))
        var launch = try SupervisorLaunch(
            lease: #require(LeaseID("0a1b2c3d")),
            directory: directory,
            sharedDirectory: "/share",
            bootTimeout: 60,
        )
        #expect(Array(launcher.arguments(for: launch).suffix(2)) == ["--share", "/share"])
        launch.sharedDirectoryIsReadOnly = true
        #expect(Array(launcher.arguments(for: launch).suffix(3)) == ["--share", "/share", "--share-read-only"])
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

    /// Recognizes a supervisor whose arguments spell the data directory differently, and keeps a
    /// directory whose path extends the data directory's path apart.
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
        func command(_ dataDirectory: String) -> [String] {
            ["/opt/macpool", "supervise", "--data-dir", dataDirectory, "--lease", "0a1b2c3d", "--boot-timeout", "60"]
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

    /// Matches the five elements only as consecutive whole arguments after the first one.
    @Test func matchesOnlyWholeConsecutiveArguments() throws {
        let directory = PoolDirectory(root: URL(filePath: "/Users/me/pool", directoryHint: .isDirectory))
        let id = try #require(LeaseID("0a1b2c3d"))
        let root = directory.root.path(percentEncoded: false)
        let elements = ["supervise", "--data-dir", root, "--lease", "0a1b2c3d"]
        func matches(_ arguments: [String]) -> Bool {
            ProcessSupervisorLauncher.isSupervisor(arguments, of: id, in: directory)
        }
        #expect(matches(["/opt/macpool"] + elements))
        #expect(matches(["/bin/sh", "-c", "sleep 600"] + elements + ["--share", "/tmp"]))
        // The first argument is the program's name, not an argument it parses.
        #expect(!matches(elements))
        // The elements are spread apart by another argument.
        #expect(!matches([
            "/opt/macpool",
            "supervise",
            "--data-dir",
            root,
            "--boot-timeout",
            "60",
            "--lease",
            "0a1b2c3d",
        ]))
        #expect(!matches(["/opt/macpool", "supervise", "--verbose", "--data-dir", root, "--lease", "0a1b2c3d"]))
        // The elements are joined inside one argument, as an earlier text match accepted.
        #expect(!matches(["/opt/macpool", elements.joined(separator: " ")]))
        #expect(!matches(["/bin/sh", "-c", "echo " + elements.joined(separator: " ") + " ", "x"]))
        #expect(!matches(["/opt/macpool", "supervise --data-dir", root, "--lease", "0a1b2c3d"]))
        #expect(!matches(["/opt/macpool", "supervise", "--data-dir", root, "--lease 0a1b2c3d"]))
        // An identifier that contains the lease's identifier is another lease.
        #expect(!matches(["/opt/macpool", "supervise", "--data-dir", root, "--lease", "0a1b2c3d0"]))
        #expect(!matches(["/opt/macpool", "supervise", "--data-dir", root, "--lease"]))
    }

    /// Recognizes a data directory whose path holds spaces, a tab, and characters outside ASCII,
    /// which a locale-dependent listing of the command line escapes.
    @Test func recognizesDirectoryWithAnyCharacters() throws {
        let scratch = try ShortDirectory()
        let pool = scratch.url.appending(path: "caf\u{E9} \t\u{43F}\u{443}\u{43B}", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pool, withIntermediateDirectories: false)
        let directory = PoolDirectory(root: pool)
        let id = try #require(LeaseID("0a1b2c3d"))
        let launcher = ProcessSupervisorLauncher(executable: URL(filePath: "/opt/macpool"))
        let arguments = launcher.arguments(for: SupervisorLaunch(
            lease: id,
            directory: directory,
            sharedDirectory: nil,
            bootTimeout: 60,
        ))
        #expect(arguments[2].hasSuffix("caf\u{E9} \t\u{43F}\u{443}\u{43B}"))
        #expect(ProcessSupervisorLauncher.isSupervisor(["/opt/macpool"] + arguments, of: id, in: directory))
    }

    /// Reports why a process that is not a supervisor does not match, and sends no signal for the
    /// process identifier 0, which `kill` would apply to the test's whole process group.
    @Test func reportsWhyAProcessDoesNotMatch() async throws {
        let launcher = ProcessSupervisorLauncher(executable: URL(filePath: "/opt/macpool"))
        let directory = PoolDirectory(root: URL(filePath: "/Users/me/pool", directoryHint: .isDirectory))
        let id = try #require(LeaseID("0a1b2c3d"))
        await #expect(throws: SupervisorMismatch.noProcess) {
            try await launcher.identify(processID: 0, startTime: .absent, of: id, in: directory)
        }
        launcher.send(.kill, to: 0, of: id, in: directory)
        // The test's own process runs, but not as a supervisor.
        await #expect(throws: SupervisorMismatch.otherArguments) {
            try await launcher.identify(processID: getpid(), startTime: .absent, of: id, in: directory)
        }
    }

    /// Checks a recorded start time before the arguments and withholds a match for another start
    /// time or a malformed record.
    @Test func comparesRecordedStartTime() async throws {
        let launcher = ProcessSupervisorLauncher(executable: URL(filePath: "/opt/macpool"))
        let directory = PoolDirectory(root: URL(filePath: "/Users/me/pool", directoryHint: .isDirectory))
        let id = try #require(LeaseID("0a1b2c3d"))
        let started = try ProcessStartTime.read(processID: getpid())
        func identify(_ startTime: RecordedStartTime) async throws(SupervisorMismatch) {
            try await launcher.identify(processID: getpid(), startTime: startTime, of: id, in: directory)
        }
        // The test process has the recorded start time but runs no supervisor.
        await #expect(throws: SupervisorMismatch.otherArguments) {
            try await identify(.recorded(started))
        }
        await #expect(throws: SupervisorMismatch.startTimeDiffers(recorded: started + 1, actual: started)) {
            try await identify(.recorded(started + 1))
        }
        await #expect(throws: SupervisorMismatch.malformedStartTime) {
            try await identify(.malformed)
        }
    }
}
