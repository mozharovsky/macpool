import CryptoKit
import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the lists of paired Macs and of the short keys that people compare.
struct TrustListTests {
    /// Writes a list that only the owner can read and reads the same records back.
    @Test func savesAndLoadsAList() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        #expect(!TrustList<TrustedClient>.exists(in: directory))
        #expect(try TrustList<TrustedClient>.load(from: directory) == TrustList())

        var clients = TrustList<TrustedClient>()
        clients.insert(client("runner"))
        clients.insert(client("builder", isBlocked: true))
        try clients.save(to: directory)
        var hosts = TrustList<TrustedHost>()
        hosts.insert(TrustedHost(
            key: randomKey(),
            name: "studio",
            address: "studio.local",
            port: 7373,
            pairedAt: Date(timeIntervalSince1970: 1_800_000_000),
        ))
        try hosts.save(to: directory)

        #expect(TrustList<TrustedClient>.exists(in: directory))
        #expect(try TrustList<TrustedClient>.load(from: directory) == clients)
        #expect(try TrustList<TrustedHost>.load(from: directory) == hosts)
        let file = TrustList<TrustedClient>.file(in: directory).path(percentEncoded: false)
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: file))) as? [String: Any]
        #expect(stored?["version"] as? Int == 1)
        let first = (stored?["macs"] as? [[String: Any]])?.first
        #expect(first?["key"] as? String == clients.records.first?.key.rawValue)
        #expect(first?["blocked"] as? Bool == false)
        #expect(first?["paired_at"] as? String == "2027-01-15T08:00:00Z")
        let trust = directory.trustDirectory.path(percentEncoded: false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trust).sorted() == ["clients.json", "hosts.json"])
    }

    /// Keeps one record per key and admits only clients that are not blocked.
    @Test func keepsOneRecordPerKey() {
        var clients = TrustList<TrustedClient>()
        let runner = client("runner")
        let builder = client("builder")
        clients.insert(runner)
        clients.insert(builder)
        var blocked = runner
        blocked.isBlocked = true
        clients.insert(blocked)
        #expect(clients.records == [blocked, builder])
        #expect(clients[runner.key] == blocked)
        #expect(clients.admittedKeys == [builder.key])
    }

    /// Refuses lists that other users could read or replace, and never changes them.
    @Test func refusesUnsafeLists() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        var clients = TrustList<TrustedClient>()
        clients.insert(client("runner"))
        try clients.save(to: directory)
        let manager = FileManager.default
        let file = TrustList<TrustedClient>.file(in: directory).path(percentEncoded: false)
        let refusal = { (reason: String) in PoolError.unusableTrustList(path: file, reason: reason) }

        #expect(chmod(file, 0o644) == 0)
        #expect(throws: refusal("its permissions 644 let other users in")) {
            try TrustList<TrustedClient>.load(from: directory)
        }
        #expect(chmod(file, 0o600) == 0)

        let elsewhere = root.url.appending(path: "elsewhere.json").path(percentEncoded: false)
        try manager.moveItem(atPath: file, toPath: elsewhere)
        try manager.createSymbolicLink(atPath: file, withDestinationPath: elsewhere)
        #expect(throws: refusal("it is a symbolic link")) {
            try TrustList<TrustedClient>.load(from: directory)
        }
        try manager.removeItem(atPath: file)
        try manager.createDirectory(atPath: file, withIntermediateDirectories: false)
        #expect(throws: refusal("it is not a regular file")) {
            try TrustList<TrustedClient>.load(from: directory)
        }
        try manager.removeItem(atPath: file)
        try manager.moveItem(atPath: elsewhere, toPath: file)
        #expect(try TrustList<TrustedClient>.load(from: directory) == clients)

        let trust = directory.trustDirectory.pathWithoutTrailingSlash
        #expect(chmod(trust, 0o750) == 0)
        #expect(throws: PoolError.insecureDirectory(path: trust, reason: "its permissions 750 let other users in")) {
            try TrustList<TrustedClient>.load(from: directory)
        }
        let after = try manager.attributesOfItem(atPath: trust)[.posixPermissions] as? Int
        #expect(after == 0o750)
    }

    /// Refuses a file with another format version, a key listed twice, or contents that are no
    /// list.
    @Test func refusesUnreadableContents() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        try TrustList<TrustedClient>().save(to: directory)
        let file = TrustList<TrustedClient>.file(in: directory)
        let path = file.path(percentEncoded: false)
        let key = randomKey()
        let record = #"{"key":"\#(key)","name":"runner","paired_at":"2027-01-15T08:00:00Z","blocked":false}"#

        try Data(#"{"version":2,"macs":[]}"#.utf8).write(to: file)
        #expect(throws: PoolError.unusableTrustList(
            path: path,
            reason: "it has format version 2, and this build reads only version 1",
        )) {
            try TrustList<TrustedClient>.load(from: directory)
        }

        try Data(#"{"version":1,"macs":[\#(record)]}"#.utf8).write(to: file)
        #expect(try TrustList<TrustedClient>.load(from: directory)[key]?.name == "runner")
        try Data(#"{"version":1,"macs":[\#(record),\#(record)]}"#.utf8).write(to: file)
        #expect(throws: PoolError.unusableTrustList(path: path, reason: "it lists the key \(key) twice")) {
            try TrustList<TrustedClient>.load(from: directory)
        }

        for contents in [#"[]"#, #"{"version":1}"#, #"{"version":1,"macs":[{"key":"ABC"}]}"#] {
            try Data(contents.utf8).write(to: file)
            #expect(throws: PoolError.self, "\(contents)") {
                try TrustList<TrustedClient>.load(from: directory)
            }
        }
    }

    /// Refuses to read or write a list file larger than the limit.
    @Test func limitsTheSizeOfLists() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        try TrustList<TrustedClient>().save(to: directory)
        let file = TrustList<TrustedClient>.file(in: directory)
        let path = file.path(percentEncoded: false)
        let limit = TrustList<TrustedClient>.byteLimit
        let empty = #"{"version":1,"macs":[]}"#
        let full = empty + String(repeating: " ", count: limit - empty.utf8.count)

        try Data(full.utf8).write(to: file)
        #expect(try TrustList<TrustedClient>.load(from: directory).records.isEmpty)
        try Data((full + " ").utf8).write(to: file)
        #expect(throws: PoolError.unusableTrustList(
            path: path,
            reason: "it has more than \(limit) bytes, the most that the pool reads",
        )) {
            try TrustList<TrustedClient>.load(from: directory)
        }

        try TrustList<TrustedClient>().save(to: directory)
        var list = TrustList<TrustedClient>()
        while list.records.count < 2000 {
            list.insert(client(String(repeating: "n", count: PairedMac.maximumNameLength)))
        }
        #expect(throws: PoolError.self) {
            try list.save(to: directory)
        }
        #expect(try TrustList<TrustedClient>.load(from: directory).records.isEmpty)
    }

    /// Shows the first 80 bits of a fingerprint in base32. Logs name a paired client by the same
    /// text.
    @Test func showsAShortKey() throws {
        let key = try #require(KeyFingerprint("a0a1a2a3a4a5a6a7a8a9" + String(repeating: "f", count: 44)))
        #expect(key.shortKey == "ucq2-fi5e-uwtk-pkfj")
        #expect(LeaseOwner.client(key).description == "client ucq2-fi5e-uwtk-pkfj")
        let encoded = try JSONEncoder().encode([key])
        #expect(try JSONDecoder().decode([KeyFingerprint].self, from: encoded) == [key])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([KeyFingerprint].self, from: Data(#"["A0"]"#.utf8))
        }
    }

    /// Encodes the test vectors of RFC 4648 in lowercase and without padding.
    @Test func encodesBase32() {
        let vectors = ["": "", "f": "my", "fo": "mzxq", "foo": "mzxw6", "foob": "mzxw6yq", "fooba": "mzxw6ytb"]
        for (input, output) in vectors {
            #expect(Base32.encode(Array(input.utf8)) == output, "\(input)")
        }
        #expect(Base32.encode(Array("foobar".utf8)) == "mzxw6ytboi")
    }
}

/// Creates the record of a client with a new key.
///
/// - Parameters:
///   - name: The client's name.
///   - isBlocked: Whether the host refuses the client.
/// - Returns: The record, paired at a fixed time.
func client(_ name: String, isBlocked: Bool = false) -> TrustedClient {
    TrustedClient(
        key: randomKey(),
        name: name,
        pairedAt: Date(timeIntervalSince1970: 1_800_000_000),
        isBlocked: isBlocked,
    )
}

/// Creates the fingerprint of a new key.
///
/// - Returns: The fingerprint.
func randomKey() -> KeyFingerprint {
    KeyFingerprint(digest: MacIdentity.keyDigest(of: P256.Signing.PrivateKey().publicKey))
}
