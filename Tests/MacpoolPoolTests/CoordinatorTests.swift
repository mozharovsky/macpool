import Foundation
import Logging
@testable import MacpoolPool
import Testing

/// Tests of hosts that report to a coordinator.
@Suite(.timeLimit(.minutes(1)))
struct CoordinatorTests {
    /// A report that fits a host with two slots and one source.
    static let report = HostReport(
        address: "192.0.2.10",
        port: 7373,
        slots: 2,
        leases: 1,
        queued: 0,
        available: 1,
        sources: ["base"],
    )

    /// Shows the last report of each host to local and paired clients until the host's
    /// connection closes.
    @Test func showsTheReportsOfHosts() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let hostOwner = try LeaseLedgerTests.paired("a")
        guard case let .client(hostKey) = hostOwner else {
            return
        }
        let host = try await pool.pairedClient(of: daemon, owner: hostOwner, mayHost: true, name: "mini")
        try host.send(PoolRequest.report(Self.report))
        var newer = Self.report
        newer.available = 0
        try host.send(PoolRequest.report(newer))
        #expect(await eventually { await daemon.summary().hosts.map(\.report) == [newer] })
        pool.clock.advance(by: 4)

        let expected = HostSummary(name: "mini", key: hostKey, report: newer, reportAge: 4)
        #expect(await daemon.summary().hosts == [expected])
        let client = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("b"))
        try client.send(PoolRequest.status)
        guard case let .status(summary) = try await next(client) else {
            Issue.record("the coordinator did not answer with its status")
            return
        }
        #expect(summary.hosts == [expected])
        #expect(pool.logs.entries("A host reports to this coordinator").count == 1)

        host.close()
        #expect(await eventually { await daemon.summary().hosts.isEmpty })
        #expect(pool.logs.entries("A host stopped reporting to this coordinator").count == 1)
        client.close()
        await daemon.shutdown()
    }

    /// Refuses reports from the local user, from a paired Mac without the host right, and
    /// reports whose counts do not fit.
    @Test func refusesReportsOutOfPlace() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let refusal = ClientRightsTests.refusal(
            "this Mac may not report as a host. Pair it with a code from macpool host invite --may-host",
        )

        let local = try await PoolClient.connect(to: pool.directory)
        try local.send(PoolRequest.report(Self.report))
        #expect(try await next(local) == .failure(refusal))
        let client = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("b"))
        try client.send(PoolRequest.report(Self.report))
        #expect(try await next(client) == .failure(refusal))

        let host = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("a"), mayHost: true)
        var overfull = Self.report
        overfull.available = 3
        try host.send(PoolRequest.report(overfull))
        let counts = ClientRightsTests.refusal("the report's counts of slots and leases do not fit together")
        #expect(try await next(host) == .failure(counts))
        var unnamed = Self.report
        unnamed.sources = ["a/b"]
        try host.send(PoolRequest.report(unnamed))
        #expect(try await next(host) == .failure(ClientRightsTests.refusal("a source name in the report is not valid")))
        #expect(await daemon.summary().hosts.isEmpty)
        local.close()
        client.close()
        host.close()
        await daemon.shutdown()
    }

    /// Pairs a host with a coordinator through a code with the host right. The host's daemon then
    /// connects to the coordinator and reports its listener, slots, and sources.
    @Test func reportsToTheCoordinator() async throws {
        let coordinator = try await PairingHost(name: "coordinator")
        let invitation = try await coordinator.invite(mayHost: true)
        let pool = try PoolFixture()
        _ = try await PoolClient.pair(using: invitation.code, name: "mini", directory: pool.directory)
        let hostKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: pool.directory).keyDigest)
        var settings = loopbackSettings()
        settings.coordinator = "coordinator"
        let host = try await pool.start(slots: 2, offeredSources: ["base": pool.source], peers: settings)
        let port = try await listeningPort(of: host)

        let expected = HostReport(
            address: "127.0.0.1",
            port: port,
            slots: 2,
            leases: 0,
            queued: 0,
            available: 2,
            sources: ["base"],
        )
        #expect(await eventually {
            await coordinator.daemon.summary().hosts.map(\.report) == [expected]
        })
        #expect(await coordinator.daemon.summary().hosts.map(\.key) == [hostKey])
        #expect(pool.logs.entries("Connected to the coordinator").count == 1)

        await coordinator.stop()
        #expect(await eventually { !pool.logs.entries("The daemon lost its connection to the coordinator").isEmpty })
        await host.shutdown()
    }

    /// Keeps reporting to nobody while the list of paired hosts has no such coordinator, and logs
    /// the repeated reason once at the notice level.
    @Test func logsAMissingCoordinatorOnce() async throws {
        let pool = try PoolFixture()
        var settings = loopbackSettings()
        settings.coordinator = "missing"
        let host = try await pool.start(peers: settings)
        #expect(await eventually { pool.logs.entries("The daemon cannot reach its coordinator").count >= 2 })
        let levels = pool.logs.entries("The daemon cannot reach its coordinator").map(\.level)
        #expect(levels.first == .notice)
        #expect(levels.dropFirst().allSatisfy { $0 == .debug })
        await host.shutdown()
    }

    /// Checks the rules of a report.
    @Test func validatesReports() throws {
        try Self.report.validate()
        var report = Self.report
        report.port = 0
        #expect(throws: PoolError.self) { try report.validate() }
        report = Self.report
        report.address = "example host"
        #expect(throws: PoolError.self) { try report.validate() }
        report = Self.report
        report.leases = -1
        #expect(throws: PoolError.self) { try report.validate() }
        report = Self.report
        report.sources = ["base", "base"]
        #expect(throws: PoolError.self) { try report.validate() }
        report = Self.report
        report.sources = (0 ... HostReport.maximumSources).map { "source\($0)" }
        #expect(throws: PoolError.self) { try report.validate() }
    }
}
