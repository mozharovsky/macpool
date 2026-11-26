import Foundation

/// The lease requests that a coordinator places on the hosts that report to it.
///
/// Requests wait in order of priority, and requests of equal priority wait in arrival order. A
/// request has at most one open grant at a time. ``place(on:until:)`` chooses a host for each
/// request without an open grant and prefers the host with the most available slots.
///
/// A host that declines a request, or does not answer before the grant's deadline, gets the
/// request again only after its next report. The coordinator removes a Mac's requests when the
/// Mac's connection closes.
struct PlacementQueue {
    /// The most requests that one Mac may have in the queue.
    static let maximumRequestsPerMac = 8

    /// A lease request that waits for a host.
    struct Request: Equatable {
        /// The connection that sent the request and receives the answer.
        let client: ClientID

        /// The fingerprint of the requesting Mac's key.
        let key: KeyFingerprint

        /// The Mac's name in the coordinator's list of paired clients.
        let name: String

        /// The requested terms, with the source's offered name.
        let terms: LeaseTerms

        /// When the request joined the queue.
        let since: Date

        /// The hosts that declined the request since their last report.
        var declinedBy: Set<KeyFingerprint> = []

        /// The grant that waits for a host's answer.
        var grant: OpenGrant?
    }

    /// A grant that waits for a host's answer.
    struct OpenGrant: Equatable {
        /// The number by which the host's answer names the grant.
        let ticket: UInt64

        /// The fingerprint of the host's key.
        let host: KeyFingerprint

        /// The time after which the coordinator stops waiting for the answer.
        let deadline: SuspendingClock.Instant
    }

    /// A host that may take leases, as the queue sees it.
    struct Candidate: Equatable {
        /// The fingerprint of the host's key, or `nil` for the coordinator's own daemon.
        let key: KeyFingerprint?

        /// The number of leases that the host can start now.
        var available: Int

        /// The names of the sources that the host offers.
        let sources: Set<String>
    }

    /// The host that ``place(on:until:)`` chose for a request.
    enum Placement: Equatable {
        /// The coordinator's own daemon serves the request, which left the queue.
        case local(Request)

        /// The queue sent a grant to a host and waits for its answer.
        case remote(HostGrant, host: KeyFingerprint)
    }

    /// The outcome of a host's answer to a grant.
    enum Answer: Equatable {
        /// The host accepted the grant, and the request left the queue.
        case accepted(Request)

        /// The host declined the grant, and the request waits for another host.
        case declined(Request)

        /// No request has an open grant with the ticket for that host.
        case unknown
    }

    /// The waiting requests in the order in which they get a host.
    private(set) var requests: [Request] = []

    /// The ticket of the next grant.
    private var nextTicket: UInt64 = 1

    /// Adds a request behind the requests of the same or a higher priority.
    ///
    /// - Parameter request: The request.
    /// - Returns: The request's place in the queue, starting at 1.
    @discardableResult
    mutating func enqueue(_ request: Request) -> Int {
        let index = requests.firstIndex { $0.terms.priority < request.terms.priority } ?? requests.endIndex
        requests.insert(request, at: index)
        return index + 1
    }

    /// Returns the place of a waiting request without an open grant.
    ///
    /// - Parameter client: The connection that sent the request.
    /// - Returns: The place, starting at 1, or `nil` when no such request waits without a grant.
    func waitingPosition(of client: ClientID) -> Int? {
        requests.firstIndex { $0.client == client && $0.grant == nil }.map { $0 + 1 }
    }

    /// Counts the waiting requests of a Mac.
    ///
    /// - Parameter key: The fingerprint of the Mac's key.
    /// - Returns: The number of the Mac's requests in the queue.
    func count(of key: KeyFingerprint) -> Int {
        requests.count(where: { $0.key == key })
    }

