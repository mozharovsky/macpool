import Foundation
import Logging
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
        let code = PairingCode(address: "example.local", port: 7373, hostKey: hostKey, secret: secret)
        let text = code.description
        #expect(text.hasPrefix("macpool1:example.local:7373:"))
        #expect(text.split(separator: ":").last?.count == 52)
        #expect(PairingCode(text) == code)
        let characters = String(text.split(separator: ":").last ?? "")
        #expect(PairingCode(" macpool1:example.local:7373:\(characters.uppercased())\n") == code)
        #expect(code.matches(hostKey))
        #expect(!code.matches(randomKey()))

        let ipv6 = PairingCode(address: "fe80::1%en0", port: 1, hostKey: hostKey, secret: secret)
        #expect(PairingCode(ipv6.description) == ipv6)
        for broken in [
            "macpool2:example.local:7373:\(characters)",
            "macpool1::7373:\(characters)",
            "macpool1:example.local:0:\(characters)",
            "macpool1:example.local:70000:\(characters)",
            "macpool1:example.local:7373:\(characters.dropLast())",
            "macpool1:example.local:7373:\(characters.dropLast())1",
            "macpool1:example.local:7373",
            "macpool1:exa\u{1B}[31mmple:7373:\(characters)",
            "macpool1:example local:7373:\(characters)",
            "macpool1:\(String(repeating: "a", count: 254)):7373:\(characters)",
        ] {
            #expect(PairingCode(broken) == nil, "\(broken)")
        }
        #expect(PairingCode.isValidAddress("192.0.2.20"))
        #expect(!PairingCode.isValidAddress("example local"))
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
            "a\u{1D159}b",
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
            "\u{1D159}",
            "\u{1D159} \u{2800}",
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
        #expect(invitation.redeem(opened.secret, at: start) == .accepted(accepted, priorityCeiling: 0))
        #expect(!invitation.isOpen(at: start))
        #expect(invitation.redeem(opened.secret, at: start) == .closed)

        let guessed = invitation.open(for: first, priorityCeiling: 5, at: start)
        for count in 1 ... 6 {
            #expect(invitation.redeem([0], at: start) == .rejected(inviter: first, wrongSecrets: count))
        }
        let guessedOnce = PairingInvitation.Ended(inviter: first, wrongSecrets: 6)
        #expect(invitation.redeem(guessed.secret, at: start) == .accepted(guessedOnce, priorityCeiling: 5))

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
        #expect(paired == PairedMac(name: "example", key: host.key))
        let clientIdentity = try MacIdentity.loadOrCreate(in: client)
        let clientKey = KeyFingerprint(digest: clientIdentity.keyDigest)
        #expect(try await next(invitation.channel) == .paired(PairedMac(name: "runner", key: clientKey)))

        let clients = try TrustList<TrustedClient>.load(from: host.fixture.directory)
        #expect(clients.records.map(\.name) == ["runner"])
        #expect(clients[clientKey]?.isBlocked == false)
        #expect(clients[clientKey]?.pairedAt == host.fixture.clock.now)
        let hosts = try TrustList<TrustedHost>.load(from: client)
        #expect(hosts.records.map { [$0.name, $0.address, "\($0.port)"] } == [["example", "127.0.0.1", "\(host.port)"]])
        #expect(hosts[host.key] != nil)
        #expect(host.fixture.logs.entries("Paired a Mac").map { $0.metadata["key"] } == [clientKey.rawValue])
        #expect(host.fixture.logs.entries("A Mac connected to pair").map(\.level) == [.debug])

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

        let second = try await host.invite(priorityCeiling: 7)
        let paired = try await PoolClient.pair(using: second.code, name: "builder", directory: client)
        #expect(paired == PairedMac(name: "example", key: host.key))
        #expect(try await next(second.channel) == .alreadyPaired(PairedMac(name: "runner", key: clientKey)))
        let clients = try TrustList<TrustedClient>.load(from: host.fixture.directory)
        #expect(clients.records.map(\.name) == ["runner"])
        #expect(clients[clientKey]?.pairedAt == pairedAt)
        #expect(clients[clientKey]?.isBlocked == false)
        #expect(clients[clientKey]?.priorityCeiling == 0)
        #expect(try TrustList<TrustedHost>.load(from: client)[host.key] != nil)
        let other = try host.clientDirectory()
        await #expect(throws: PoolError.self) {
            try await PoolClient.pair(using: second.code, name: "other", directory: other)
        }
        await host.stop()
    }

    /// Pairs a revoked Mac again with a new code after a person deleted its record. The daemon
    /// kept the Mac's block only in memory. The new pairing ends that block.
    @Test func pairsAgainAfterAnUnsavedBlock() async throws {
        let host = try await PairingHost()
        let client = try host.clientDirectory()
        let first = try await host.invite()
        _ = try await PoolClient.pair(using: first.code, name: "runner", directory: client)
        let identity = try MacIdentity.loadOrCreate(in: client)
        let clientKey = KeyFingerprint(digest: identity.keyDigest)
        let directory = host.fixture.directory
        try RevocationTests.setImmutable(true, listIn: directory)
        defer { try? RevocationTests.setImmutable(false, listIn: directory) }
        await #expect(throws: PoolError.self) {
            try await PoolClient.send(.revoke(key: clientKey.shortKey), to: directory)
        }
        #expect(await refusal { () async throws(PoolError) in
            try await PoolClient.connect(to: host.endpoint, as: identity, hostKey: host.key)
        } != nil)

        try RevocationTests.setImmutable(false, listIn: directory)
        try TrustList<TrustedClient>().save(to: directory)
        let second = try await host.invite()
        _ = try await PoolClient.pair(using: second.code, name: "runner", directory: client)
        #expect(try await next(second.channel) == .paired(PairedMac(name: "runner", key: clientKey)))
        #expect(await host.daemon.unsavedBlocks.isEmpty)
        let channel = try await PoolClient.connect(to: host.endpoint, as: identity, hostKey: host.key)
        try channel.send(PoolRequest.status)
        guard case .status = try await next(channel) else {
            Issue.record("the host did not serve the Mac that paired again")
            return
        }
        channel.close()
        await host.stop()
    }

    /// Records the priority ceiling of the code with the new client.
    @Test func recordsTheCeilingOfTheCode() async throws {
        let host = try await PairingHost()
        let client = try host.clientDirectory()
        let invitation = try await host.invite(priorityCeiling: 5)
        _ = try await PoolClient.pair(using: invitation.code, name: "runner", directory: client)
        let clientKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: client).keyDigest)
        #expect(try TrustList<TrustedClient>.load(from: host.fixture.directory)[clientKey]?.priorityCeiling == 5)
        let paired = host.fixture.logs.entries("Paired a Mac")
        #expect(paired.map { $0.metadata["priority_ceiling"] } == ["5"])
        await host.stop()
    }

    /// Refuses requests of Macs on the network without a host path while the host cannot read its
    /// list of paired clients. The inviting connection gets the reason.
    @Test func refusesWithoutPathsWhenTheListCannotBeRead() async throws {
        let host = try await PairingHost()
        let pairedDirectory = try host.clientDirectory()
        let first = try await host.invite()
        _ = try await PoolClient.pair(using: first.code, name: "runner", directory: pairedDirectory)
        let paired = try MacIdentity.loadOrCreate(in: pairedDirectory)
        let pairedChannel = try await PoolClient.connect(to: host.endpoint, as: paired, hostKey: host.key)
        let invitation = try await host.invite()
        let strangerChannel = try await PoolClient.connect(to: host.endpoint, as: makeIdentity(), hostKey: host.key)

        // Both handshakes read the list. Only the requests below find it unreadable.
        try Data("{".utf8).write(to: TrustList<TrustedClient>.file(in: host.fixture.directory))
        var replies: [PoolReply] = []
        for _ in 0 ..< 2 {
            try pairedChannel.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
            try await replies.append(next(pairedChannel))
        }
        try pairedChannel.send(PoolRequest.invite(address: "127.0.0.1"))
        try await replies.append(next(pairedChannel))
        try strangerChannel.send(PoolRequest.pair(secret: Base32.encode(invitation.code.secret), name: "stranger"))
        try await replies.append(next(strangerChannel))
        let unreadable = PoolReply.failure(
            PoolError.invalidRequest(reason: "the host cannot read its list of paired Macs").description,
        )
        // The paired connection stays open after each refusal.
        #expect(replies == [unreadable, unreadable, unreadable, .failure("the host cannot record the pairing")])
        guard case let .failure(reason) = try await next(invitation.channel) else {
            Issue.record("the inviting connection received no reason")
            return
        }
        #expect(reason.hasPrefix("the pairing failed: "))
        let root = host.fixture.root.url.path(percentEncoded: false)
        #expect(reason.contains(String(root.dropLast())))
        // A paired Mac that repeats its requests writes one error a minute.
        let levels = host.fixture.logs.entries("The list of paired clients cannot be read").map(\.level)
        #expect(levels == [.error, .debug, .debug])
        pairedChannel.close()
        strangerChannel.close()
        await host.stop()
    }

    /// Opens no invitation while the host's name for clients holds the home directory, also in
    /// capital letters, or a path that starts with `~/`. Every Mac that pairs would receive the name.
    @Test func opensNoInvitationWhileTheHostNameHoldsAPath() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let refusal = PoolError.invalidRequest(
            reason: "the host's name for clients contains a path on this Mac. Choose another name",
        )
        for name in [home, home.uppercased(), "build~/mac"] {
            let host = try await PairingHost(name: name)
            let channel = try await PoolClient.connect(to: host.fixture.directory)
            try channel.send(PoolRequest.invite(address: "127.0.0.1"))
            #expect(try await next(channel) == .failure(refusal.description), "\(name)")
            #expect(host.fixture.logs.entries("Opened an invitation").isEmpty, "\(name)")
            channel.close()
            await host.stop()
        }
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
            let hex = code.secret.map { String(format: "%02x", $0) }.joined()
            return [Base32.encode(code.secret), code.description, "\(code.secret)", hex].map { $0.lowercased() }
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
    /// silent wait, and limits how many such Macs connect at once. The warning about the limit
    /// reaches the warning level once a minute.
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

        // Filling the freed places again does not bring the warning back within a minute.
        let warnings = { host.fixture.logs.entries("Too many Macs pair at once").count { $0.level == .warning } }
        let refused = {
            await refusal { () async throws(PoolError) in
                try await PoolClient.connect(to: host.endpoint, as: extra, hostKey: host.key)
            } != nil
        }
        #expect(warnings() == 1)
        silent = []
        for _ in 0 ..< PoolDaemon.pairingConnectionLimit {
            let identity = try makeIdentity()
            #expect(await eventually {
                guard let channel = try? await PoolClient.connect(to: host.endpoint, as: identity, hostKey: host.key)
                else {
                    return false
                }
                silent.append(channel)
                return true
            })
        }
        #expect(await refused())
        #expect(warnings() == 1)
        host.fixture.clock.advance(by: PeerLogRate.interval)
        #expect(await refused())
        #expect(warnings() == 2)
        for channel in silent {
            channel.close()
        }
        await host.stop()
    }

    /// Refuses a blocked client's pairing, a pairing through the local socket, an invitation from a
    /// paired client, an invitation with a negative priority ceiling, and an invitation while the
    /// host does not listen.
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
        try local.send(PoolRequest.invite(address: "example local"))
        let address = PoolError.invalidRequest(reason: "example local is not a host name or an IP address")
        #expect(try await next(local) == .failure(address.description))
        try local.send(PoolRequest.invite(address: "127.0.0.1", priorityCeiling: -1))
        let negative = PoolError.invalidRequest(reason: "the priority ceiling must be 0 or more")
        #expect(try await next(local) == .failure(negative.description))
        local.close()
        await host.stop()

        let quiet = try PoolFixture()
        let daemon = try await quiet.start()
        await #expect(throws: PoolError.daemonRefused(message: "the host does not listen for paired Macs")) {
            try await PoolClient.send(.invite(address: "127.0.0.1"), to: quiet.directory)
        }
        await daemon.shutdown()

        let unnamed = try await PairingHost(name: "example\u{202E}")
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

    /// Refuses a host's name that fails this Mac's rule with an error that names the cause. A host
    /// on a newer macOS may send such a name after it recorded the client.
    @Test func refusesAHostNameThatThisMacDoesNotAccept() async throws {
        try await expectPairing(
            withAHostThatReplies: { .paired(PairedMac(name: "\u{3164}", key: $0)) },
            toThrow: .malformedMessage(
                reason: "the host's name has characters that macOS on this Mac does not accept. "
                    + "The host recorded this Mac. Change the host's name and pair again with a new code",
            ),
        )
    }

    /// Names only the kind of a reply that does not finish a pairing. The host chose the texts in
    /// the reply.
    @Test func namesOnlyTheKindOfAnUnexpectedReply() async throws {
        try await expectPairing(
            withAHostThatReplies: { .alreadyPaired(PairedMac(name: "\u{1B}[2J", key: $0)) },
            toThrow: .malformedMessage(reason: "the host replied to a pairing with an unexpected already_paired reply"),
        )
    }

    /// Pairs with a host that greets the client and sends one reply to the pairing. Expects the
    /// pairing to throw and the client to record no host.
    ///
    /// - Parameters:
    ///   - reply: Returns the host's reply for the host's key.
    ///   - error: The error that the pairing must throw.
    /// - Throws: An error when the host cannot listen or the client's list of hosts cannot be read.
    private func expectPairing(
        withAHostThatReplies reply: @escaping @Sendable (KeyFingerprint) -> PoolReply,
        toThrow error: PoolError,
    ) async throws {
        let host = try makeIdentity()
        let hostKey = KeyFingerprint(digest: host.keyDigest)
        let listener = try await PeerListener(identity: host, settings: loopbackSettings(), admits: { _ in true })
        defer { listener.close() }
        let fakeHost = Task {
            for await peer in listener.connections {
                try? peer.channel.send(HostGreeting(version: peer.version, role: .host))
                _ = try? await peer.channel.receive(PoolRequest.self)
                try? peer.channel.send(reply(hostKey))
                await peer.channel.finish()
            }
        }
        defer { fakeHost.cancel() }
        let root = try ShortDirectory()
        let client = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        let secret = Array(0 ..< UInt8(PairingCode.secretBytes))
        let code = PairingCode(address: "127.0.0.1", port: listener.port, hostKey: hostKey, secret: secret)
        await #expect(throws: error) {
            try await PoolClient.pair(using: code, name: "runner", directory: client)
        }
        #expect(try TrustList<TrustedHost>.load(from: client).records.isEmpty)
    }
}

/// A host daemon that listens for paired Macs on 127.0.0.1 under the name `example`.
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
    init(name: String = "example") async throws {
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
    /// - Parameter priorityCeiling: The highest priority that the Mac that pairs may ask for.
    /// - Returns: The inviting connection and the code.
    /// - Throws: An error when the daemon refuses or sends no code.
    func invite(priorityCeiling: Int = 0) async throws -> OpenInvitation {
        let channel = try await PoolClient.connect(to: fixture.directory)
        try channel.send(PoolRequest.invite(address: "127.0.0.1", priorityCeiling: priorityCeiling))
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
