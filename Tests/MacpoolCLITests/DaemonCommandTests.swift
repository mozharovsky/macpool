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
                "--allow-from", "100.64.0.0/10", "--allow-from", "FD7A:115C:A1E0::/48", "--coordinator", "hub",
            ]) as? DaemonRunCommand,
        )
        let settings = try #require(run.listening.settings)
        #expect(settings.coordinator == "hub")
        #expect(settings.address == "192.0.2.20")
        #expect(settings.port == 7480)
        #expect(settings.name == "lab")
        #expect(settings.allowedSources.map(\.description) == ["100.64.0.0/10", "fd7a:115c:a1e0::/48"])
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

    /// Refuses sources without a name or a bundle, a name with a slash, a name used twice, more
    /// sources than a report to the coordinator names, a range with bits after its prefix, and
    /// options that need `--listen` without it.
    @Test func refusesInvalidListenerOptions() {
        let tooMany = (0 ... HostReport.maximumSources).flatMap { ["--offer", "s\($0)=/vms/s\($0)"] }
        let invalid: [[String]] = [
            ["--listen", "192.0.2.20", "--coordinator", "hub"] + tooMany,
            ["--offer", "base=/vms/base"],
            ["--host-name", "lab"],
            ["--allow-from", "192.0.2.0/24"],
            ["--coordinator", "hub"],
            ["--listen", "192.0.2.20", "--allow-from", "192.0.2.20/24"],
            ["--listen", "192.0.2.20", "--allow-from", "lab.local"],
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
                "--host-name", "lab", "--offer", "base=vms/base", "--allow-from", "2001:db8::/32",
                "--coordinator", "hub",
            ]) as? DaemonInstallCommand,
        )
        let base = FileManager.default.currentDirectoryPath + "/vms/base"
        let agent = install.agent(running: URL(filePath: "/opt/macpool"))
        #expect(agent.slots == 1)
        #expect(agent.peerArguments == [
            "--listen=[2001:db8::20]:7480", "--host-name=lab", "--offer=base=\(base)", "--allow-from=2001:db8::/32",
            "--coordinator=hub",
        ])
        let run = try #require(try Macpool.parseAsRoot(["daemon", "run"] + agent.peerArguments) as? DaemonRunCommand)
        #expect(run.listening.settings?.address == "2001:db8::20")
        #expect(run.listening.settings?.port == 7480)
        #expect(run.listening.settings?.name == "lab")
        #expect(run.listening.offeredSources == ["base": base])
        #expect(run.listening.settings?.allowedSources == install.listening.allowedSources)
        #expect(run.listening.settings?.coordinator == "hub")

        let local = try #require(try Macpool.parseAsRoot(["daemon", "install"]) as? DaemonInstallCommand)
        #expect(local.agent(running: URL(filePath: "/opt/macpool")).peerArguments.isEmpty)
    }

    /// Passes a host name and a source name that start with a dash to `daemon run` as values.
    @Test func passesValuesThatStartWithADash() throws {
        let install = try #require(
            try Macpool.parseAsRoot([
                "daemon", "install", "--listen", "192.0.2.20", "--host-name=-lab", "--offer=-base=/vms/base",
            ]) as? DaemonInstallCommand,
        )
        let arguments = install.agent(running: URL(filePath: "/opt/macpool")).peerArguments
        let run = try #require(try Macpool.parseAsRoot(["daemon", "run"] + arguments) as? DaemonRunCommand)
        #expect(run.listening.settings?.name == "-lab")
        #expect(run.listening.offeredSources == ["-base": "/vms/base"])
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
        let restricted = PoolSummary(
            slots: 2,
            leases: [],
            queue: [],
            listener: ListenerSummary(
                address: "192.0.2.20",
                port: 7373,
                problem: nil,
                allowedSources: ["192.0.2.0/24", "fd7a:115c:a1e0::/48"],
            ),
        )
        #expect(LeaseOutput.table(restricted).suffix(2) == [
            "listening for paired Macs on 192.0.2.20:7373",
            "allowing connections only from 192.0.2.0/24, fd7a:115c:a1e0::/48",
        ])
    }

    /// Prints a table of the hosts that report to the daemon as their coordinator.
    @Test func printsTheHosts() throws {
        let key = try #require(KeyFingerprint(String(repeating: "ab", count: 32)))
        let report = HostReport(
            address: "2001:db8::30",
            port: 7373,
            slots: 2,
            leases: 1,
            queued: 0,
            available: 1,
            sources: ["base", "xcode"],
        )
        let idle = HostReport(
            address: "192.0.2.31",
            port: 7480,
            slots: 1,
            leases: 0,
            queued: 0,
            available: 1,
            sources: [],
        )
        let pool = PoolSummary(slots: 1, leases: [], queue: [], hosts: [
            HostSummary(name: "mini", key: key, report: report, reportAge: 4),
            HostSummary(name: "attic", key: key, report: idle, reportAge: 12),
        ])
        let host = PeerText.name("mini", key: key)
        let other = PeerText.name("attic", key: key)
        #expect(Array(LeaseOutput.table(pool).dropFirst()) == [
            "HOST\(pad("HOST", other))  ADDRESS              AVAILABLE  SLOTS  LEASES  QUEUED  REPORTED  SOURCES",
            "\(host)\(pad(host, other))  [2001:db8::30]:7373  1          2      1       0       4s ago    base, xcode",
            "\(other)  192.0.2.31:7480      1          1      0       0       12s ago   -",
        ])
        // A paired coordinator's text passes through PeerText.escaped, which must not escape the
        // isolates around the host's name a second time.
        #expect(LeaseOutput.table(pool, shown: PeerText.escaped).last
            == "\(other)  192.0.2.31:7480      1          1      0       0       12s ago   -")
    }
}

/// Returns the spaces that pad a cell to the width of a longer one in the table of `list`.
///
/// - Parameters:
///   - cell: The shorter cell.
///   - widest: The longest cell of the column.
/// - Returns: The spaces.
private func pad(_ cell: String, _ widest: String) -> String {
    let width = { (text: String) in text.count { $0 != PeerText.isolateStart && $0 != PeerText.isolateEnd } }
    return String(repeating: " ", count: max(0, width(widest) - width(cell)))
}
