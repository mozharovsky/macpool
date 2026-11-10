import CryptoKit
import Foundation
@testable import MacpoolPool
import Security
import Subprocess
import SwiftASN1
import System
import Testing
import X509

/// Tests of this Mac's key, its certificate, and the digests that name keys.
struct MacIdentityTests {
    /// Creates the key once with permissions for the owner only and outside backups, and reads
    /// the same key back.
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
        let backup = try directory.trustDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(backup.isExcludedFromBackup == true)
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

    /// Pairs a certificate only with its own key in Security.
    @Test func pairsCertificateOnlyWithItsKey() throws {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("macpool") }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: Date(),
            notValidAfter: Date().addingTimeInterval(3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {},
            issuerPrivateKey: Certificate.PrivateKey(key),
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let parsed = try #require(SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData))
        #expect(try SecIdentityCreate(nil, parsed, Self.securityKey(for: key)) != nil)
        #expect(try SecIdentityCreate(nil, parsed, Self.securityKey(for: P256.Signing.PrivateKey())) == nil)
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

        // Opening a FIFO for reading would wait for a writer without the nonblocking flag.
        try manager.removeItem(atPath: file)
        #expect(mkfifo(file, 0o600) == 0)
        #expect(throws: refusal("it is not a regular file")) {
            try MacIdentity.loadOrCreate(in: directory)
        }
    }

    /// Refuses a key file or a trust directory with an access control list, including one that the
    /// trust directory inherits from the data directory.
    @Test func refusesAccessControlLists() async throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        _ = try MacIdentity.loadOrCreate(in: directory)
        let file = directory.identityFile.path(percentEncoded: false)
        let trust = directory.trustDirectory.pathWithoutTrailingSlash
        let reason = FileExposure.accessControlList.reason

        try await Self.changeMode("+a", "everyone allow read", file)
        #expect(throws: PoolError.unusableIdentity(path: file, reason: reason)) {
            try MacIdentity.loadOrCreate(in: directory)
        }
        try await Self.changeMode("-N", file)
        try await Self.changeMode("+a", "everyone allow list", trust)
        #expect(throws: PoolError.insecureDirectory(path: trust, reason: reason)) {
            try MacIdentity.loadOrCreate(in: directory)
        }
        try await Self.changeMode("-N", trust)
        _ = try MacIdentity.loadOrCreate(in: directory)

        let shared = PoolDirectory(root: root.url.appending(path: "shared", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(
            at: shared.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700],
        )
        let inheritable = "everyone allow read,file_inherit,directory_inherit"
        try await Self.changeMode("+a", inheritable, shared.root.pathWithoutTrailingSlash)
        let inherited = PoolError.insecureDirectory(
            path: shared.trustDirectory.pathWithoutTrailingSlash,
            reason: reason,
        )
        #expect(throws: inherited) {
            try MacIdentity.loadOrCreate(in: shared)
        }
        #expect(!FileManager.default.fileExists(atPath: shared.identityFile.path(percentEncoded: false)))
    }

    /// Refuses to keep a key on a volume that ignores ownership, where every local user acts as
    /// the owner of every file.
    @Test func refusesVolumeThatIgnoresOwnership() async throws {
        let root = try ShortDirectory()
        try await OwnerlessVolume.withVolume(in: root.url) { volume in
            let directory = PoolDirectory(root: volume.appending(path: "pool", directoryHint: .isDirectory))
            let refusal = PoolError.insecureDirectory(
                path: directory.trustDirectory.pathWithoutTrailingSlash,
                reason: FileExposure.ownerlessVolume.reason,
            )
            #expect(throws: refusal) {
                try MacIdentity.loadOrCreate(in: directory)
            }
            #expect(!FileManager.default.fileExists(atPath: directory.identityFile.path(percentEncoded: false)))

            // The key file gets the same check, which the directory check above runs first.
            let file = volume.appending(path: "identity.pem")
            #expect(FileManager.default.createFile(
                atPath: file.path(percentEncoded: false),
                contents: Data(),
                attributes: [.posixPermissions: 0o600],
            ))
            let descriptor = open(file.path(percentEncoded: false), O_RDONLY)
            defer { close(descriptor) }
            let exposure = try FileExposure.find(in: descriptor, of: file)
            #expect(exposure == .ownerlessVolume)
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

    /// Runs `chmod` for the access control list changes that Foundation does not offer.
    ///
    /// - Parameter arguments: The arguments, such as `+a`, an entry, and a path.
    /// - Throws: An error when `chmod` cannot start or fails.
    static func changeMode(_ arguments: String...) async throws {
        let result = try await run(
            .path(FilePath("/bin/chmod")),
            arguments: Arguments(arguments),
            output: .discarded,
            error: .string(limit: 1 << 16),
        )
        try #require(result.terminationStatus.isSuccess, "chmod \(arguments) failed: \(result.standardError)")
    }

    /// Converts a CryptoKit private key into a Security key that lives only in memory.
    ///
    /// - Parameter key: The private key.
    /// - Returns: The same key as a Security key.
    /// - Throws: An error when Security rejects the key.
    static func securityKey(for key: P256.Signing.PrivateKey) throws -> SecKey {
        let attributes = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ] as CFDictionary
        return try #require(SecKeyCreateWithData(key.x963Representation as CFData, attributes, nil))
    }
}

/// A small APFS disk image that a test mounts with ownership ignored, as an external volume can be.
private enum OwnerlessVolume {
    /// Mounts a new image inside a directory, runs a body with the mounted volume, and detaches the
    /// image again.
    ///
    /// - Parameters:
    ///   - directory: The directory that holds the image and its mount point.
    ///   - body: The work on the volume, which receives the volume's root.
    /// - Throws: An error when the image cannot be created or mounted, or the body's error.
    static func withVolume(in directory: URL, _ body: (URL) async throws -> Void) async throws {
        let image = directory.appending(path: "volume.dmg").path(percentEncoded: false)
        let mountPoint = directory.appending(path: "volume", directoryHint: .isDirectory)
        try await hdiutil("create", "-quiet", "-size", "20m", "-fs", "APFS", "-volname", "macpool-test", image)
        try await hdiutil(
            "attach", "-quiet", "-owners", "off", "-nobrowse",
            "-mountpoint", mountPoint.pathWithoutTrailingSlash, image,
        )
        do {
            try await body(mountPoint)
        } catch {
            try? await hdiutil("detach", "-quiet", "-force", mountPoint.pathWithoutTrailingSlash)
            throw error
        }
        try await hdiutil("detach", "-quiet", "-force", mountPoint.pathWithoutTrailingSlash)
    }

    /// Runs `hdiutil`.
    ///
    /// - Parameter arguments: The verb and its options.
    /// - Throws: An error when `hdiutil` cannot start or fails.
    private static func hdiutil(_ arguments: String...) async throws {
        let result = try await run(
            .path(FilePath("/usr/bin/hdiutil")),
            arguments: Arguments(arguments),
            output: .discarded,
            error: .string(limit: 1 << 16),
        )
        try #require(result.terminationStatus.isSuccess, "hdiutil \(arguments) failed: \(result.standardError)")
    }
}
