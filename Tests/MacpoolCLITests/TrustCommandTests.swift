import ArgumentParser
import Foundation
@testable import MacpoolCLI
@testable import MacpoolPool
import Testing

/// Tests of `host list`, `pool list`, and the escaping of text from other Macs.
struct TrustCommandTests {
    /// The time of every pairing in these tests, 2027-01-15T08:00:00Z.
    private static let pairedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// Escapes the scalars that act on a terminal and keeps every other scalar.
    @Test(arguments: zip(
        ["\u{1B}[31mred", "a\u{202E}b", "a\u{2028}b", "a\u{2029}b", "a\u{200B}b", "a\nb", "a\\u{1B}"],
        ["\\u{1B}[31mred", "a\\u{202E}b", "a\\u{2028}b", "a\\u{2029}b", "a\\u{200B}b", "a\\u{A}b", "a\\\\u{1B}"],
    ))
    func escapesTerminalScalars(text: String, escaped: String) {
        #expect(PeerText.escaped(text) == escaped)
    }

    /// Leaves plain text, other scripts, and emoji unchanged.
    @Test(arguments: ["runner", "Mac mini 2", "שלום", "Grüße", "📦 builds 🍎"])
    func keepsPlainText(text: String) {
        #expect(PeerText.escaped(text) == text)
    }

