public import Foundation

/// The identifier of a lease, eight lowercase hexadecimal digits.
///
/// The daemon names the lease's clone and supervisor socket after it, so the type accepts only
/// identifiers that are safe as file names.
public struct LeaseID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// The identifier's text.
    public let rawValue: String

    /// Checks an identifier's text.
    ///
    /// - Parameter rawValue: The text, such as `1a2b3c4d`.
    /// - Returns: `nil` when the text is not eight lowercase hexadecimal digits.
    public init?(_ rawValue: String) {
        guard rawValue.utf8.count == 8, rawValue.utf8.allSatisfy(Self.isLowercaseHexDigit) else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Creates a random identifier.
    ///
    /// - Returns: An identifier from 32 random bits.
    public static func random() -> LeaseID {
        // String(_:radix:) writes lowercase digits, so the padded text is always a valid identifier.
        let text = String(UInt32.random(in: .min ... .max), radix: 16)
        return LeaseID(unchecked: String(repeating: "0", count: 8 - text.count) + text)
    }

    /// Wraps text that the caller already checked.
    ///
    /// - Parameter rawValue: Eight lowercase hexadecimal digits.
    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    /// Decodes an identifier and rejects malformed text.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError.dataCorrupted` when the text is not a valid identifier.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = LeaseID(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a lease identifier: \(text)")
        }
        self = id
    }

    /// Encodes the identifier as its text.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An error when the encoder rejects the value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The identifier's text.
    public var description: String {
        rawValue
    }

    /// Orders identifiers by their text.
    ///
    /// - Parameters:
    ///   - lhs: The first identifier.
    ///   - rhs: The second identifier.
    /// - Returns: Whether the first identifier sorts before the second.
    public static func < (lhs: LeaseID, rhs: LeaseID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Reports whether a byte is an ASCII digit or a lowercase letter from `a` to `f`.
    ///
    /// - Parameter byte: The UTF-8 byte to check.
    /// - Returns: Whether the byte is a lowercase hexadecimal digit.
    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a") ... UInt8(ascii: "f"))
            .contains(byte)
    }
}

/// When the daemon boots a leased VM again after it stopped.
public enum RestartPolicy: String, Codable, Sendable, CaseIterable {
    /// Any stop ends the lease.
    case never

    /// A VM that failed to boot, stopped with an error, or lost its supervisor boots again. A
    /// shutdown from inside the guest ends the lease.
    case onFailure = "on-failure"

    /// Every stop that the lease did not ask for boots the VM again, including a shutdown from
    /// inside the guest.
    case always
}

/// What a client asks for when it requests a lease.
public struct LeaseTerms: Codable, Sendable, Equatable {
    /// The longest time to live that a lease accepts, in seconds, which is seven days.
    public static let maximumTimeToLive = 7 * 24 * 3600

    /// The longest boot timeout that a lease accepts, in seconds, which is one day.
    public static let maximumBootTimeout = 24 * 3600

    /// The stopped bundle that the daemon clones for the lease.
    ///
    /// A client on the daemon's socket sends the bundle's absolute path. A paired client sends a
    /// name that the host offers, and the daemon replaces it with that bundle's path.
    public var source: String

    /// The lease's time to live in seconds, from 1 to ``maximumTimeToLive``.
    ///
    /// The lease expires this long after its VM first becomes ready, and each renewal moves the
    /// expiry to this long after the renewal.
    public var timeToLive: Int

    /// The queue priority. Requests with a higher priority get a slot first, and requests with the
    /// same priority get one in arrival order.
    public var priority: Int

    /// When the daemon boots the VM again after it stopped.
    public var restartPolicy: RestartPolicy

    /// The absolute path of a host directory that the guest mounts, or `nil` for none.
    public var sharedDirectory: String?

    /// The longest wait for each boot's address, SSH server, and credential rotation, in seconds,
    /// from 1 to ``maximumBootTimeout``.
    public var bootTimeout: Int

