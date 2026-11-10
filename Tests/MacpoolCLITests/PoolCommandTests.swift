import ArgumentParser
import Foundation
@testable import MacpoolCLI
@testable import MacpoolPool
import Testing

/// Tests of the pool commands' arguments and output.
struct PoolCommandTests {
    /// Parses `lease` with every option and a command after the terminator.
    @Test func parsesLeaseOptions() throws {
        let command = try Macpool.parseAsRoot([
            "lease", "--data-dir", "/pool", "--from", "/vms/base", "--ttl", "600", "--priority", "3",
            "--restart", "always", "--share", "/share", "--boot-timeout", "300", "--", "ssh", "-V",
        ])
        let lease = try #require(command as? LeaseCommand)
        #expect(lease.location.directory.root.path(percentEncoded: false) == "/pool")
        #expect(lease.command == ["ssh", "-V"])
        #expect(lease.terms == LeaseTerms(
            source: "/vms/base",
            timeToLive: 600,
            priority: 3,
            restartPolicy: .always,
            sharedDirectory: "/share",
            bootTimeout: 300,
            detached: false,
        ))
    }

    /// Applies the documented defaults to `lease` and resolves relative paths.
    @Test func appliesLeaseDefaults() throws {
        let lease = try #require(try Macpool.parseAsRoot(["lease", "--from", "base", "--detach"]) as? LeaseCommand)
        #expect(lease.terms.source == FileManager.default.currentDirectoryPath + "/base")
        #expect(lease.terms.timeToLive == 3600)
        #expect(lease.terms.priority == 0)
        #expect(lease.terms.restartPolicy == .onFailure)
        #expect(lease.terms.bootTimeout == 900)
        #expect(lease.terms.detached)
        #expect(lease.location.directory == .standard)
    }

    /// Rejects contradictory and out-of-range lease options.
    @Test func rejectsInvalidLeaseOptions() {
        let invalid = [
            ["lease", "--from", "b", "--detach", "--", "true"],
            ["lease", "--from", "b", "--ttl", "0"],
            ["lease", "--from", "b", "--boot-timeout", "0"],
            ["lease", "--from", "b", "--restart", "sometimes"],
            ["lease"],
            ["daemon", "run", "--slots", "3"],
            ["daemon", "install", "--slots", "0"],
        ]
        for arguments in invalid {
            #expect(throws: (any Error).self) {
                try Macpool.parseAsRoot(arguments)
            }
        }
    }

    /// Parses the commands that manage leases and the daemon.
    @Test func parsesPoolCommands() throws {
        let release = try #require(try Macpool.parseAsRoot(["release", "0a1b2c3d"]) as? ReleaseCommand)
        #expect(release.lease == "0a1b2c3d")
        let renew = try #require(try Macpool.parseAsRoot(["renew", "0a1b2c3d"]) as? RenewCommand)
        #expect(renew.lease == "0a1b2c3d")
        let list = try #require(try Macpool.parseAsRoot(["list", "--json"]) as? ListCommand)
        #expect(list.json)
        let daemon = try #require(try Macpool.parseAsRoot(["daemon", "--slots", "1"]) as? DaemonRunCommand)
        #expect(daemon.slots == 1)
        let run = try #require(try Macpool.parseAsRoot(["daemon", "run"]) as? DaemonRunCommand)
        #expect(run.slots == 2)
        #expect(try Macpool.parseAsRoot(["daemon", "install"]) is DaemonInstallCommand)
        #expect(try Macpool.parseAsRoot(["daemon", "uninstall"]) is DaemonUninstallCommand)
        let supervise = try #require(
            try Macpool.parseAsRoot(["supervise", "--data-dir", "/pool", "--lease", "0a1b2c3d"]) as? SuperviseCommand,
        )
        #expect(supervise.bootTimeout == 900)
        #expect(supervise.share == nil)
    }

    /// Parses only lease identifiers.
    @Test func parsesLeaseIdentifiers() throws {
        #expect(try LeaseID.parse("0a1b2c3d").rawValue == "0a1b2c3d")
        #expect(throws: CommandError.self) {
            try LeaseID.parse("../etc")
        }
    }

    /// Formats the pool as a table with aligned columns and queued requests.
    @Test func formatsPoolTable() throws {
        let pool = try PoolSummary(
            slots: 2,
            leases: [
                LeaseSummary(
                    id: #require(LeaseID("0a1b2c3d")),
                    source: "/vms/base",
                    bundle: "/pool/leases/0a1b2c3d",
                    phase: .ready,
                    address: "192.168.64.2",
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                    restarts: 0,
                    detached: false,
                    priority: 0,
                ),
                LeaseSummary(
                    id: #require(LeaseID("ffff0000")),
                    source: "/vms/other",
                    bundle: "/pool/leases/ffff0000",
                    phase: .starting,
                    address: nil,
                    expiresAt: nil,
                    restarts: 1,
                    detached: true,
                    priority: 2,
                ),
            ],
            queue: [
                QueuedSummary(position: 1, source: "/vms/base", priority: 5, since: Date(timeIntervalSince1970: 0)),
            ],
        )
        #expect(LeaseOutput.table(pool) == [
            "slots 2, leases 2, queued 1",
            "LEASE     PHASE     ADDRESS       EXPIRES               RESTARTS  SOURCE",
            "0a1b2c3d  ready     192.168.64.2  2027-01-15T08:00:00Z  0         /vms/base",
            "ffff0000  starting  -             -                     1         /vms/other",
            "queued 1: priority 5, since 1970-01-01T00:00:00Z, /vms/base",
        ])
    }

    /// Leaves a running supervisor's socket and exit record alone when its lease is supervised.
    @Test func superviseRefusesLeaseWithRunningSupervisor() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "mp-" + UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = PoolDirectory(root: parent)
        try directory.prepare()
        let id = try #require(LeaseID("0a1b2c3d"))
        let lock = try SupervisorLock(of: id, in: directory, processID: 4242, startTime: 1)
        try directory.writeExitRecord(.requested, for: id)
        let command = try #require(
            try Macpool.parseAsRoot([
                "supervise", "--data-dir", parent.path(percentEncoded: false), "--lease", id.rawValue,
            ]) as? SuperviseCommand,
        )
        await #expect(throws: CommandError.pool(.supervisorRunning(id: id.rawValue))) {
            try await command.run()
        }
        #expect(directory.readExitRecord(for: id) == .requested)
        #expect(SupervisorLock.holder(of: id, in: directory)?.processID == 4242)
        withExtendedLifetime(lock) {}
    }
}
