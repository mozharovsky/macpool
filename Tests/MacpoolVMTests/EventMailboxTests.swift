@testable import MacpoolVM
import Testing

/// Tests of event delivery between the VM delegate and one waiting task.
struct EventMailboxTests {
    /// Returns buffered events in arrival order without waiting.
    @Test func returnsBufferedEventsInOrder() async throws {
        let mailbox = EventMailbox()
        mailbox.post(.networkDisconnected(description: "first"))
        mailbox.post(.guestStopped)
        #expect(try await mailbox.next(within: .zero) == .networkDisconnected(description: "first"))
        #expect(try await mailbox.next(within: .seconds(5)) == .guestStopped)
        #expect(try await mailbox.next(within: .zero) == nil)
    }

    /// Ends a wait with no event once its timeout elapses.
    @Test func timesOutWithoutEvent() async throws {
        let mailbox = EventMailbox()
        let clock = ContinuousClock()
        let started = clock.now
        #expect(try await mailbox.next(within: .milliseconds(100)) == nil)
        #expect(clock.now - started >= .milliseconds(100))
    }

    /// Wakes a waiting task when an event arrives before the timeout.
    @Test(.timeLimit(.minutes(1)))
    func deliversEventToWaitingTask() async throws {
        let mailbox = EventMailbox()
        let waiter = Task { try await mailbox.next(within: .seconds(30)) }
        await Self.waitForWaiter(in: mailbox)
        mailbox.post(.guestStopped)
        #expect(try await waiter.value == .guestStopped)
        #expect(try await mailbox.next(within: .zero) == nil)
    }

    /// Rejects a second waiting task while the first still waits.
    @Test(.timeLimit(.minutes(1)))
    func rejectsConcurrentWait() async throws {
        let mailbox = EventMailbox()
        let first = Task { try await mailbox.next(within: .seconds(30)) }
        await Self.waitForWaiter(in: mailbox)
        await #expect(throws: MacpoolError.eventWaitInProgress) {
            try await mailbox.next(within: .seconds(1))
        }
        mailbox.post(.guestStopped)
        #expect(try await first.value == .guestStopped)
    }

    /// Ends a wait at once when its task is cancelled, long before the timeout.
    @Test(.timeLimit(.minutes(1)))
    func endsWaitOnCancellation() async throws {
        let mailbox = EventMailbox()
        let waiter = Task { try await mailbox.next(within: .seconds(3600)) }
        await Self.waitForWaiter(in: mailbox)
        waiter.cancel()
        #expect(try await waiter.value == nil)
        #expect(!mailbox.hasWaiter)
        mailbox.post(.guestStopped)
        #expect(try await mailbox.next(within: .zero) == .guestStopped)
    }

    /// Returns without waiting when the task is already cancelled, but still hands out buffered events.
    @Test(.timeLimit(.minutes(1)))
    func skipsWaitForCancelledTask() async throws {
        let mailbox = EventMailbox()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let empty = try await mailbox.next(within: .seconds(3600))
            mailbox.post(.guestStopped)
            let buffered = try await mailbox.next(within: .seconds(3600))
            return [empty, buffered]
        }
        #expect(try await task.value == [nil, .guestStopped])
    }

    /// Keeps an event that arrives after a wait expired for the next wait.
    @Test func buffersEventAfterExpiredWait() async throws {
        let mailbox = EventMailbox()
        #expect(try await mailbox.next(within: .milliseconds(20)) == nil)
        mailbox.post(.stoppedWithError(description: "late"))
        #expect(try await mailbox.next(within: .zero) == .stoppedWithError(description: "late"))
    }

    /// Suspends until a task waits in the mailbox.
    ///
    /// - Parameter mailbox: The mailbox to watch.
    static func waitForWaiter(in mailbox: EventMailbox) async {
        while !mailbox.hasWaiter {
            await Task.yield()
        }
    }
}
