/// How a VM's run ended.
public enum MachineOutcome: Sendable, Equatable, Codable, CustomStringConvertible {
    /// The VM stopped because someone asked for the stop.
    case requested

    /// The guest shut itself down.
    case guestShutdown

    /// The boot or the VM failed.
    ///
    /// - Parameter reason: The failure's description.
    case failed(String)

    /// The supervisor ended without reporting an outcome, for example because it crashed.
    case lost

    /// The JSON keys of an outcome.
    private enum CodingKeys: String, CodingKey {
        /// The kind of outcome.
        case kind
        /// The failure's description.
        case reason
    }

    /// Decodes an outcome.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when the kind is unknown or a failure has no reason.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "requested":
            self = .requested
        case "guest-shutdown":
            self = .guestShutdown
        case "failed":
            self = try .failed(container.decode(String.self, forKey: .reason))
        case "lost":
            self = .lost
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown outcome \(kind)",
            )
        }
    }

    /// Encodes the outcome.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An error when the encoder rejects a value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .requested:
            try container.encode("requested", forKey: .kind)
        case .guestShutdown:
            try container.encode("guest-shutdown", forKey: .kind)
        case let .failed(reason):
            try container.encode("failed", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .lost:
            try container.encode("lost", forKey: .kind)
        }
    }

    /// A short description for lease replies and logs.
    public var description: String {
        switch self {
        case .requested:
            "the VM was stopped on request"
        case .guestShutdown:
            "the guest shut down"
        case let .failed(reason):
            reason
        case .lost:
            "the VM supervisor ended without a report"
        }
    }
}

/// The stage of a supervised VM.
public enum SupervisorPhase: String, Codable, Sendable {
    /// The supervisor boots the VM and waits for its address, SSH, and credential rotation.
    case booting

    /// The VM answers on SSH with its own credentials.
    case ready

    /// The VM stopped and the supervisor is about to exit.
    case exited
}

/// What a supervisor reports about its VM.
///
/// The supervisor sends its current status to every new connection and each later change on its
/// own line.
///
/// Every status carries the supervisor's protocol version. A supervisor keeps running while a
/// newer daemon replaces the old one, so the daemon checks the version before it trusts a status.
/// A supervisor with another version, or one whose status the daemon cannot read, is stopped by
/// signal and its lease boots again with a current supervisor.
public struct SupervisorStatus: Codable, Sendable, Equatable {
    /// The protocol version that this build's supervisors speak.
    public static let currentProtocol = 1

    /// The protocol version of the supervisor that sent the status.
    public var protocolVersion: Int

    /// The VM's stage.
    public var phase: SupervisorPhase

    /// The guest's IPv4 address once the VM is ready.
    public var address: String?

    /// How the run ended, once the phase is ``SupervisorPhase/exited``.
    public var outcome: MachineOutcome?

    /// The JSON keys of a status.
    private enum CodingKeys: String, CodingKey {
        /// The `protocol` key.
        case protocolVersion = "protocol"
        /// The `phase` key.
        case phase
        /// The `address` key.
        case address
        /// The `outcome` key.
        case outcome
    }

    /// Creates a status.
    ///
    /// - Parameters:
    ///   - phase: The VM's stage.
    ///   - address: The guest's address once the VM is ready.
    ///   - outcome: How the run ended, for the exited phase.
    ///   - protocolVersion: The sender's protocol version, which is this build's own outside of
    ///     tests.
    public init(
        phase: SupervisorPhase,
        address: String? = nil,
        outcome: MachineOutcome? = nil,
        protocolVersion: Int = currentProtocol,
    ) {
        self.protocolVersion = protocolVersion
        self.phase = phase
        self.address = address
        self.outcome = outcome
    }
}

/// A command from the daemon to a supervisor.
public struct SupervisorCommand: Codable, Sendable, Equatable {
    /// The commands that a supervisor accepts.
    public enum Kind: String, Codable, Sendable {
        /// Stops the VM at once. The daemon deletes the clone afterward, so the supervisor does not
        /// wait for the guest to shut down.
        case stop
    }

    /// The command.
    public var command: Kind

    /// Creates a command.
    ///
    /// - Parameter command: The command.
    public init(_ command: Kind) {
        self.command = command
    }
}