    /// Chooses a host for each request without an open grant.
    ///
    /// A host may take a request when it offers the request's source, has an available slot, and
    /// has not declined the request since its last report. Among those hosts the queue takes the
    /// one with the most available slots. On a tie it takes the coordinator's own daemon, and
    /// then the host that comes first in `candidates`. Each choice takes one slot from the host
    /// for the rest of the call.
    ///
    /// - Parameters:
    ///   - candidates: The hosts that reported recently, and the coordinator's own daemon.
    ///   - deadline: The time after which a new grant expires without an answer.
    /// - Returns: The choices in queue order.
    mutating func place(on candidates: [Candidate], until deadline: SuspendingClock.Instant) -> [Placement] {
        var hosts = candidates
        var placements: [Placement] = []
        var index = requests.startIndex
        while index < requests.endIndex {
            let request = requests[index]
            guard request.grant == nil, let chosen = choose(for: request, among: hosts) else {
                index += 1
                continue
            }
            hosts[chosen].available -= 1
            guard let host = hosts[chosen].key else {
                requests.remove(at: index)
                placements.append(.local(request))
                continue
            }
            let ticket = nextTicket
            nextTicket += 1
            requests[index].grant = OpenGrant(ticket: ticket, host: host, deadline: deadline)
            let grant = HostGrant(
                ticket: ticket,
                client: request.key,
                name: request.name,
                source: request.terms.source,
                priority: request.terms.priority,
            )
            placements.append(.remote(grant, host: host))
            index += 1
        }
        return placements
    }

    /// Applies a host's answer to a grant.
    ///
    /// - Parameters:
    ///   - ticket: The grant's ticket.
    ///   - host: The fingerprint of the key of the host that answered.
    ///   - isAccepted: Whether the host accepted the grant.
    /// - Returns: What happened to the request.
    mutating func answer(ticket: UInt64, from host: KeyFingerprint, isAccepted: Bool) -> Answer {
        guard let index = requests.firstIndex(where: { $0.grant?.ticket == ticket && $0.grant?.host == host }) else {
            return .unknown
        }
        guard !isAccepted else {
            return .accepted(requests.remove(at: index))
        }
        requests[index].grant = nil
        requests[index].declinedBy.insert(host)
        return .declined(requests[index])
    }

    /// Treats every grant whose deadline passed as declined.
    ///
    /// - Parameter awake: The current time on the clock of ``OpenGrant/deadline``.
    /// - Returns: The requests whose grants expired.
    mutating func expireGrants(at awake: SuspendingClock.Instant) -> [Request] {
        var expired: [Request] = []
        for index in requests.indices {
            guard let grant = requests[index].grant, grant.deadline <= awake else {
                continue
            }
            requests[index].grant = nil
            requests[index].declinedBy.insert(grant.host)
            expired.append(requests[index])
        }
        return expired
    }

    /// Lets a host that reported again take the requests that it declined.
    ///
    /// - Parameter host: The fingerprint of the host's key.
    mutating func hostReported(_ host: KeyFingerprint) {
        for index in requests.indices {
            requests[index].declinedBy.remove(host)
        }
    }

    /// Withdraws the open grants to a host whose connection closed.
    ///
    /// - Parameter host: The fingerprint of the host's key.
    /// - Returns: The requests that lost their grant.
    mutating func hostLeft(_ host: KeyFingerprint) -> [Request] {
        var withdrawn: [Request] = []
        for index in requests.indices where requests[index].grant?.host == host {
            requests[index].grant = nil
            withdrawn.append(requests[index])
        }
        return withdrawn
    }

    /// Removes the requests of a connection that closed.
    ///
    /// - Parameter client: The connection.
    mutating func remove(client: ClientID) {
        requests.removeAll { $0.client == client }
    }

    /// Returns the index of the candidate that takes a request.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - candidates: The hosts with the slots that this call of ``place(on:until:)`` left.
    /// - Returns: The candidate's index, or `nil` when no candidate may take the request.
    private func choose(for request: Request, among candidates: [Candidate]) -> Int? {
        var best: Int?
        for (index, candidate) in candidates.enumerated() {
            guard candidate.available > 0, candidate.sources.contains(request.terms.source) else {
                continue
            }
            if let key = candidate.key, request.declinedBy.contains(key) {
                continue
            }
            guard let current = best else {
                best = index
                continue
            }
            let other = candidates[current]
            if candidate.available > other.available || (candidate.available == other.available
                && candidate.key == nil && other.key != nil) {
                best = index
            }
        }
        return best
    }
}
