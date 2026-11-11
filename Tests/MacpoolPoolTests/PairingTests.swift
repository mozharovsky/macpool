import Foundation
@testable import MacpoolPool
import Network
import Testing

/// Tests of pairing codes, invitations, and the pairing of a client Mac with a host.
@Suite(.timeLimit(.minutes(1)))
struct PairingTests {
    /// Writes a code and reads it back, with an IPv6 address, uppercase letters, and spaces.
    @Test func readsAndWritesCodes() {
        let hostKey = randomKey()
        let secret = Array(0 ..< UInt8(PairingCode.secretBytes))
        let code = PairingCode(address: "studio.local", port: 7373, hostKey: hostKey, secret: secret)
        let text = code.description
        #expect(text.hasPrefix("macpool1:studio.local:7373:"))
        #expect(text.split(separator: ":").last?.count == 52)
        #expect(PairingCode(text) == code)
        let characters = String(text.split(separator: ":").last ?? "")
        #expect(PairingCode(" macpool1:studio.local:7373:\(characters.uppercased())\n") == code)
        #expect(code.matches(hostKey))
        #expect(!code.matches(randomKey()))

        let ipv6 = PairingCode(address: "fe80::1%en0", port: 1, hostKey: hostKey, secret: secret)
        #expect(PairingCode(ipv6.description) == ipv6)
        for broken in [
            "macpool2:studio.local:7373:\(characters)",
            "macpool1::7373:\(characters)",
            "macpool1:studio.local:0:\(characters)",
            "macpool1:studio.local:70000:\(characters)",
            "macpool1:studio.local:7373:\(characters.dropLast())",
            "macpool1:studio.local:7373:\(characters.dropLast())1",
            "macpool1:studio.local:7373",
            "macpool1:exa\u{1B}[31mmple:7373:\(characters)",
            "macpool1:example local:7373:\(characters)",
            "macpool1:\(String(repeating: "a", count: 254)):7373:\(characters)",
        ] {
            #expect(PairingCode(broken) == nil, "\(broken)")
        }
        #expect(PairingCode.isValidAddress("192.0.2.20"))
        #expect(!PairingCode.isValidAddress("studio local"))
        #expect(!PairingCode.isValidAddress(""))
    }

    /// Decodes what the encoder writes and rejects text that no bytes encode to.
    @Test func decodesBase32() {
        for count in 0 ... 12 {
            let bytes = (0 ..< count).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
            #expect(Base32.decode(Base32.encode(bytes)) == bytes, "\(count)")
        }
        #expect(Base32.decode("MZXW6YTBOI") == Array("foobar".utf8))
        for broken in ["m", "mzx", "mzxw6y", "mz", "mzxw6=", "mzxw0"] {
            #expect(Base32.decode(broken) == nil, "\(broken)")
        }
    }

    /// Accepts names that people can read and rejects empty, blank, long, control, format,
    /// separator, private-use, default-ignorable, and invisible text.
    @Test func checksNames() {
        let accepted = [
            "Build Mac 2",
            "Студия 🚀",
            String(repeating: "\u{E9}", count: 64),
            "e\u{301}",
            "a\u{2800}b",
        ]
        for name in accepted {
            #expect(PairedMac.isValidName(name), "\(name)")
        }
        let rejected = [
            "",
            "   ",
            "\u{3164}",
            "\u{115F}",
            "\u{1160}",
            "\u{FFA0}",
            "\u{2800}",
            "\u{2800} \u{2800}",
            "a\u{3164}b",
            "\u{301}",
            "\u{301}abc",
            "\u{34F}",
            "heart\u{2764}\u{FE0F}",
            String(repeating: "a", count: 65),
            String(repeating: "e\u{301}", count: 33),
            "line\nbreak",
            "bell\u{7}",
            "abc\u{202E}fed",
            "zero\u{200B}width",
            "line\u{2028}separator",
            "private\u{E000}",
        ]
        for name in rejected {
            #expect(!PairedMac.isValidName(name), "\(name.unicodeScalars.map(\.value))")
        }
    }