    /// Whether the lease outlives the client's connection once the VM is ready.
    ///
    /// The daemon ends an attached lease when its client disconnects. It ends a detached lease
    /// only on release or expiry, and it ends both kinds when the client disconnects before the
    /// VM is first ready, because the client then never learned the lease's identifier.
    public var detached: Bool

    /// The JSON keys of the terms.
    private enum CodingKeys: String, CodingKey {
        /// The `source` key.
        case source
        /// The `ttl_seconds` key.
        case timeToLive = "ttl_seconds"
        /// The `priority` key.
        case priority
        /// The `restart` key.
        case restartPolicy = "restart"
        /// The `shared_directory` key.
        case sharedDirectory = "shared_directory"
        /// The `boot_timeout_seconds` key.
        case bootTimeout = "boot_timeout_seconds"
        /// The `detached` key.
        case detached
    }

    /// Creates terms from their values.
    ///
    /// - Parameters:
    ///   - source: The absolute path of the stopped source bundle.
    ///   - timeToLive: The time to live in seconds.
    ///   - priority: The queue priority, where higher values go first.
    ///   - restartPolicy: When the daemon boots the VM again.
    ///   - sharedDirectory: The absolute path of a host directory to share, or `nil`.
    ///   - bootTimeout: The longest wait for each boot, in seconds.
    ///   - detached: Whether the lease outlives the client's connection once it is ready.
    public init(
        source: String,
        timeToLive: Int,
        priority: Int = 0,
        restartPolicy: RestartPolicy = .onFailure,
        sharedDirectory: String? = nil,
        bootTimeout: Int = 900,
        detached: Bool = false,
    ) {
        self.source = source
        self.timeToLive = timeToLive
        self.priority = priority
        self.restartPolicy = restartPolicy
        self.sharedDirectory = sharedDirectory
        self.bootTimeout = bootTimeout
        self.detached = detached
    }

    /// Checks the ranges of the terms with the source as a path.
    ///
    /// - Throws: ``PoolError/invalidRequest(reason:)`` when a path is not absolute or a duration
    ///   is out of range.
    public func validate() throws(PoolError) {
        guard source.hasPrefix("/") else {
            throw .invalidRequest(reason: "the source \(source) is not an absolute path")
        }
        if let sharedDirectory, !sharedDirectory.hasPrefix("/") {
            throw .invalidRequest(reason: "the shared directory \(sharedDirectory) is not an absolute path")
        }
        guard (1 ... Self.maximumTimeToLive).contains(timeToLive) else {
            throw .invalidRequest(reason: "the time to live takes 1 to \(Self.maximumTimeToLive) seconds")
        }
        guard (1 ... Self.maximumBootTimeout).contains(bootTimeout) else {
            throw .invalidRequest(reason: "the boot timeout takes 1 to \(Self.maximumBootTimeout) seconds")
        }
    }
}

/// The stage of a lease that holds a slot.
public enum LeasePhase: String, Codable, Sendable {
    /// The daemon clones the source and boots the VM.
    case starting

    /// The VM answers on SSH with its own credentials.
    case ready

    /// The VM stopped and waits for its next boot under the restart policy.
    case restarting

    /// The lease ended and the daemon stops the VM and deletes the clone.
    case stopping
}

/// A lease as clients see it.
public struct LeaseSummary: Codable, Sendable, Equatable {
    /// The lease's identifier.
    public var id: LeaseID

    /// The source bundle's path.
    public var source: String

    /// The clone's bundle path, which `Scripts/ssh.sh` and `macpool ip` accept.
    public var bundle: String

    /// The lease's stage.
    public var phase: LeasePhase

    /// The guest's IPv4 address while the VM is ready, otherwise `nil`.
    public var address: String?

    /// The time at which the lease expires, or `nil` before the VM is first ready.
    public var expiresAt: Date?

    /// The number of times the daemon booted the VM again.
    public var restarts: Int