    /// Prints the clients with isolated names. Right-to-left letters then keep the columns in order.
    @Test func printsClientsWithIsolatedNames() throws {
        let fixture = try TrustFixture()
        let runner = try fixture.key("a")
        let hebrew = try fixture.key("b")
        try fixture.save([
            TrustedClient(key: runner, name: "runner", pairedAt: Self.pairedAt, isBlocked: false),
            TrustedClient(key: hebrew, name: "שלום", pairedAt: Self.pairedAt, isBlocked: true, priorityCeiling: 12),
        ])
        #expect(try fixture.hostList() == [
            "PAIRED                BLOCKED  CEILING  CLIENT",
            "2027-01-15T08:00:00Z  no       0        \u{2068}runner\u{2069} (\(runner.shortKey))",
            "2027-01-15T08:00:00Z  yes      12       \u{2068}שלום\u{2069} (\(hebrew.shortKey))",
        ])
    }

    /// Prints the hosts with isolated addresses and names and aligns the columns without the
    /// isolates.
    @Test func printsHostsWithIsolatedAddresses() throws {
        let fixture = try TrustFixture()
        let first = try fixture.key("c")
        let second = try fixture.key("d")
        try fixture.save([
            TrustedHost(
                key: first,
                name: "build\u{1B}[2J",
                address: "example.local",
                port: 7373,
                pairedAt: Self.pairedAt,
            ),
            TrustedHost(key: second, name: "מארח", address: "מארח.local", port: 80, pairedAt: Self.pairedAt),
        ])
        #expect(try fixture.poolList() == [
            "PAIRED                ADDRESS        PORT  HOST",
            "2027-01-15T08:00:00Z  \u{2068}example.local\u{2069}  7373  "
                + "\u{2068}build\\u{1B}[2J\u{2069} (\(first.shortKey))",
            "2027-01-15T08:00:00Z  \u{2068}מארח.local\u{2069}     80    \u{2068}מארח\u{2069} (\(second.shortKey))",
        ])
    }

    /// Tells apart two names that differ only in trailing spaces.
    @Test func showsWhereANameEnds() throws {
        let fixture = try TrustFixture()
        let first = try fixture.key("1")
        let second = try fixture.key("2")
        try fixture.save([
            TrustedClient(key: first, name: "runner", pairedAt: Self.pairedAt, isBlocked: false),
            TrustedClient(key: second, name: "runner  ", pairedAt: Self.pairedAt, isBlocked: false),
        ])
        let lines = try fixture.hostList()
        #expect(lines.count == 3)
        #expect(lines[1].hasSuffix("\u{2068}runner\u{2069} (\(first.shortKey))"))
        #expect(lines[2].hasSuffix("\u{2068}runner  \u{2069} (\(second.shortKey))"))
    }

    /// Prints the exact records as JSON, without isolates or escapes of its own.
    @Test func printsExactJSON() throws {
        let fixture = try TrustFixture()
        let clients = try [
            TrustedClient(key: fixture.key("e"), name: "a\u{202E}b\u{2028}", pairedAt: Self.pairedAt, isBlocked: true),
        ]
        let hosts = try [
            TrustedHost(
                key: fixture.key("f"),
                name: "שלום\u{200B}",
                address: "10.0.0.2",
                port: 7373,
                pairedAt: Self.pairedAt,
            ),
        ]
        try fixture.save(clients)
        try fixture.save(hosts)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for text in try [fixture.hostList(json: true), fixture.poolList(json: true)].map({ $0.joined() }) {
            #expect(!text.contains(PeerText.isolateStart))
            #expect(!text.contains(PeerText.isolateEnd))
            #expect(!text.contains("\\u{"))
        }
        #expect(try decoder
            .decode([TrustedClient].self, from: Data(fixture.hostList(json: true).joined().utf8)) == clients)
        #expect(try decoder.decode([TrustedHost].self, from: Data(fixture.poolList(json: true).joined().utf8)) == hosts)
    }

    /// Prints empty lists for a missing data directory and for empty files, and creates nothing.
    @Test func printsEmptyLists() throws {
        let fixture = try TrustFixture()
        let expectEmpty = {
            #expect(try fixture.hostList() == ["no paired clients"])
            #expect(try fixture.poolList() == ["no paired hosts"])
            let clients = try fixture.hostList(json: true).joined()
            let hosts = try fixture.poolList(json: true).joined()
            #expect(try JSONDecoder().decode([TrustedClient].self, from: Data(clients.utf8)).isEmpty)
            #expect(try JSONDecoder().decode([TrustedHost].self, from: Data(hosts.utf8)).isEmpty)
        }
        try expectEmpty()
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.root.path(percentEncoded: false)))
        try fixture.save([TrustedClient]())
        try fixture.save([TrustedHost]())
        try expectEmpty()
    }

    /// Reports an unreadable list with its path and the reason.
    @Test func reportsUnreadableLists() throws {
        let fixture = try TrustFixture()
        try fixture.save([TrustedClient]())
        try fixture.save([TrustedHost]())
        let clients = TrustList<TrustedClient>.file(in: fixture.directory)
        try Data("not a list".utf8).write(to: clients)
        let hosts = TrustList<TrustedHost>.file(in: fixture.directory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: hosts.path(percentEncoded: false),
        )

        let clientError = #expect(throws: CommandError.self) {
            try fixture.hostList()
        }
        #expect(clientError?.description.hasPrefix(
            "the list of paired Macs \(clients.path(percentEncoded: false)) is unusable: it holds no list",
        ) == true)
        let hostError = #expect(throws: CommandError.self) {
            try fixture.poolList()
        }
        #expect(hostError?.description == """
        the list of paired Macs \(hosts.path(percentEncoded: false)) is unusable: \
        its permissions 644 let other users in
        """)
    }
}

/// A data directory in a temporary directory that the test owns and removes.
private final class TrustFixture {
    /// The temporary directory that holds the data directory.
    private let parent: URL

    /// The data directory. It does not exist until a test saves a list.
    let directory: PoolDirectory

    /// Creates the temporary directory without the data directory.
    ///
    /// - Throws: An error when the directory cannot be created.
    init() throws {
        parent = FileManager.default.temporaryDirectory
            .appending(path: "mp-" + UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        directory = PoolDirectory(root: parent.appending(path: "pool", directoryHint: .isDirectory))
    }

    /// Removes the temporary directory.
    deinit {
        try? FileManager.default.removeItem(at: parent)
    }

    /// Returns a key whose fingerprint repeats one hexadecimal digit.
    ///
    /// - Parameter digit: The digit.
    /// - Returns: The key.
    /// - Throws: An error when the digit is not hexadecimal.
    func key(_ digit: Character) throws -> KeyFingerprint {
        try #require(KeyFingerprint(String(repeating: digit, count: 64)))
    }

    /// Replaces a list of paired Macs with the records.
    ///
    /// - Parameter records: The records in their order.
    /// - Throws: ``PoolError`` when the list cannot be written.
    func save<Record: TrustRecord>(_ records: [Record]) throws {
        var list = TrustList<Record>()
        records.forEach { list.insert($0) }
        try list.save(to: directory)
    }

    /// Parses and runs `host list` on the data directory.
    ///
    /// - Parameter json: Whether to pass `--json`.
    /// - Returns: The lines that the command prints.
    /// - Throws: ``CommandError`` when the list cannot be read.
    func hostList(json: Bool = false) throws -> [String] {
        let arguments = ["host", "list", "--data-dir", directory.root.path(percentEncoded: false)] +
            (json ? ["--json"] : [])
        return try #require(try Macpool.parseAsRoot(arguments) as? HostListCommand).lines()
    }

    /// Parses and runs `pool list` on the data directory.
    ///
    /// - Parameter json: Whether to pass `--json`.
    /// - Returns: The lines that the command prints.
    /// - Throws: ``CommandError`` when the list cannot be read.
    func poolList(json: Bool = false) throws -> [String] {
        let arguments = ["pool", "list", "--data-dir", directory.root.path(percentEncoded: false)] +
            (json ? ["--json"] : [])
        return try #require(try Macpool.parseAsRoot(arguments) as? PoolListCommand).lines()
    }
}