    /// Ends an invitation on the right secret, at its expiry, and when another invitation or its
    /// own connection closes it. Counts wrong secrets and stays open after them.
    @Test func endsInvitations() {
        let invitation = PairingInvitation()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ClientID(value: 1)
        let second = ClientID(value: 2)
        #expect(!invitation.isOpen(at: start))
        #expect(invitation.redeem([], at: start) == .closed)

        let opened = invitation.open(for: first, at: start)
        #expect(opened.secret.count == PairingCode.secretBytes)
        #expect(opened.expiresAt == start.addingTimeInterval(600))
        #expect(opened.replaced == nil)
        #expect(invitation.isOpen(at: start))
        let accepted = PairingInvitation.Ended(inviter: first, wrongSecrets: 0)
        #expect(invitation.redeem(opened.secret, at: start) == .accepted(accepted))
        #expect(!invitation.isOpen(at: start))
        #expect(invitation.redeem(opened.secret, at: start) == .closed)

        let guessed = invitation.open(for: first, at: start)
        for count in 1 ... 6 {
            #expect(invitation.redeem([0], at: start) == .rejected(inviter: first, wrongSecrets: count))
        }
        let guessedOnce = PairingInvitation.Ended(inviter: first, wrongSecrets: 6)
        #expect(invitation.redeem(guessed.secret, at: start) == .accepted(guessedOnce))

        let expiring = invitation.open(for: first, at: start)
        _ = invitation.redeem([0], at: start)
        #expect(invitation.expire(at: start.addingTimeInterval(599)) == nil)
        #expect(!invitation.isOpen(at: start.addingTimeInterval(600)))
        #expect(invitation.redeem(expiring.secret, at: start.addingTimeInterval(600)) == .closed)
        let expired = PairingInvitation.Ended(inviter: first, wrongSecrets: 1)
        #expect(invitation.expire(at: start.addingTimeInterval(600)) == expired)
        #expect(invitation.expire(at: start.addingTimeInterval(600)) == nil)

        _ = invitation.open(for: first, at: start)
        let replaced = PairingInvitation.Ended(inviter: first, wrongSecrets: 0)
        #expect(invitation.open(for: second, at: start).replaced == replaced)
        #expect(invitation.close(for: first) == nil)
        #expect(invitation.isOpen(at: start))
        #expect(invitation.close(for: second) == PairingInvitation.Ended(inviter: second, wrongSecrets: 0))
        #expect(!invitation.isOpen(at: start))
    }

