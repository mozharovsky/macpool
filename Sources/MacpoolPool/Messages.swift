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

    /// Whether the guest can only read the shared directory.
    ///
    /// The value matters only with a ``sharedDirectory``.
    public var sharedDirectoryIsReadOnly: Bool

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
        /// The `shared_directory` key. It holds the path of a writable share.
        case sharedDirectory = "shared_directory"
        /// The `read_only_shared_directory` key. It holds the path of a read-only share.
        ///
        /// If a daemon from before read-only shares receives this key, it ignores the key and
        /// boots the guest without a share. A flag beside `shared_directory` would instead make
        /// that daemon share the directory writable.
        case readOnlySharedDirectory = "read_only_shared_directory"
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
    ///   - sharedDirectoryIsReadOnly: Whether the guest can only read the shared directory.
    ///   - bootTimeout: The longest wait for each boot, in seconds.
    ///   - detached: Whether the lease outlives the client's connection once it is ready.
    public init(
        source: String,
        timeToLive: Int,
        priority: Int = 0,
        restartPolicy: RestartPolicy = .onFailure,
        sharedDirectory: String? = nil,
        sharedDirectoryIsReadOnly: Bool = false,
        bootTimeout: Int = 900,
        detached: Bool = false,
    ) {
        self.source = source
        self.timeToLive = timeToLive
        self.priority = priority
        self.restartPolicy = restartPolicy
        self.sharedDirectory = sharedDirectory
        self.sharedDirectoryIsReadOnly = sharedDirectoryIsReadOnly
        self.bootTimeout = bootTimeout
        self.detached = detached
    }

    /// Decodes terms and reads the shared directory from whichever of its two keys is present.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when a value is missing or malformed, or when both shared
    ///   directory keys are present.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        timeToLive = try container.decode(Int.self, forKey: .timeToLive)
        priority = try container.decode(Int.self, forKey: .priority)
        restartPolicy = try container.decode(RestartPolicy.self, forKey: .restartPolicy)
        bootTimeout = try container.decode(Int.self, forKey: .bootTimeout)
        detached = try container.decode(Bool.self, forKey: .detached)
        let writable = try container.decodeIfPresent(String.self, forKey: .sharedDirectory)
        let readOnly = try container.decodeIfPresent(String.self, forKey: .readOnlySharedDirectory)
        guard writable == nil || readOnly == nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .readOnlySharedDirectory,
                in: container,
                debugDescription: "The terms name both a writable and a read-only shared directory.",
            )
        }
        sharedDirectory = readOnly ?? writable
        sharedDirectoryIsReadOnly = readOnly != nil
    }

    /// Encodes the terms with the shared directory under the key for its access.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: `EncodingError` when the encoder rejects a value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(timeToLive, forKey: .timeToLive)
        try container.encode(priority, forKey: .priority)
        try container.encode(restartPolicy, forKey: .restartPolicy)
        try container.encode(bootTimeout, forKey: .bootTimeout)
        try container.encode(detached, forKey: .detached)
        try container.encodeIfPresent(
            sharedDirectory,
            forKey: sharedDirectoryIsReadOnly ? .readOnlySharedDirectory : .sharedDirectory,
        )
    }

    /// Checks the ranges of the terms with the source as a path.
    ///
    /// - Throws: ``PoolError/invalidRequest(reason:)`` when a path is not absolute, the shared
    ///   directory is read-only without a path, or a duration is out of range.
    public func validate() throws(PoolError) {
        guard source.hasPrefix("/") else {
            throw .invalidRequest(reason: "the source \(source) is not an absolute path")
        }
        guard sharedDirectory != nil || !sharedDirectoryIsReadOnly else {
            throw .invalidRequest(reason: "a read-only share needs a shared directory")
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

/// An image in the data directory, as clients see it.
public struct ImageSummary: Codable, Sendable, Equatable {
    /// The image's directory name.
    public var name: String

    /// The image's bundle path. Pass it to `lease --from`.
    public var path: String

    /// Whether the daemon leases clones of the image.
    public var isReady: Bool

    /// The build of each piece of software in the image, keyed by a name such as `xcode`.
    public var builds: [String: String]

    /// Why the image record cannot be read, or `nil` if it can.
    public var problem: String?

    /// Creates a summary.
    ///
    /// - Parameters:
    ///   - name: The image's directory name.
    ///   - path: The image's bundle path.
    ///   - isReady: Whether the daemon leases clones of the image.
    ///   - builds: The build of each piece of software in the image.
    ///   - problem: Why the image record cannot be read.
    public init(name: String, path: String, isReady: Bool, builds: [String: String] = [:], problem: String? = nil) {
        self.name = name
        self.path = path
        self.isReady = isReady
        self.builds = builds
        self.problem = problem
    }

    /// The JSON keys of the summary.
    private enum CodingKeys: String, CodingKey {
        /// The `name` key.
        case name
        /// The `path` key.
        case path
        /// The `ready` key.
        case isReady = "ready"
        /// The `builds` key.
        case builds
        /// The `problem` key.
        case problem
    }
}

/// The pool's slots, leases, queue, and images, as clients see them.
public struct PoolSummary: Codable, Sendable, Equatable {
    /// The number of VMs that the daemon runs at once.
    public var slots: Int

    /// The leases that hold a slot, ordered by identifier.
    public var leases: [LeaseSummary]

    /// The requests that wait for a slot, in the order they will get one.
    public var queue: [QueuedSummary]

    /// The images in the data directory, ordered by name.
    ///
    /// Only clients on this Mac receive images. A paired Mac receives an empty array.
    public var images: [ImageSummary]

    /// Creates a summary.
    ///
    /// - Parameters:
    ///   - slots: The number of VMs that the daemon runs at once.
    ///   - leases: The leases that hold a slot.
    ///   - queue: The requests that wait for a slot.
    ///   - images: The images in the data directory.
    public init(slots: Int, leases: [LeaseSummary], queue: [QueuedSummary], images: [ImageSummary] = []) {
        self.slots = slots
        self.leases = leases
        self.queue = queue
        self.images = images
    }

    /// Decodes a summary and treats a missing `images` key as no images.
    ///
    /// A daemon from before images existed sends no such key.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: `DecodingError` when a key is missing or holds a value of the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slots = try container.decode(Int.self, forKey: .slots)
        leases = try container.decode([LeaseSummary].self, forKey: .leases)
        queue = try container.decode([QueuedSummary].self, forKey: .queue)
        images = try container.decodeIfPresent([ImageSummary].self, forKey: .images) ?? []
    }

    /// The JSON keys of the summary.
    private enum CodingKeys: String, CodingKey {
        /// The `slots` key.
        case slots
        /// The `leases` key.
        case leases
        /// The `queue` key.
        case queue
        /// The `images` key.
        case images
    }
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

/// What the daemon on the other end of a connection between Macs is.
enum PeerRole: String, Codable, Sendable {
    /// A daemon that leases its VMs to paired Macs.
    case host
}

/// The line that a host sends first on a connection from another Mac, before any request.
///
/// A client in TLS 1.3 finishes its handshake before the host checks the client's key, so a
/// refused client also sees a ready connection. The greeting tells the client that the host
/// admitted it. The line has the form of a reply of the kind `hello`. ``PoolReply`` does not
/// decode this kind.
struct HostGreeting: Codable, Sendable, Equatable {
    /// The version of the application protocol that ALPN chose.
    var version: Int

    /// What the daemon is.
    var role: PeerRole

    /// The JSON keys of a greeting.
    private enum CodingKeys: String, CodingKey {
        /// The kind of message. A greeting always has `hello`.
        case reply
        /// The protocol version.
        case version
        /// The daemon's role.
        case role
    }

    /// The kind of message under the `reply` key.
    private static let kind = "hello"

    /// Creates a greeting.
    ///
    /// - Parameters:
    ///   - version: The protocol version.
    ///   - role: What the daemon is.
    init(version: Int, role: PeerRole) {
        self.version = version
        self.role = role
    }

    /// Decodes a greeting.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when the line is another kind of message or a field is missing.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .reply)
        guard kind == Self.kind else {
            throw DecodingError.dataCorruptedError(
                forKey: .reply,
                in: container,
                debugDescription: "expected a greeting, not \(kind)",
            )
        }
        version = try container.decode(Int.self, forKey: .version)
        role = try container.decode(PeerRole.self, forKey: .role)
    }

    /// Encodes the greeting.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An error when the encoder rejects a value.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.kind, forKey: .reply)
        try container.encode(version, forKey: .version)
        try container.encode(role, forKey: .role)
    }
}

/// The first line that a client receives from a host.
///
/// If the host admits the client, it sends a ``HostGreeting``. If it refuses the connection after
/// the handshake, it sends a failure reply with the reason and closes the connection.
enum HostOpening: Decodable, Sendable, Equatable {
    /// The host admitted the client.
    ///
    /// - Parameter greeting: The host's greeting.
    case greeting(HostGreeting)

    /// The host refused the connection.
    ///
    /// - Parameter reason: The host's description of the refusal.
    case refusal(String)

    /// The JSON keys that tell a refusal from a greeting.
    private enum CodingKeys: String, CodingKey {
        /// The kind of message.
        case reply
        /// The reason of a refusal.
        case reason
    }

    /// Decodes a greeting or a refusal.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when the line is neither a greeting nor a failure reply.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .reply) == "failure" {
            self = try .refusal(container.decode(String.self, forKey: .reason))
        } else {
            self = try .greeting(HostGreeting(from: decoder))
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
