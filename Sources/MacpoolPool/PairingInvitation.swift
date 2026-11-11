import CryptoKit
import Foundation
import Synchronization

/// A host's open invitation for one client Mac to pair, held only in memory.
///
/// The host keeps at most one invitation. Opening a new one closes the old one. A restart of the
/// daemon closes it too.
///
/// The invitation keeps the SHA-256 digest of its secret instead of the secret. A check compares
/// digests. Its time therefore does not depend on how many leading bytes of a guess are right.
///
/// The invitation ends when a client pairs, after ``lifetime``, after ``wrongSecretLimit`` wrong
/// secrets, or when the inviting connection closes. The listener reads it during handshakes on
/// its own queue. A lock therefore guards its state.
final class PairingInvitation: Sendable {
    /// How long an invitation stays open, in seconds.
    static let lifetime: TimeInterval = 600

    /// The number of wrong secrets that end an invitation.
    static let wrongSecretLimit = 5

    /// The state of an open invitation.
    private struct Ticket {
        /// The SHA-256 digest of the secret.
        let digest: SHA256Digest

        /// When the invitation ends unless a client pairs.
        let expiresAt: Date

        /// The wrong secrets so far.
        var wrongSecrets: Int

        /// The connection that opened the invitation.
        let inviter: ClientID
    }

    /// A new invitation.
    struct Opened {
        /// The secret that the code carries.
        let secret: [UInt8]

        /// When the invitation ends unless a client pairs.
        let expiresAt: Date

        /// The connection whose invitation the new one closed, if any.
        let replaced: ClientID?
    }

    /// The result of a pairing attempt.
    enum Redemption: Equatable {
        /// The secret was right, and the invitation ended.
        ///
        /// - Parameter inviter: The connection that opened the invitation.
        case accepted(inviter: ClientID)

        /// The secret was wrong.
        ///
        /// - Parameters:
        ///   - inviter: The connection that opened the invitation.
        ///   - remaining: The wrong secrets that the invitation still takes. At 0 it ended.
        case rejected(inviter: ClientID, remaining: Int)

        /// No invitation was open.
        case closed
    }

    /// The open invitation, or `nil` when none is open.
    private let ticket = Mutex<Ticket?>(nil)

    /// Opens an invitation and closes the one that was open.
    ///
    /// - Parameters:
    ///   - inviter: The connection that asks for the invitation.
    ///   - now: The current time.
    /// - Returns: The new invitation's secret and end.
    func open(for inviter: ClientID, at now: Date) -> Opened {
        let secret = SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }
        let expiresAt = now.addingTimeInterval(Self.lifetime)
        let replaced = ticket.withLock { ticket in
            defer {
                ticket = Ticket(
                    digest: SHA256.hash(data: secret),
                    expiresAt: expiresAt,
                    wrongSecrets: 0,
                    inviter: inviter,
                )
            }
            return ticket.map(\.inviter)
        }
        return Opened(secret: secret, expiresAt: expiresAt, replaced: replaced == inviter ? nil : replaced)
    }

    /// Reports whether an invitation is open.
    ///
    /// - Parameter now: The current time.
    /// - Returns: Whether an invitation is open and has not expired.
    func isOpen(at now: Date) -> Bool {
        ticket.withLock { $0.map { now < $0.expiresAt } ?? false }
    }

    /// Checks a secret against the open invitation.
    ///
    /// - Parameters:
    ///   - secret: The secret that a client sent.
    ///   - now: The current time.
    /// - Returns: The result. A right secret and the last allowed wrong one end the invitation.
    func redeem(_ secret: [UInt8], at now: Date) -> Redemption {
        let digest = SHA256.hash(data: secret)
        return ticket.withLock { ticket in
            guard let open = ticket, now < open.expiresAt else {
                return .closed
            }
            if digest == open.digest {
                ticket = nil
                return .accepted(inviter: open.inviter)
            }
            var counted = open
            counted.wrongSecrets += 1
            ticket = counted.wrongSecrets < Self.wrongSecretLimit ? counted : nil
            return .rejected(inviter: open.inviter, remaining: Self.wrongSecretLimit - counted.wrongSecrets)
        }
    }

    /// Closes the invitation of a connection.
    ///
    /// - Parameter inviter: A connection that may have opened the invitation.
    func close(for inviter: ClientID) {
        ticket.withLock { ticket in
            if ticket?.inviter == inviter {
                ticket = nil
            }
        }
    }

    /// Closes the invitation once it expired.
    ///
    /// - Parameter now: The current time.
    /// - Returns: The connection whose invitation expired, or `nil` when none did.
    func expire(at now: Date) -> ClientID? {
        ticket.withLock { ticket in
            guard let open = ticket, now >= open.expiresAt else {
                return nil
            }
            ticket = nil
            return open.inviter
        }
    }
}
