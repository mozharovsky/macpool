import Synchronization

/// The keys of the Macs that a coordinator introduced, for the handshakes of the listener for
/// paired Macs.
///
/// A handshake runs outside the daemon's actor and reads the keys here. The daemon replaces the
/// keys after each change of its grants and leases, and it checks each Mac again after the
/// handshake.
final class IntroducedKeys: Sendable {
    /// The keys.
    private let keys = Mutex<Set<KeyFingerprint>>([])

    /// Reports whether the coordinator introduced a key.
    ///
    /// - Parameter key: The fingerprint of a Mac's key.
    /// - Returns: Whether the key is one of the introduced keys.
    func contains(_ key: KeyFingerprint) -> Bool {
        keys.withLock { $0.contains(key) }
    }

    /// Replaces the introduced keys.
    ///
    /// - Parameter newKeys: The keys of the Macs that the coordinator introduced.
    func replace(with newKeys: Set<KeyFingerprint>) {
        keys.withLock { $0 = newKeys }
    }
}
