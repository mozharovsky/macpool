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

    /// What the key file holds, for error messages.
    private static let keyName = "this Mac's key"

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

    /// Reads this Mac's identity, or creates the key when the data directory has neither a key
    /// nor a list of paired Macs.
    ///
    /// Processes that create the key at the same time end up with the same key, because only the
    /// first file takes the name.
    ///
    /// - Parameter directory: The data directory.
    /// - Returns: The identity.
    /// - Throws: ``PoolError/insecureDirectory(path:reason:)`` when another user could control
    ///   or read the trust directory, ``PoolError/unusableIdentity(path:reason:)`` when the key
    ///   file is not a regular file of the current user, other users can reach it, it holds no
    ///   P-256 key, or its certificate cannot be built,
    ///   ``PoolError/missingIdentity(path:lists:)`` when the key file is missing and a list of
    ///   paired Macs exists, or ``PoolError/fileSystem(operation:path:reason:)`` when a file
    ///   operation fails.
    static func loadOrCreate(in directory: PoolDirectory) throws(PoolError) -> MacIdentity {
        try directory.prepareTrustDirectory()
        let file = directory.identityFile
        if let key = try readKey(at: file) {
            return try MacIdentity(privateKey: key, file: file)
        }
        // A new key would leave every paired Mac refusing this one without saying why.
        var lists: [String] = []
        if TrustList<TrustedClient>.exists(in: directory) {
            lists.append(TrustList<TrustedClient>.file(in: directory).path(percentEncoded: false))
        }
        if TrustList<TrustedHost>.exists(in: directory) {
            lists.append(TrustList<TrustedHost>.file(in: directory).path(percentEncoded: false))
        }
        guard lists.isEmpty else {
            throw .missingIdentity(path: file.path(percentEncoded: false), lists: lists)
        }
        try PrivateFile.create(
            at: file,
            contents: Data(P256.Signing.PrivateKey().pemRepresentation.utf8),
            name: keyName,
        )
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
    /// The digest covers the SubjectPublicKeyInfo that CryptoKit encodes for the certificate's
    /// key, not the bytes in the certificate. Every certificate for one key therefore gets one
    /// digest. For the certificates that macpool builds, the two encodings are the same.
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
    /// - Parameter file: The key file.
    /// - Returns: The key, or `nil` when the file does not exist.
    /// - Throws: ``PoolError/unusableIdentity(path:reason:)`` when the file fails a check of
    ///   ``PrivateFile/read(at:name:refusal:)`` or holds no P-256 key in PEM, or
    ///   ``PoolError/fileSystem(operation:path:reason:)`` when it cannot be read.
    private static func readKey(at file: URL) throws(PoolError) -> P256.Signing.PrivateKey? {
        let path = file.path(percentEncoded: false)
        let refusal = { (reason: String) in PoolError.unusableIdentity(path: path, reason: reason) }
        guard let data = try PrivateFile.read(at: file, name: keyName, refusal: refusal) else {
            return nil
        }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: String(decoding: data, as: UTF8.self)) else {
            throw refusal("it holds no P-256 private key in PEM")
        }
        return key
    }
}
