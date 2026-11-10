import CryptoKit
import Foundation
import Security
import SwiftASN1
import Testing
import X509

/// Tests of the self-signed certificates that carry a Mac's key in TLS.
///
/// The SDK parses certificates but cannot build one, so these tests check that a certificate from
/// the certificate packages works with Security on this system.
struct SelfSignedCertificateTests {
    /// Pairs a certificate for a CryptoKit key with that key in Security and rejects another key.
    @Test func pairsCertificateWithItsKey() throws {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("macpool") }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now,
            notValidAfter: now.addingTimeInterval(3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
            },
            issuerPrivateKey: Certificate.PrivateKey(key),
        )
        #expect(certificate.publicKey.isValidSignature(certificate.signature, for: certificate))

        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let parsed = try #require(SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData))
        let publicKey = try #require(SecCertificateCopyKey(parsed))
        #expect(SecKeyCopyExternalRepresentation(publicKey, nil) as Data? == key.publicKey.x963Representation)

        #expect(try SecIdentityCreate(nil, parsed, securityKey(for: key)) != nil)
        #expect(try SecIdentityCreate(nil, parsed, securityKey(for: P256.Signing.PrivateKey())) == nil)
    }

    /// Converts a CryptoKit private key into a Security key that lives only in memory.
    ///
    /// - Parameter key: The private key.
    /// - Returns: The same key as a Security key.
    /// - Throws: An error when Security rejects the key.
    private func securityKey(for key: P256.Signing.PrivateKey) throws -> SecKey {
        let attributes = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ] as CFDictionary
        return try #require(SecKeyCreateWithData(key.x963Representation as CFData, attributes, nil))
    }
}
