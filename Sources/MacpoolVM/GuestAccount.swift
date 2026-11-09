import Foundation

/// The guest administrator account that first-boot provisioning creates.
///
/// The account lives in the bundle's `guest-account.json`, which only the owner can read. The
/// password is random because every guest on the host's NAT network can reach the guest's SSH
/// port.
///
/// A clone shares the account with its source. ``VMBundle/clone(to:)`` copies the account file,
/// and the cloned disk holds the same account and the same SSH host keys. Every clone of a bundle
/// therefore accepts the same password and presents the same host key until each clone receives
/// its own.
public struct GuestAccount: Codable, Sendable, Equatable {
    /// The account's full name.
    public var fullName: String

    /// The account's short user name.
    public var username: String

    /// The account's password.
    public var password: String

    /// The JSON keys of the account file.
    private enum CodingKeys: String, CodingKey {
        /// The `full_name` key.
        case fullName = "full_name"
        /// The `username` key.
        case username
        /// The `password` key.
        case password
    }

    /// The characters of generated passwords, without look-alikes such as `0`, `O`, `1`, and `l`.
    static let passwordAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

    /// The length of generated passwords, which gives about 105 bits of entropy.
    static let passwordLength = 18

    /// Creates an account from its values.
    ///
    /// - Parameters:
    ///   - fullName: The account's full name.
    ///   - username: The account's short user name.
    ///   - password: The account's password.
    public init(fullName: String, username: String, password: String) {
        self.fullName = fullName
        self.username = username
        self.password = password
    }

    /// Reads a bundle's account and creates one with a random password on first use.
    ///
    /// - Parameter bundle: The bundle that stores the account.
    /// - Returns: The stored account.
    /// - Throws: ``MacpoolError`` when the file cannot be created, read, or decoded.
    public static func loadOrCreate(in bundle: VMBundle) throws(MacpoolError) -> GuestAccount {
        let file = bundle.guestAccountFile
        if !FileManager.default.fileExists(atPath: file.filePath) {
            var generator = SystemRandomNumberGenerator()
            let account = GuestAccount(
                fullName: "macpool",
                username: "macpool",
                password: generatePassword(using: &generator),
            )
            let data: Data
            do {
                data = try JSONEncoder().encode(account) + Data("\n".utf8)
            } catch {
                throw .invalidBundle(path: file.filePath, reason: "\(error)")
            }
            try FileSystem.createNewFile(at: file, contents: data, permissions: 0o600)
        }
        let data = try FileSystem.read(file, for: "reading the guest account")
        do {
            return try JSONDecoder().decode(GuestAccount.self, from: data)
        } catch {
            throw .invalidBundle(path: file.filePath, reason: "\(error)")
        }
    }

    /// Generates a password from ``passwordAlphabet``.
    ///
    /// - Parameter generator: The source of randomness. Production code passes the system's
    ///   cryptographically secure generator.
    /// - Returns: A password of ``passwordLength`` characters.
    static func generatePassword(using generator: inout some RandomNumberGenerator) -> String {
        var password = ""
        for _ in 0 ..< passwordLength {
            let index = Int.random(in: passwordAlphabet.indices, using: &generator)
            password.append(passwordAlphabet[index])
        }
        return password
    }
}
