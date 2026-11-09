public import Foundation

/// The guest administrator account that first-boot provisioning creates.
///
/// The account lives in the bundle's `guest-account.json`, which only the owner can read. The
/// password is random because every guest on the host's NAT network can reach the guest's SSH
/// port.
///
/// A clone starts with its source's account file, because its disk holds the same account. The
/// clone's first run replaces the password through ``CredentialRotation``, which writes the new
/// account here once the guest accepts it.
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
            try FileSystem.createNewFile(at: file, contents: account.encoded(for: file), permissions: 0o600)
        }
        return try load(from: file)
    }

    /// Reads an account file.
    ///
    /// - Parameter file: The account file, such as ``VMBundle/guestAccountFile``.
    /// - Returns: The stored account.
    /// - Throws: ``MacpoolError`` when the file cannot be read or decoded.
    public static func load(from file: URL) throws(MacpoolError) -> GuestAccount {
        let data = try FileSystem.read(file, for: "reading the guest account")
        do {
            return try JSONDecoder().decode(GuestAccount.self, from: data)
        } catch {
            throw .invalidBundle(path: file.filePath, reason: "\(error)")
        }
    }

    /// Replaces an account file atomically with owner-only permissions.
    ///
    /// - Parameter file: The account file to replace or create.
    /// - Throws: ``MacpoolError`` when the account cannot be encoded or the file cannot be written.
    public func write(to file: URL) throws(MacpoolError) {
        try FileSystem.replacePrivateFile(at: file, contents: encoded(for: file), for: "writing the guest account")
    }

    /// Returns the same account with a new random password.
    ///
    /// - Returns: An account with the same names and a password from the system's
    ///   cryptographically secure generator.
    public func withNewPassword() -> GuestAccount {
        var generator = SystemRandomNumberGenerator()
        var account = self
        account.password = Self.generatePassword(using: &generator)
        return account
    }

    /// Encodes the account as the JSON of an account file.
    ///
    /// - Parameter file: The file the data is meant for, for error messages.
    /// - Returns: The JSON with a final line break.
    /// - Throws: ``MacpoolError/invalidBundle(path:reason:)`` when encoding fails.
    private func encoded(for file: URL) throws(MacpoolError) -> Data {
        do {
            return try JSONEncoder().encode(self) + Data("\n".utf8)
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
