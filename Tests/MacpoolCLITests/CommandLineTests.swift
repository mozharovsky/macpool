import ArgumentParser
import Foundation
import Logging
@testable import MacpoolCLI
import MacpoolVM
import Testing

/// Tests of argument parsing, defaults, and output formatting.
struct CommandLineTests {
    /// Parses `run` with every option set.
    @Test func parsesRunOptions() throws {
        let command = try Macpool.parseAsRoot([
            "run", "--bundle", ".cache/vms/clone", "--share", "/tmp/share",
            "--provision", "--wait-ssh", "--timeout", "120", "--hold", "60", "--log-level", "debug",
        ])
        let run = try #require(command as? RunCommand)
        #expect(run.bundle == ".cache/vms/clone")
        #expect(run.sharing.share == "/tmp/share")
        #expect(!run.sharing.readOnly)
        #expect(run.provision)
        #expect(run.waitSSH)
        #expect(run.timeout == 120)
        #expect(run.hold == 60)
        #expect(run.logging.logLevel == .debug)
        #expect(run.logging.makeLogger(label: "test").logLevel == .debug)
    }

    /// Parses a read-only share and rejects the flag without a directory.
    @Test func parsesReadOnlyShare() throws {
        let run = try #require(
            try Macpool.parseAsRoot(["run", "--bundle", "b", "--share", "/tmp/share", "--share-read-only"])
                as? RunCommand,
        )
        #expect(run.sharing.sharedDirectory == SharedDirectory(url: URL(filePath: "/tmp/share"), isReadOnly: true))
        #expect(throws: (any Error).self) {
            try Macpool.parseAsRoot(["run", "--bundle", "b", "--share-read-only"])
        }
    }

    /// Applies the documented defaults to `run`, `create`, and `fetch`.
    @Test func appliesDefaults() throws {
        let run = try #require(try Macpool.parseAsRoot(["run", "--bundle", "b"]) as? RunCommand)
        #expect(run.timeout == 900)
        #expect(run.hold == 0)
        #expect(!run.provision)
        #expect(!run.waitSSH)
        #expect(run.logging.logLevel == .warning)
        #expect(run.sharing.sharedDirectory == nil)
        let create = try #require(
            try Macpool.parseAsRoot(["create", "--ipsw", "i.ipsw", "--bundle", "b"]) as? CreateCommand,
        )
        #expect(create.diskGigabytes == 128)
        #expect(create.cpus == 8)
        #expect(create.memoryGigabytes == 16)
        #expect(create.logging.logLevel == .warning)
        let fetch = try #require(try Macpool.parseAsRoot(["fetch"]) as? FetchCommand)
        #expect(fetch.cache == ".cache/ipsw")
        #expect(!fetch.download)
    }

    /// Accepts the gigabyte options under their hyphenated names.
    @Test func parsesGigabyteOptions() throws {
        let create = try #require(
            try Macpool.parseAsRoot([
                "create", "--ipsw", "i.ipsw", "--bundle", "b", "--disk-gb", "80", "--memory-gb", "24",
            ]) as? CreateCommand,
        )
        #expect(create.diskGigabytes == 80)
        #expect(create.memoryGigabytes == 24)
    }

    /// Names the address subcommand `ip` and the clone options `from` and `to`.
    @Test func parsesAddressAndClone() throws {
        let address = try #require(try Macpool.parseAsRoot(["ip", "--bundle", "b"]) as? AddressCommand)
        #expect(address.bundle == "b")
        let clone = try #require(try Macpool.parseAsRoot(["clone", "--from", "a", "--to", "b"]) as? CloneCommand)
        #expect(clone.from == "a")
        #expect(clone.to == "b")
    }

    /// Rejects negative durations and missing required options.
    @Test func rejectsInvalidArguments() {
        #expect(throws: (any Error).self) {
            try Macpool.parseAsRoot(["run", "--bundle", "b", "--hold", "-1"])
        }
        #expect(throws: (any Error).self) {
            try Macpool.parseAsRoot(["clone", "--from", "a"])
        }
    }

    /// Converts gigabytes to bytes and rejects sizes beyond 64 bits.
    @Test func convertsGigabytes() throws {
        #expect(try CreateCommand.byteCount(gigabytes: 16) == 17_179_869_184)
        #expect(throws: CommandError.self) {
            try CreateCommand.byteCount(gigabytes: UInt64.max)
        }
    }

    /// Formats measurement lines and durations with fixed decimals.
    @Test func formatsMeasurements() {
        #expect(Report.measurementLine("ssh_seconds", "9.8") == "measure ssh_seconds=9.8")
        #expect(Report.seconds(.milliseconds(9840), decimals: 1) == "9.8")
        #expect(Report.seconds(.milliseconds(1), decimals: 3) == "0.001")
        #expect(Report.seconds(.seconds(264), decimals: 0) == "264")
    }
}
