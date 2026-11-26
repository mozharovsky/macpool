import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the order and the choices of the coordinator's queue of placements.
struct PlacementQueueTests {
    /// The time at which the tests' grants expire.
    private static let deadline = SuspendingClock().now + .seconds(5)

    /// Creates a request for the source `base`.
    ///
    /// - Parameters:
    ///   - client: The connection's number.
    ///   - priority: The request's priority.
    /// - Returns: The request.
    private static func request(_ client: UInt64, priority: Int = 0) -> PlacementQueue.Request {
        PlacementQueue.Request(
            client: ClientID(value: client),
            key: randomKey(),
            name: "mac\(client)",
            terms: LeaseTerms(source: "base", timeToLive: 60, priority: priority),
            since: Date(),
        )
    }

    /// Creates a host that offers `base`.
    ///
    /// - Parameters:
    ///   - key: The host's key, or `nil` for the coordinator's own daemon.
    ///   - available: The host's free slots.
    /// - Returns: The candidate.
    private static func host(_ key: KeyFingerprint?, available: Int) -> PlacementQueue.Candidate {
        PlacementQueue.Candidate(key: key, available: available, sources: ["base"])
    }

    /// Orders requests by priority and then by arrival.
    @Test func ordersByPriority() {
        var queue = PlacementQueue()
        #expect(queue.enqueue(Self.request(1)) == 1)
        #expect(queue.enqueue(Self.request(2)) == 2)
        #expect(queue.enqueue(Self.request(3, priority: 1)) == 1)
        #expect(queue.requests.map(\.client.value) == [3, 1, 2])
        #expect(queue.waitingPosition(of: ClientID(value: 2)) == 3)
    }

    /// Chooses the host with the most free slots, prefers its own daemon on a tie, and takes one
    /// slot per choice.
    @Test func choosesTheMostFreeSlots() {
        var queue = PlacementQueue()
        let first = Self.request(1)
        let second = Self.request(2)
        let third = Self.request(3)
        for request in [first, second, third] {
            queue.enqueue(request)
        }
        let mini = randomKey()
        let placements = queue.place(
            on: [Self.host(nil, available: 1), Self.host(mini, available: 2)],
            until: Self.deadline,
        )
        #expect(placements == [
            .remote(HostGrant(ticket: 1, client: first.key, name: "mac1", source: "base", priority: 0), host: mini),
            .local(second),
            .remote(HostGrant(ticket: 2, client: third.key, name: "mac3", source: "base", priority: 0), host: mini),
        ])
        #expect(queue.requests.map(\.grant?.ticket) == [1, 2])
    }

    /// Skips hosts without the source or a free slot and leaves the request waiting.
    @Test func waitsWithoutACandidate() {
        var queue = PlacementQueue()
        queue.enqueue(Self.request(1))
        let other = PlacementQueue.Candidate(key: randomKey(), available: 3, sources: ["other"])
        #expect(queue.place(on: [other, Self.host(randomKey(), available: 0)], until: Self.deadline).isEmpty)
        #expect(queue.waitingPosition(of: ClientID(value: 1)) == 1)
    }

    /// Offers a declined request to the same host only after the host reported again.
    @Test func skipsAHostThatDeclinedUntilItReports() {
        var queue = PlacementQueue()
        let request = Self.request(1)
        queue.enqueue(request)
        let mini = randomKey()
        _ = queue.place(on: [Self.host(mini, available: 1)], until: Self.deadline)
        #expect(queue.answer(ticket: 1, from: randomKey(), isAccepted: true) == .unknown)
        guard case .declined = queue.answer(ticket: 1, from: mini, isAccepted: false) else {
            Issue.record("the host's answer did not decline the request")
            return
        }
        #expect(queue.place(on: [Self.host(mini, available: 1)], until: Self.deadline).isEmpty)
        queue.hostReported(mini)
        let placements = queue.place(on: [Self.host(mini, available: 1)], until: Self.deadline)
        #expect(placements.count == 1)
        guard case let .accepted(accepted) = queue.answer(ticket: 2, from: mini, isAccepted: true) else {
            Issue.record("the host's answer did not accept the request")
            return
        }
        #expect(accepted.key == request.key)
        #expect(queue.requests.isEmpty)
    }

    /// Withdraws expired grants and the grants of a host that left, and removes the requests of
    /// a closed connection.
    @Test func withdrawsGrants() {
        var queue = PlacementQueue()
        queue.enqueue(Self.request(1))
        queue.enqueue(Self.request(2))
        let mini = randomKey()
        let hub = randomKey()
        _ = queue.place(on: [Self.host(mini, available: 1), Self.host(hub, available: 1)], until: Self.deadline)
        #expect(queue.expireGrants(at: Self.deadline - .seconds(1)).isEmpty)
        #expect(queue.expireGrants(at: Self.deadline).count == 2)
        #expect(queue.requests.allSatisfy { $0.grant == nil && $0.declinedBy.count == 1 })

        queue.hostReported(mini)
        queue.hostReported(hub)
        _ = queue.place(on: [Self.host(mini, available: 2)], until: Self.deadline)
        #expect(queue.hostLeft(mini).count == 2)
        #expect(queue.requests.allSatisfy { $0.grant == nil && $0.declinedBy.isEmpty })
        #expect(queue.count(of: queue.requests[0].key) == 1)
        queue.remove(client: ClientID(value: 1))
        #expect(queue.requests.map(\.client.value) == [2])
    }
}
