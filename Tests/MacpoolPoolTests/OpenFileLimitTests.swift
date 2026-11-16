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

    /// Writes the raised soft limit once with the old hard limit and returns the limit that it
    /// reads back. It writes nothing when the soft limit is high enough, returns the old limit
    /// after a refused write, and returns `nil` when it cannot read.
    @Test func raisesTheLimitThroughItsCalls() {
        let unlimited = Self.unlimited
        var limits = rlimit(rlim_cur: 256, rlim_max: unlimited)
        var writes: [rlimit] = []
        var acceptsWrites = true
        let raise = { (perProcess: rlim_t) in
            OpenFileLimit.raise(perProcess: perProcess, read: { limits }, write: { wanted in
                writes.append(wanted)
                if acceptsWrites {
                    limits = wanted
                }
            })
        }

        #expect(raise(245_760) == 4096)
        #expect(writes.map(\.rlim_cur) == [4096])
        #expect(writes.map(\.rlim_max) == [unlimited])
        #expect(limits.rlim_cur == 4096)

        writes = []
        limits = rlimit(rlim_cur: 1_048_576, rlim_max: unlimited)
        #expect(raise(245_760) == 245_760)
        #expect(writes.isEmpty)

        acceptsWrites = false
        limits = rlimit(rlim_cur: 256, rlim_max: unlimited)
        #expect(raise(245_760) == 256)
        #expect(writes.count == 1)

        writes = []
        #expect(OpenFileLimit.raise(perProcess: 245_760, read: { nil }, write: { writes.append($0) }) == nil)
        #expect(writes.isEmpty)
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
