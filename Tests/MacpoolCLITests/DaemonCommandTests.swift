import ArgumentParser
import Foundation
@testable import MacpoolCLI
import MacpoolPool
import Testing

/// Tests of the options that make the daemon listen for paired Macs.
struct DaemonCommandTests {
    /// Passes the listener's address, port, name, and sources to the daemon.
    @Test func parsesTheListener() throws {
        let run = try #require(
            try Macpool.parseAsRoot([
                "daemon", "run", "--listen", "192.0.2.20:7480", "--host-name", "lab",
                "--offer", "base=/vms/base", "--offer", "xcode=/vms/xcode/",
            ]) as? DaemonRunCommand,
        )
        let settings = try #require(run.listening.settings)
        #expect(settings.address == "192.0.2.20")
        #expect(settings.port == 7480)
        #expect(settings.name == "lab")
        #expect(run.listening.offeredSources == ["base": "/vms/base", "xcode": "/vms/xcode"])
    }

    /// Listens on the default port, names the host after this Mac, and resolves relative paths.
    @Test func appliesTheListenerDefaults() throws {
        let run = try #require(
            try Macpool.parseAsRoot(["daemon", "--listen", "192.0.2.20", "--offer", "base=vms/./base"])
                as? DaemonRunCommand,
        )
        let settings = try #require(run.listening.settings)
        #expect(settings.port == 7373)
        #expect(settings.name == PairedMac.localName())
        #expect(run.listening.offeredSources == ["base": FileManager.default.currentDirectoryPath + "/vms/base"])
        #expect(try #require(try Macpool.parseAsRoot(["daemon", "run"]) as? DaemonRunCommand).listening.settings == nil)
    }

    /// Reads IPv6 addresses with and without a port.
    @Test(arguments: zip(
        ["::1", "[::1]", "[2001:db8::20]:7480", "2001:DB8::20"],
        ["[::1]:7373", "[::1]:7373", "[2001:db8::20]:7480", "[2001:DB8::20]:7373"],
    ))
    func readsIPv6Addresses(text: String, shown: String) throws {
        let address = try ListenAddress(parsing: text)
        #expect(address.description == shown)
        #expect(!address.address.hasPrefix("["))
    }

    /// Refuses addresses that the listener cannot bind to and ports outside 1 to 65535.
    @Test(arguments: [
        "lab.local", "0.0.0.0", "::", "127.1", "192.0.2.20:0", "192.0.2.20:65536", "192.0.2.20:x",
        "[192.0.2.20]:7373", "[::1", "[::1]7373", "fe80::1%en0", "",
    ])
    func refusesListenAddresses(text: String) {
        #expect(throws: (any Error).self) {
            try Macpool.parseAsRoot(["daemon", "run", "--listen", text])
        }
    }

    /// Refuses sources without a name or a bundle, a name with a slash, a name used twice, and
    /// options that need `--listen` without it.
    @Test func refusesInvalidListenerOptions() {
        let invalid: [[String]] = [
            ["--offer", "base=/vms/base"],
            ["--host-name", "lab"],
            ["--listen", "192.0.2.20", "--offer", "/vms/base"],
            ["--listen", "192.0.2.20", "--offer", "=/vms/base"],
            ["--listen", "192.0.2.20", "--offer", "base="],
            ["--listen", "192.0.2.20", "--offer", "a/b=/vms/base"],
            ["--listen", "192.0.2.20", "--offer", "base=/vms/a", "--offer", "base=/vms/b"],
            ["--listen", "192.0.2.20", "--host-name", "\u{202E}lab"],
        ]
        for arguments in invalid {
            #expect(throws: (any Error).self, "\(arguments)") {
                try Macpool.parseAsRoot(["daemon", "install"] + arguments)
            }
        }
    }

    /// Writes options into the launchd job that `daemon run` parses back to the same listener.
    @Test func passesTheListenerToTheJob() throws {
        let install = try #require(
            try Macpool.parseAsRoot([
                "daemon", "install", "--data-dir", "/pool", "--slots", "1", "--listen", "[2001:db8::20]:7480",
                "--host-name", "lab", "--offer", "base=vms/base",
            ]) as? DaemonInstallCommand,
        )
        let base = FileManager.default.currentDirectoryPath + "/vms/base"
        let agent = install.agent(running: URL(filePath: "/opt/macpool"))
        #expect(agent.slots == 1)
        #expect(agent.peerArguments == [
            "--listen", "[2001:db8::20]:7480", "--host-name", "lab", "--offer", "base=\(base)",
        ])
        let run = try #require(try Macpool.parseAsRoot(["daemon", "run"] + agent.peerArguments) as? DaemonRunCommand)
        #expect(run.listening.settings?.address == "2001:db8::20")
        #expect(run.listening.settings?.port == 7480)
        #expect(run.listening.settings?.name == "lab")
        #expect(run.listening.offeredSources == ["base": base])

        let local = try #require(try Macpool.parseAsRoot(["daemon", "install"]) as? DaemonInstallCommand)
        #expect(local.agent(running: URL(filePath: "/opt/macpool")).peerArguments.isEmpty)
    }

    /// Prints whether the daemon listens for paired Macs after the first line of `list`.
    @Test func printsTheListener() {
        let listening = PoolSummary(
            slots: 2,
            leases: [],
            queue: [],
            listener: ListenerSummary(address: "2001:db8::20", port: 7373, problem: nil),
        )
        #expect(LeaseOutput.table(listening) == [
            "slots 2, leases 0, queued 0, images 0",
            "listening for paired Macs on [2001:db8::20]:7373",
        ])
        let waiting = PoolSummary(
            slots: 2,
            leases: [],
            queue: [],
            listener: ListenerSummary(address: "192.0.2.20", port: 7373, problem: "the address is not available"),
        )
        #expect(LeaseOutput.table(waiting).last
            == "not listening for paired Macs on 192.0.2.20:7373: the address is not available")
    }
}
