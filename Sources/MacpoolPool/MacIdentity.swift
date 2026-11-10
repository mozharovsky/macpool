import CryptoKit
import Foundation
import Security
import SwiftASN1
import X509

/// This Mac's P-256 key and the self-signed certificate that carries the key in TLS.
///
/// One key serves the Mac as a host and as a client. The SHA-256 digest of the key's
/// SubjectPublicKeyInfo names the Mac to its peers, so they pin the key and ignore the
/// certificate's names and dates.
///
/// Only the private key is stored, in PKCS#8 PEM in ``PoolDirectory/identityFile``. The
/// certificate is built from the key each time the identity loads.
struct MacIdentity: Sendable {
    /// The private key.
    let privateKey: P256.Signing.PrivateKey

    /// The file that holds the private key.
    let file: URL

    /// The self-signed certificate that carries the public key.
    let certificate: SecCertificate

    /// Builds the certificate for a key.
    ///
    /// - Parameters:
    ///   - privateKey: The key.
    ///   - file: The file that holds the key.
    /// - Throws: ``PoolError/unusableIdentity(path:reason:)`` when the certificate cannot be
    ///   built.
    init(privateKey: P256.Signing.PrivateKey, file: URL) throws(PoolError) {
        let path = file.path(percentEncoded: false)
        let der: [UInt8]
        do {
            let name = try DistinguishedName { CommonName("macpool") }
            let now = Date()
            // Peers check only the key, so the dates matter only to tools that show the
            // certificate.
            let certificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),
                publicKey: Certificate.PublicKey(privateKey.publicKey),
                notValidBefore: now.addingTimeInterval(-24 * 3600),
                notValidAfter: now.addingTimeInterval(365 * 24 * 3600),
                issuer: name,
                subject: name,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    Critical(KeyUsage(digitalSignature: true))
                    try ExtendedKeyUsage([.serverAuth, .clientAuth])
                },
                issuerPrivateKey: Certificate.PrivateKey(privateKey),
            )
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            der = serializer.serializedBytes
        } catch {
            throw .unusableIdentity(path: path, reason: "its certificate cannot be built: \(error)")
        }
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            throw .unusableIdentity(path: path, reason: "Security does not accept its certificate")
        }
        self.privateKey = privateKey
        self.file = file
        self.certificate = certificate
    }

    /// The SHA-256 digest of the public key's SubjectPublicKeyInfo, which names this Mac to its
    /// peers.
    var keyDigest: SHA256Digest {
        Self.keyDigest(of: privateKey.publicKey)
    }

    /// Pairs the key with the certificate for a TLS connection.
    ///
    /// The key stays in memory and never enters a keychain.
    ///
    /// - Returns: The identity that a TLS connection presents.
    /// - Throws: ``PoolError/unusableIdentity(path:reason:)`` when Security rejects the key.
    func secIdentity() throws(PoolError) -> SecIdentity {
        let attributes = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ] as CFDictionary
        guard let key = SecKeyCreateWithData(privateKey.x963Representation as CFData, attributes, nil),
              let identity = SecIdentityCreate(nil, certificate, key) else {
            throw .unusableIdentity(path: file.path(percentEncoded: false), reason: "Security rejects the key")
        }
        return identity
    }

    /// Reads this Mac's identity, or creates the key when the data directory has none.
    ///
    /// Processes that create the key at the same time end up with the same key, because only the
    /// first file takes the name.
    ///
    /// - Parameter directory: The data directory.
    /// - Returns: The identity.
    /// - Throws: ``PoolError/insecureDirectory(path:reason:)`` when another user could control
    ///   the trust directory, ``PoolError/unusableIdentity(path:reason:)`` when the key file is
    ///   not a regular file of the current user, other users can read or change it, or it holds
    ///   no P-256 key, or ``PoolError/fileSystem(operation:path:reason:)`` when a file operation
    ///   fails.
    static func loadOrCreate(in directory: PoolDirectory) throws(PoolError) -> MacIdentity {
        try directory.prepareTrustDirectory()
        let file = directory.identityFile
        if let key = try readKey(at: file) {
            return try MacIdentity(privateKey: key, file: file)
        }
        try createKey(at: file)
        guard let key = try readKey(at: file) else {
            throw .unusableIdentity(path: file.path(percentEncoded: false), reason: "it vanished after it was created")
        }
        return try MacIdentity(privateKey: key, file: file)
    }

    /// Computes the digest that names a public key.
    ///
    /// - Parameter publicKey: The key.
    /// - Returns: The SHA-256 digest of the key's SubjectPublicKeyInfo in DER.
    static func keyDigest(of publicKey: P256.Signing.PublicKey) -> SHA256Digest {
        SHA256.hash(data: publicKey.derRepresentation)
    }

    /// Computes the digest that names the key in a peer's certificate.
    ///
    /// - Parameter certificate: The peer's certificate.
    /// - Returns: The SHA-256 digest of the key's SubjectPublicKeyInfo in DER, or `nil` when the
    ///   certificate carries no P-256 key.
    static func keyDigest(of certificate: SecCertificate) -> SHA256Digest? {
        guard let key = SecCertificateCopyKey(certificate),
              let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: bytes) else {
            return nil
        }
        return keyDigest(of: publicKey)
    }

    /// Reads a private key from a file that only the current user can read.
    ///
    /// The checks run on the open file, so the file cannot change between the check and the
    /// read.
    ///
    /// - Parameter file: The key file.
    /// - Returns: The key, or `nil` when the file does not exist.
    /// - Throws: ``PoolError/unusableIdentity(path:reason:)`` when the file is a symbolic link,
    ///   not a regular file, owned by another user, open to other users, or holds no P-256 key in
    ///   PEM, or ``PoolError/fileSystem(operation:path:reason:)`` when it cannot be read.
    private static func readKey(at file: URL) throws(PoolError) -> P256.Signing.PrivateKey? {
        let path = file.path(percentEncoded: false)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT:
                return nil
            case ELOOP:
                throw .unusableIdentity(path: path, reason: "it is a symbolic link")
            default:
                throw .systemCall("opening", file)
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw .systemCall("inspecting", file)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw .unusableIdentity(path: path, reason: "it is not a regular file")
        }
        guard status.st_uid == getuid() else {
            throw .unusableIdentity(path: path, reason: "another user owns it")
        }
        guard status.st_mode & 0o077 == 0 else {
            let mode = String(status.st_mode & 0o777, radix: 8)
            throw .unusableIdentity(path: path, reason: "its permissions \(mode) let other users in")
        }
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw .fileSystem("reading this Mac's key", file, error)
        }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: String(decoding: data, as: UTF8.self)) else {
            throw .unusableIdentity(path: path, reason: "it holds no P-256 private key in PEM")
        }
        return key
    }

    /// Creates a new private key in a file that only the current user can read, unless the file
    /// already exists.
    ///
    /// The key reaches the disk under a temporary name first. A hard link then gives it the final
    /// name, which fails when another process created the file first and keeps that file.
    ///
    /// - Parameter file: The key file.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the key cannot be written
    ///   or named.
    private static func createKey(at file: URL) throws(PoolError) {
        let path = file.path(percentEncoded: false)
        let temporary = file.deletingLastPathComponent()
            .appending(path: ".\(file.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8))")
        let temporaryPath = temporary.path(percentEncoded: false)
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw .systemCall("creating", temporary)
        }
        defer { unlink(temporaryPath) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(P256.Signing.PrivateKey().pemRepresentation.utf8))
            // Without the flush a power loss can leave the named file empty.
            try handle.synchronize()
        } catch {
            throw .fileSystem("writing this Mac's key", temporary, error)
        }
        guard link(temporaryPath, path) == 0 || errno == EEXIST else {
            throw .systemCall("naming this Mac's key", file)
        }
    }
}
