import Darwin
@testable import MacpoolPool
import Testing

/// Tests of the limit of open files that the daemon raises when it starts.
struct OpenFileLimitTests {
    /// The limits before the daemon raises the soft limit and the soft limit that it sets.
    struct Case: Sendable {
        /// The soft limit before the change.
        let soft: rlim_t

        /// The hard limit.
        let hard: rlim_t

        /// The value of `kern.maxfilesperproc`.
        let perProcess: rlim_t

        /// The soft limit that the daemon sets.
        let raised: rlim_t
    }

    /// The value of `RLIM_INFINITY`, which Swift does not import.
    static let unlimited: rlim_t = (1 << 63) - 1

    /// Raises a launchd job's limit to 4096, stops at the hard limit and at the kernel's limit
    /// for one process, and never lowers a higher limit.
    @Test(arguments: [
        Case(soft: 256, hard: OpenFileLimitTests.unlimited, perProcess: 245_760, raised: 4096),
        Case(soft: 256, hard: 512, perProcess: 245_760, raised: 512),
        Case(soft: 10240, hard: OpenFileLimitTests.unlimited, perProcess: 245_760, raised: 10240),
        Case(soft: 256, hard: OpenFileLimitTests.unlimited, perProcess: 2048, raised: 2048),
    ])
    func raisesTheSoftLimit(_ limits: Case) {
        #expect(OpenFileLimit.raisedSoftLimit(
            soft: limits.soft,
            hard: limits.hard,
            perProcess: limits.perProcess,
        ) == limits.raised)
    }

    /// Refuses to listen for paired Macs below 1024 open files or when the limit is unknown.
    @Test func refusesPeersBelowTheMinimum() {
        #expect(OpenFileLimit.peerRefusal(for: 512)
            == "the daemon may open only 512 files, and the listener for paired Macs needs 1024")
        #expect(OpenFileLimit.peerRefusal(for: 1023) != nil)
        #expect(OpenFileLimit.peerRefusal(for: 1024) == nil)
        #expect(OpenFileLimit.peerRefusal(for: 4096) == nil)
        #expect(OpenFileLimit.peerRefusal(for: nil) == "the daemon cannot read its limit of open files")
    }

    /// Raises the soft limit of the test process as far as the limits allow and returns it.
    ///
    /// The limit only grows, so other tests in the process keep working.
    @Test func raisesTheLimitOfThisProcess() throws {
        var before = rlimit()
        try #require(getrlimit(RLIMIT_NOFILE, &before) == 0)
        let perProcess = OpenFileLimit.maximumPerProcess()
        let limit = try #require(OpenFileLimit.raise())
        var after = rlimit()
        try #require(getrlimit(RLIMIT_NOFILE, &after) == 0)
        #expect(after.rlim_cur == OpenFileLimit.raisedSoftLimit(
            soft: before.rlim_cur,
            hard: before.rlim_max,
            perProcess: perProcess,
        ))
        #expect(limit == min(after.rlim_cur, perProcess))
    }
}