    /// Pairs a client with a code, records each Mac in the other's list, and serves the client
    /// as a paired Mac afterwards. The code works once.
    @Test func pairsAClientOnce() async throws {
        let host = try await PairingHost()
        let invitation = try await host.invite()
        let client = try host.clientDirectory()

        let paired = try await PoolClient.pair(using: invitation.code, name: "runner", directory: client)
        #expect(paired == PairedMac(name: "studio", key: host.key))
        let clientIdentity = try MacIdentity.loadOrCreate(in: client)
        let clientKey = KeyFingerprint(digest: clientIdentity.keyDigest)
        #expect(try await next(invitation.channel) == .paired(PairedMac(name: "runner", key: clientKey)))

        let clients = try TrustList<TrustedClient>.load(from: host.fixture.directory)
        #expect(clients.records.map(\.name) == ["runner"])
        #expect(clients[clientKey]?.isBlocked == false)
        #expect(clients[clientKey]?.pairedAt == host.fixture.clock.now)
        let hosts = try TrustList<TrustedHost>.load(from: client)
        #expect(hosts.records.map { [$0.name, $0.address, "\($0.port)"] } == [["studio", "127.0.0.1", "\(host.port)"]])
        #expect(hosts[host.key] != nil)
        #expect(host.fixture.logs.entries("Paired a Mac").map { $0.metadata["key"] } == [clientKey.rawValue])

        let channel = try await PoolClient.connect(to: host.endpoint, as: clientIdentity, hostKey: host.key)
        try channel.send(PoolRequest.status)
        guard case .status = try await next(channel) else {
            Issue.record("the host did not serve the paired client")
            return
        }
        try channel.send(PoolRequest.pair(secret: Base32.encode(invitation.code.secret), name: "runner"))
        #expect(try await next(channel) == .failure("the host has no open invitation, so ask for a new code"))
        channel.close()

        let other = try host.clientDirectory()
        await #expect(throws: PoolError.connection(
            path: "127.0.0.1:\(host.port)",
            reason: "the host closed the connection, so the code was used, expired, or replaced",
        )) {
            try await PoolClient.pair(using: invitation.code, name: "thief", directory: other)
        }
        await host.stop()
    }

    /// Keeps an invitation open after wrong secrets. The inviting connection receives one notice,
    /// and the log has one warning per invitation and the count when the invitation ends.
    @Test func keepsAnInvitationAfterWrongCodes() async throws {
        let host = try await PairingHost()
        let invitation = try await host.invite()
        let wrong = PairingCode(
            address: "127.0.0.1",
            port: host.port,
            hostKey: host.key,
            secret: Array(repeating: 7, count: PairingCode.secretBytes),
        )
        for _ in 0 ..< 6 {
            let client = try host.clientDirectory()
            await #expect(throws: PoolError.daemonRefused(message: "the pairing code is wrong")) {
                try await PoolClient.pair(using: wrong, name: "guesser", directory: client)
            }
        }
        #expect(try await next(invitation.channel) == .wrongCode)
        let client = try host.clientDirectory()
        _ = try await PoolClient.pair(using: invitation.code, name: "runner", directory: client)
        let clientKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: client).keyDigest)
        #expect(try await next(invitation.channel) == .paired(PairedMac(name: "runner", key: clientKey)))
        let logs = host.fixture.logs
        #expect(logs.entries("A Mac sent a wrong pairing code").count == 1)
        #expect(logs.entries("An invitation ended after wrong pairing codes").map { $0.metadata["count"] } == ["6"])

        let later = try await host.invite()
        let guesser = try host.clientDirectory()
        await #expect(throws: PoolError.daemonRefused(message: "the pairing code is wrong")) {
            try await PoolClient.pair(using: wrong, name: "guesser", directory: guesser)
        }
        #expect(try await next(later.channel) == .wrongCode)
        #expect(logs.entries("A Mac sent a wrong pairing code").count == 2)
        later.channel.close()
        #expect(await eventually {
            logs.entries("An invitation ended after wrong pairing codes").map { $0.metadata["count"] } == ["6", "1"]
        })
        await host.stop()
    }

    /// Restores a paired client's record of the host with a new code. The host leaves its record
    /// of the client unchanged and tells the inviting connection that the client was paired.
    @Test func pairsAgainWithANewCode() async throws {
        let host = try await PairingHost()
        let client = try host.clientDirectory()
        let first = try await host.invite()
        _ = try await PoolClient.pair(using: first.code, name: "runner", directory: client)
        let pairedAt = host.fixture.clock.now
        let clientKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: client).keyDigest)
        try FileManager.default.removeItem(at: TrustList<TrustedHost>.file(in: client))
        host.fixture.clock.advance(by: 60)

        let second = try await host.invite()
        let paired = try await PoolClient.pair(using: second.code, name: "builder", directory: client)
        #expect(paired == PairedMac(name: "studio", key: host.key))
        #expect(try await next(second.channel) == .alreadyPaired(PairedMac(name: "runner", key: clientKey)))
        let clients = try TrustList<TrustedClient>.load(from: host.fixture.directory)
        #expect(clients.records.map(\.name) == ["runner"])
        #expect(clients[clientKey]?.pairedAt == pairedAt)
        #expect(clients[clientKey]?.isBlocked == false)
        #expect(try TrustList<TrustedHost>.load(from: client)[host.key] != nil)
        let other = try host.clientDirectory()
        await #expect(throws: PoolError.self) {
            try await PoolClient.pair(using: second.code, name: "other", directory: other)
        }
        await host.stop()
    }

    /// Refuses the pairing of a Mac that the host blocked after the Mac's greeting, and keeps the
    /// record blocked.
    @Test func refusesAMacBlockedAfterItsGreeting() async throws {
        let host = try await PairingHost()
        let invitation = try await host.invite()
        let stranger = try makeIdentity()
        let strangerKey = KeyFingerprint(digest: stranger.keyDigest)
        let channel = try await PoolClient.connect(to: host.endpoint, as: stranger, hostKey: host.key)
        _ = try listClients([strangerKey], in: host.fixture.directory, blocked: [strangerKey])

        try channel.send(PoolRequest.pair(secret: Base32.encode(invitation.code.secret), name: "runner"))
        #expect(try await next(channel) == .failure("the host blocked this Mac"))
        #expect(try await next(invitation.channel) == .failure("a blocked Mac used the code and ended the invitation"))
        let record = try TrustList<TrustedClient>.load(from: host.fixture.directory)[strangerKey]
        #expect(record?.isBlocked == true)
        #expect(record?.name == "client")
        channel.close()
        await host.stop()
    }

    /// Pairs exactly one of two clients that send the right secret at once.
    @Test func pairsOneOfTwoClientsWithOneCode() async throws {
        let host = try await PairingHost()
        let invitation = try await host.invite()
        let code = invitation.code
        let directories = try [host.clientDirectory(), host.clientDirectory()]
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for (index, directory) in directories.enumerated() {
                group.addTask {
                    await (try? PoolClient.pair(using: code, name: "client \(index)", directory: directory)) != nil
                }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(outcomes.count(where: \.self) == 1)
        #expect(try TrustList<TrustedClient>.load(from: host.fixture.directory).records.count == 1)
        await host.stop()
    }

    /// Writes the secret of a code to no log message and to no file of either Mac, after a
    /// pairing and after a refusal.
    @Test func keepsTheSecretOutOfLogsAndFiles() async throws {
        let host = try await PairingHost()
        let first = try await host.invite()
        let client = try host.clientDirectory()
        _ = try await PoolClient.pair(using: first.code, name: "runner", directory: client)
        let second = try await host.invite()
        let reused = PairingCode(address: "127.0.0.1", port: host.port, hostKey: host.key, secret: first.code.secret)
        let guesser = try host.clientDirectory()
        await #expect(throws: PoolError.daemonRefused(message: "the pairing code is wrong")) {
            try await PoolClient.pair(using: reused, name: "guesser", directory: guesser)
        }
        await host.stop()

        let secrets = [first.code, second.code].flatMap { code in
            [Base32.encode(code.secret), code.description].map { $0.lowercased() }
        }
        let logs = host.fixture.logs.allEntries.map { "\($0.message) \($0.metadata)".lowercased() }
        let files = [host.fixture.directory, client, guesser].flatMap(regularFileContents)
        for secret in secrets {
            #expect(!logs.contains { $0.contains(secret) })
            #expect(!files.contains { $0.contains(secret) })
        }
        #expect(!files.isEmpty)
    }

    /// Ends an invitation when it expires, when its connection closes, and when a newer one
    /// replaces it.
    @Test func endsInvitationsThatNobodyUsed() async throws {
        let host = try await PairingHost()
        let client = try host.clientDirectory()

        let expiring = try await host.invite()
        host.fixture.clock.advance(by: PairingInvitation.lifetime)
        await host.daemon.tick()
        #expect(try await next(expiring.channel) == .failure("the invitation expired"))
        await #expect(throws: PoolError.self) {
            try await PoolClient.pair(using: expiring.code, name: "runner", directory: client)
        }

        let replaced = try await host.invite()
        let newer = try await host.invite()
        #expect(try await next(replaced.channel) == .failure("a newer invitation replaced this one"))
        await #expect(throws: PoolError.daemonRefused(message: "the pairing code is wrong")) {
            try await PoolClient.pair(using: replaced.code, name: "runner", directory: client)
        }

        newer.channel.close()
        let closed = await eventually {
            do throws(PoolError) {
                _ = try await PoolClient.pair(using: newer.code, name: "runner", directory: client)
                return false
            } catch {
                return error != .daemonRefused(message: "the pairing code is wrong")
            }
        }
        #expect(closed)
        #expect(try TrustList<TrustedClient>.load(from: host.fixture.directory).records.isEmpty)
        await host.stop()
    }

    /// Lets a Mac that the host does not know send only one pairing request, refuses it after a
    /// silent wait, and limits how many such Macs connect at once.
    @Test func limitsMacsThatPair() async throws {
        let host = try await PairingHost()
        _ = try await host.invite()

        let stranger = try makeIdentity()
        let asking = try await PoolClient.connect(to: host.endpoint, as: stranger, hostKey: host.key)
        try asking.send(PoolRequest.status)
        #expect(try await next(asking) == .failure("this Mac is not paired with the host, so it can only pair"))
        #expect(try await asking.receive(PoolReply.self) == nil)

        var silent: [MessageChannel] = []
        for _ in 0 ..< PoolDaemon.pairingConnectionLimit {
            try await silent.append(PoolClient.connect(to: host.endpoint, as: makeIdentity(), hostKey: host.key))
        }
        let extra = try makeIdentity()
        #expect(await refusal { () async throws(PoolError) in
            try await PoolClient.connect(to: host.endpoint, as: extra, hostKey: host.key)
        } == "the host refused the connection: other Macs are pairing with the host, so try again shortly")
        let start = ContinuousClock.now
        for channel in silent {
            #expect(try await channel.receive(PoolReply.self) == nil)
            channel.close()
        }
        #expect(ContinuousClock.now - start >= .seconds(4))
        await host.stop()
    }

    /// Refuses a blocked client's pairing, a pairing through the local socket, an invitation from a
    /// paired client, and an invitation while the host does not listen.
    @Test func refusesInvitationsAndPairingsOutOfPlace() async throws {
        let host = try await PairingHost()
        let blocked = try host.clientDirectory()
        let blockedKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: blocked).keyDigest)
        let paired = try makeIdentity()
        let pairedKey = KeyFingerprint(digest: paired.keyDigest)
        try listClients([blockedKey, pairedKey], in: host.fixture.directory, blocked: [blockedKey])
        let invitation = try await host.invite()

        await #expect(throws: PoolError.self) {
            try await PoolClient.pair(using: invitation.code, name: "blocked", directory: blocked)
        }
        let channel = try await PoolClient.connect(to: host.endpoint, as: paired, hostKey: host.key)
        try channel.send(PoolRequest.invite(address: "127.0.0.1"))
        let remote = PoolError.invalidRequest(reason: "only the host's own user can invite Macs")
        #expect(try await next(channel) == .failure(remote.description))
        channel.close()

        let own = PoolError.invalidRequest(reason: "only another Mac can pair with the host")
        await #expect(throws: PoolError.daemonRefused(message: own.description)) {
            let request = PoolRequest.pair(secret: Base32.encode(invitation.code.secret), name: "self")
            _ = try await PoolClient.send(request, to: host.fixture.directory)
        }
        let local = try await PoolClient.connect(to: host.fixture.directory)
        try local.send(PoolRequest.invite(address: "studio local"))
        let address = PoolError.invalidRequest(reason: "studio local is not a host name or an IP address")
        #expect(try await next(local) == .failure(address.description))
        local.close()
        await host.stop()

        let quiet = try PoolFixture()
        let daemon = try await quiet.start()
        await #expect(throws: PoolError.daemonRefused(message: "the host does not listen for paired Macs")) {
            try await PoolClient.send(.invite(address: "127.0.0.1"), to: quiet.directory)
        }
        await daemon.shutdown()

        let unnamed = try await PairingHost(name: "studio\u{202E}")
        await #expect(throws: PoolError.daemonRefused(
            message: "the host's name for clients must have \(PairedMac.nameRule)",
        )) {
            try await PoolClient.send(.invite(address: "127.0.0.1"), to: unnamed.fixture.directory)
        }
        await unnamed.stop()
    }

    /// Refuses a host whose key does not match the code, before this Mac sends the secret.
    @Test func refusesAHostThatDoesNotMatchTheCode() async throws {
        let host = try await PairingHost()
        let invitation = try await host.invite()
        let forged = PairingCode(
            address: "127.0.0.1",
            port: host.port,
            hostKey: randomKey(),
            secret: invitation.code.secret,
        )
        let client = try host.clientDirectory()
        await #expect(throws: PoolError.connection(
            path: "127.0.0.1:\(host.port)",
            reason: "the host presented the key \(host.key) instead of a key that matches the code",
        )) {
            try await PoolClient.pair(using: forged, name: "runner", directory: client)
        }
        _ = try await PoolClient.pair(using: invitation.code, name: "runner", directory: client)
        await host.stop()
    }
}

