import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the launchd job description.
struct LaunchAgentTests {
    /// Runs the daemon for the data directory, restarts it, and leaves supervisors to themselves.
    @Test func describesDaemonJob() throws {
        let agent = LaunchAgent(
            executable: URL(filePath: "/opt/macpool/bin/macpool"),
            directory: PoolDirectory(root: URL(filePath: "/Users/me/pool")),
            slots: 1,
        )
        let data = try agent.propertyList()
        let job = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        )
        #expect(job["Label"] as? String == "macpool.daemon")
        #expect(job["ProgramArguments"] as? [String] == [
            "/opt/macpool/bin/macpool", "daemon", "run", "--data-dir", "/Users/me/pool",
            "--slots", "1", "--log-level", "info",
        ])
        #expect(job["RunAtLoad"] as? Bool == true)
        #expect(job["KeepAlive"] as? Bool == true)
        #expect(job["AbandonProcessGroup"] as? Bool == true)
        #expect(job["StandardOutPath"] as? String == "/Users/me/pool/logs/daemon.log")
        #expect(job["StandardErrorPath"] as? String == "/Users/me/pool/logs/daemon.log")
        #expect(LaunchAgent.propertyListFile.path(percentEncoded: false)
            .hasSuffix("/Library/LaunchAgents/macpool.daemon.plist"))
    }
}
