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
/// The invitation ends when a client pairs, after ``lifetime``, or when the inviting connection
/// closes. It counts wrong secrets and stays open after them. A secret has 128 random bits. A
/// limit on wrong secrets would therefore stop no guess, and any peer could end the invitation
/// with it.
///
/// The listener reads the invitation during handshakes on its own queue. A lock therefore guards
/// its state.
final class PairingInvitation: Sendable {
    /// How long an invitation stays open, in seconds.
    static let lifetime: TimeInterval = 600

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

        /// The invitation that the new one closed, if any.
        let replaced: Ended?
    }

    /// An invitation that ended.
    struct Ended: Equatable {
        /// The connection that opened the invitation.
        let inviter: ClientID

        /// The wrong secrets that the invitation received.
        let wrongSecrets: Int
    }

    /// The result of a pairing attempt.
    enum Redemption: Equatable {
        /// The secret was right, and the invitation ended.
        ///
        /// - Parameter ended: The invitation.
        case accepted(Ended)

        /// The secret was wrong, and the invitation stays open.
        ///
        /// - Parameters:
        ///   - inviter: The connection that opened the invitation.
        ///   - wrongSecrets: The wrong secrets so far, this one included.
        case rejected(inviter: ClientID, wrongSecrets: Int)

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
            return ticket.map { Ended(inviter: $0.inviter, wrongSecrets: $0.wrongSecrets) }
        }
        return Opened(secret: secret, expiresAt: expiresAt, replaced: replaced)
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
    /// - Returns: The result. Only a right secret ends the invitation.
    func redeem(_ secret: [UInt8], at now: Date) -> Redemption {
        let digest = SHA256.hash(data: secret)
        return ticket.withLock { ticket in
            guard let open = ticket, now < open.expiresAt else {
                return .closed
            }
            if digest == open.digest {
                ticket = nil
                return .accepted(Ended(inviter: open.inviter, wrongSecrets: open.wrongSecrets))
            }
            ticket?.wrongSecrets += 1
            return .rejected(inviter: open.inviter, wrongSecrets: open.wrongSecrets + 1)
        }
    }

    /// Closes the invitation of a connection.
    ///
    /// - Parameter inviter: A connection that may have opened the invitation.
    /// - Returns: The invitation, or `nil` when the connection had none open.
    func close(for inviter: ClientID) -> Ended? {
        ticket.withLock { ticket in
            guard let open = ticket, open.inviter == inviter else {
                return nil
            }
            ticket = nil
            return Ended(inviter: open.inviter, wrongSecrets: open.wrongSecrets)
        }
    }

    /// Closes the invitation once it expired.
    ///
    /// - Parameter now: The current time.
    /// - Returns: The invitation that expired, or `nil` when none did.
    func expire(at now: Date) -> Ended? {
        ticket.withLock { ticket in
            guard let open = ticket, now >= open.expiresAt else {
                return nil
            }
            ticket = nil
            return Ended(inviter: open.inviter, wrongSecrets: open.wrongSecrets)
        }
    }
}