/// A host daemon that listens for paired Macs on 127.0.0.1 under the name `studio`.
private final class PairingHost {
    /// The host's data directory and clock.
    let fixture: PoolFixture

    /// The host's daemon.
    let daemon: PoolDaemon

    /// The port of the listener for paired Macs.
    let port: UInt16

    /// The fingerprint of the host's key.
    let key: KeyFingerprint

    /// The directories that hold the data directories of client Macs.
    private var clientRoots: [ShortDirectory] = []

    /// Starts the daemon and waits until it listens.
    ///
    /// - Parameter name: The host's name for clients.
    /// - Throws: An error when the daemon does not start or listen.
    init(name: String = "studio") async throws {
        fixture = try PoolFixture()
        let settings = PeerSettings(name: name, address: "127.0.0.1", port: 0, retryInterval: .milliseconds(100))
        daemon = try await fixture.start(peers: settings)
        port = try await listeningPort(of: daemon)
        endpoint = try loopback(port)
        key = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: fixture.directory).keyDigest)
    }

    /// The listener's endpoint.
    let endpoint: NWEndpoint

    /// Opens an invitation through the local socket.
    ///
    /// - Returns: The inviting connection and the code.
    /// - Throws: An error when the daemon refuses or sends no code.
    func invite() async throws -> OpenInvitation {
        let channel = try await PoolClient.connect(to: fixture.directory)
        try channel.send(PoolRequest.invite(address: "127.0.0.1"))
        guard case let .invitation(code, _) = try await next(channel) else {
            throw PoolError.connectionClosed
        }
        return OpenInvitation(channel: channel, code: code)
    }

    /// Creates the data directory of a client Mac that lasts as long as the host.
    ///
    /// - Returns: The data directory. It does not exist yet.
    /// - Throws: An error when the parent directory cannot be created.
    func clientDirectory() throws -> PoolDirectory {
        let root = try ShortDirectory()
        clientRoots.append(root)
        return PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
    }

    /// Stops the daemon.
    func stop() async {
        await daemon.shutdown()
    }
}

/// Reads every regular file under a data directory.
///
/// - Parameter directory: The data directory.
/// - Returns: The contents of the files as lowercase text.
private func regularFileContents(_ directory: PoolDirectory) -> [String] {
    let files = FileManager.default.enumerator(at: directory.root, includingPropertiesForKeys: [.isRegularFileKey])
    return (files?.allObjects ?? []).compactMap { item in
        guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self).lowercased()
    }
}

/// An invitation and the local connection that keeps it open.
private struct OpenInvitation {
    /// The inviting connection.
    let channel: MessageChannel

    /// The code of the invitation.
    let code: PairingCode
}