    /// Whether the lease outlives its client's connection.
    public var detached: Bool

    /// The queue priority from the request.
    public var priority: Int

    /// The JSON keys of the summary.
    private enum CodingKeys: String, CodingKey {
        /// The `id` key.
        case id
        /// The `source` key.
        case source
        /// The `bundle` key.
        case bundle
        /// The `phase` key.
        case phase
        /// The `address` key.
        case address
        /// The `expires_at` key.
        case expiresAt = "expires_at"
        /// The `restarts` key.
        case restarts
        /// The `detached` key.
        case detached
        /// The `priority` key.
        case priority
    }
}

/// A request that waits for a slot, as clients see it.
public struct QueuedSummary: Codable, Sendable, Equatable {
    /// The request's place in the queue, starting at 1.
    public var position: Int

    /// The source bundle's path.
    public var source: String

    /// The request's priority.
    public var priority: Int

    /// The time at which the request joined the queue.
    public var since: Date
}

/// The pool's slots, leases, and queue, as clients see them.
public struct PoolSummary: Codable, Sendable, Equatable {
    /// The number of VMs that the daemon runs at once.
    public var slots: Int

    /// The leases that hold a slot, ordered by identifier.
    public var leases: [LeaseSummary]

    /// The requests that wait for a slot, in the order they will get one.
    public var queue: [QueuedSummary]
}

/// A request from a client to the daemon.
///
/// Each request is one JSON object on its own line, with the kind under the `request` key.
public enum PoolRequest: Sendable, Equatable, Codable {
    /// Asks for a lease. The daemon answers with progress replies on the same connection until
    /// the lease ends or the client disconnects.
    ///
    /// - Parameter terms: The lease's terms.
    case lease(LeaseTerms)

    /// Attaches the connection to an existing lease, for example after the daemon restarted.
    ///
    /// - Parameter id: The lease's identifier.
    case attach(LeaseID)

    /// Ends a lease.
    ///
    /// - Parameter id: The lease's identifier.
    case release(LeaseID)

    /// Moves a lease's expiry to its time to live after now.
    ///
    /// - Parameter id: The lease's identifier.
    case renew(LeaseID)

    /// Asks for the pool's state.
    case status

    /// The JSON keys of a request.
    private enum CodingKeys: String, CodingKey {
        /// The kind of request.
        case request
        /// The terms of a lease request.
        case terms
        /// The lease of an attach, release, or renew request.
        case lease
    }

    /// Decodes a request.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when the kind is unknown or a field is missing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .request)
        switch kind {
        case "lease":
            self = try .lease(container.decode(LeaseTerms.self, forKey: .terms))
        case "attach":
            self = try .attach(container.decode(LeaseID.self, forKey: .lease))
        case "release":
            self = try .release(container.decode(LeaseID.self, forKey: .lease))
        case "renew":
            self = try .renew(container.decode(LeaseID.self, forKey: .lease))
        case "status":
            self = .status
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .request,
                in: container,
                debugDescription: "unknown request \(kind)",
            )
        }
    }

    /// Encodes the request.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An error when the encoder rejects a value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .lease(terms):
            try container.encode("lease", forKey: .request)
            try container.encode(terms, forKey: .terms)
        case let .attach(id):
            try container.encode("attach", forKey: .request)
            try container.encode(id, forKey: .lease)
        case let .release(id):
            try container.encode("release", forKey: .request)
            try container.encode(id, forKey: .lease)
        case let .renew(id):
            try container.encode("renew", forKey: .request)
            try container.encode(id, forKey: .lease)
        case .status:
            try container.encode("status", forKey: .request)
        }
    }
}

/// A reply from the daemon to a client.
///
/// Each reply is one JSON object on its own line, with the kind under the `reply` key.
public enum PoolReply: Sendable, Equatable, Codable {
    /// The lease request waits for a slot.
    ///
    /// - Parameter position: The request's place in the queue, starting at 1.
    case queued(position: Int)

