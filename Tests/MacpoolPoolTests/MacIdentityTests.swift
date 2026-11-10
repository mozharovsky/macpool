import CryptoKit
import Foundation
@testable import MacpoolPool
import Security
import SwiftASN1
import Testing
import X509

/// Tests of this Mac's key, its certificate, and the digests that name keys.
struct MacIdentityTests {
    /// Creates the key once with permissions for the owner only and reads the same key back.
    @Test func createsKeyOnceAndReadsItBack() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        let created = try MacIdentity.loadOrCreate(in: directory)
        let trust = directory.trustDirectory.path(percentEncoded: false)
        #expect(chmod(trust, 0o755) == 0)
        let read = try MacIdentity.loadOrCreate(in: directory)
        #expect(read.keyDigest == created.keyDigest)
        #expect(read.privateKey.rawRepresentation == created.privateKey.rawRepresentation)

        let manager = FileManager.default
        let file = directory.identityFile.path(percentEncoded: false)
        #expect(try manager.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
        #expect(try manager.attributesOfItem(atPath: trust)[.posixPermissions] as? Int == 0o700)
        #expect(try manager.contentsOfDirectory(atPath: trust) == ["identity.pem"])
        #expect(try String(contentsOfFile: file, encoding: .utf8).hasPrefix("-----BEGIN PRIVATE KEY-----\n"))
    }

    /// Leaves processes that create the key at the same time with one shared key.
    @Test func createsOneKeyForConcurrentCallers() async throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        let digests = try await withThrowingTaskGroup(of: SHA256Digest.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    try MacIdentity.loadOrCreate(in: directory).keyDigest
                }
            }
            var digests: Set<SHA256Digest> = []
            for try await digest in group {
                digests.insert(digest)
            }
            return digests
        }
        #expect(digests.count == 1)
        let trust = directory.trustDirectory.path(percentEncoded: false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trust) == ["identity.pem"])
    }

    /// Carries the key in a signed certificate that Security pairs with the key.
    @Test func certificateCarriesTheKey() throws {
        let root = try ShortDirectory()
        let identity = try MacIdentity.loadOrCreate(in: PoolDirectory(root: root.url))
        #expect(MacIdentity.keyDigest(of: identity.certificate) == identity.keyDigest)

        let parsed = try Certificate(identity.certificate)
        #expect(parsed.publicKey.isValidSignature(parsed.signature, for: parsed))
        var serializer = DER.Serializer()
        try serializer.serialize(parsed.publicKey)
        #expect(SHA256.hash(data: serializer.serializedBytes) == identity.keyDigest)

        let secIdentity = try identity.secIdentity()
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(secIdentity, &certificate) == errSecSuccess)
        let presented = try #require(certificate)
        #expect(SecCertificateCopyData(presented) as Data == SecCertificateCopyData(identity.certificate) as Data)
        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(secIdentity, &key) == errSecSuccess)
        let bytes = try #require(key.flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? })
        #expect(bytes == identity.privateKey.x963Representation)
    }

    /// Names no key in a peer certificate whose key is not a P-256 key.
    @Test func namesOnlyP256Keys() throws {
        let key = P384.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("other") }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: Date(),
            notValidAfter: Date().addingTimeInterval(3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA384,
            extensions: Certificate.Extensions {},
            issuerPrivateKey: Certificate.PrivateKey(key),
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let parsed = try #require(SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData))
        #expect(MacIdentity.keyDigest(of: parsed) == nil)
    }

    /// Refuses key files that other users could read or replace and files without a key, and
    /// never replaces them.
    @Test func refusesUnsafeKeyFiles() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        _ = try MacIdentity.loadOrCreate(in: directory)
        let manager = FileManager.default
        let file = directory.identityFile.path(percentEncoded: false)
        let refusal = { (reason: String) in PoolError.unusableIdentity(path: file, reason: reason) }

        #expect(chmod(file, 0o640) == 0)
        #expect(throws: refusal("its permissions 640 let other users in")) {
            try MacIdentity.loadOrCreate(in: directory)
        }

        let elsewhere = root.url.appending(path: "elsewhere.pem").path(percentEncoded: false)
        #expect(chmod(file, 0o600) == 0)
        try manager.moveItem(atPath: file, toPath: elsewhere)
        try manager.createSymbolicLink(atPath: file, withDestinationPath: elsewhere)
        #expect(throws: refusal("it is a symbolic link")) {
            try MacIdentity.loadOrCreate(in: directory)
        }

        try manager.removeItem(atPath: file)
        let text = Data("not a key\n".utf8)
        #expect(manager.createFile(atPath: file, contents: text, attributes: [.posixPermissions: 0o600]))
        #expect(throws: refusal("it holds no P-256 private key in PEM")) {
            try MacIdentity.loadOrCreate(in: directory)
        }
        #expect(try Data(contentsOf: directory.identityFile) == text)

        try manager.removeItem(atPath: file)
        try manager.createDirectory(atPath: file, withIntermediateDirectories: false)
        #expect(throws: refusal("it is not a regular file")) {
            try MacIdentity.loadOrCreate(in: directory)
        }
    }

    /// Refuses a trust directory that is a symbolic link and leaves the link's target alone.
    @Test func refusesLinkedTrustDirectory() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        let elsewhere = root.url.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: elsewhere,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755],
        )
        try FileManager.default.createDirectory(at: directory.root, withIntermediateDirectories: false)
        // A trailing slash would make the link's own path refer to its target.
        let link = String(directory.trustDirectory.path(percentEncoded: false).dropLast())
        let target = elsewhere.path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect {
            try MacIdentity.loadOrCreate(in: directory)
        } throws: { error in
            if case let .insecureDirectory(_, reason) = error as? PoolError {
                reason == "it is not a directory"
            } else {
                false
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target).isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? Int == 0o755)
    }
}