    /// The lease holds a slot and its VM boots.
    ///
    /// - Parameter lease: The lease.
    case starting(LeaseSummary)

    /// The lease's VM is ready.
    ///
    /// - Parameter lease: The lease, with the guest's address.
    case ready(LeaseSummary)

    /// The lease's VM stopped and boots again under the restart policy.
    ///
    /// - Parameters:
    ///   - lease: The lease.
    ///   - reason: Why the VM stopped.
    case restarting(LeaseSummary, reason: String)

    /// The lease ended and its VM is stopped or stopping.
    ///
    /// - Parameters:
    ///   - id: The lease's identifier.
    ///   - reason: Why the lease ended.
    case ended(LeaseID, reason: String)

    /// The lease's expiry moved.
    ///
    /// - Parameter lease: The lease with its new expiry.
    case renewed(LeaseSummary)

    /// The daemon accepted a release.
    ///
    /// - Parameter id: The released lease's identifier.
    case released(LeaseID)

    /// The pool's state.
    ///
    /// - Parameter pool: The slots, leases, and queue.
    case status(PoolSummary)

    /// The daemon rejected the request.
    ///
    /// - Parameter message: Why the request failed.
    case failure(String)

    /// The JSON keys of a reply.
    private enum CodingKeys: String, CodingKey {
        /// The kind of reply.
        case reply
        /// The queue position.
        case position
        /// The lease summary.
        case lease
        /// The lease identifier.
        case id
        /// The reason or failure message.
        case reason
        /// The pool summary.
        case pool
    }

    /// Decodes a reply.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when the kind is unknown or a field is missing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .reply)
        switch kind {
        case "queued":
            self = try .queued(position: container.decode(Int.self, forKey: .position))
        case "starting":
            self = try .starting(container.decode(LeaseSummary.self, forKey: .lease))
        case "ready":
            self = try .ready(container.decode(LeaseSummary.self, forKey: .lease))
        case "restarting":
            self = try .restarting(
                container.decode(LeaseSummary.self, forKey: .lease),
                reason: container.decode(String.self, forKey: .reason),
            )
        case "ended":
            self = try .ended(
                container.decode(LeaseID.self, forKey: .id),
                reason: container.decode(String.self, forKey: .reason),
            )
        case "renewed":
            self = try .renewed(container.decode(LeaseSummary.self, forKey: .lease))
        case "released":
            self = try .released(container.decode(LeaseID.self, forKey: .id))
        case "status":
            self = try .status(container.decode(PoolSummary.self, forKey: .pool))
        case "failure":
            self = try .failure(container.decode(String.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .reply,
                in: container,
                debugDescription: "unknown reply \(kind)",
            )
        }
    }

    /// Encodes the reply.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An error when the encoder rejects a value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .queued(position):
            try container.encode("queued", forKey: .reply)
            try container.encode(position, forKey: .position)
        case let .starting(lease):
            try container.encode("starting", forKey: .reply)
            try container.encode(lease, forKey: .lease)
        case let .ready(lease):
            try container.encode("ready", forKey: .reply)
            try container.encode(lease, forKey: .lease)
        case let .restarting(lease, reason):
            try container.encode("restarting", forKey: .reply)
            try container.encode(lease, forKey: .lease)
            try container.encode(reason, forKey: .reason)
        case let .ended(id, reason):
            try container.encode("ended", forKey: .reply)
            try container.encode(id, forKey: .id)
            try container.encode(reason, forKey: .reason)
        case let .renewed(lease):
            try container.encode("renewed", forKey: .reply)
            try container.encode(lease, forKey: .lease)
        case let .released(id):
            try container.encode("released", forKey: .reply)
            try container.encode(id, forKey: .id)
        case let .status(pool):
            try container.encode("status", forKey: .reply)
            try container.encode(pool, forKey: .pool)
        case let .failure(message):
            try container.encode("failure", forKey: .reply)
            try container.encode(message, forKey: .reason)
        }
    }
}
