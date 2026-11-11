import Foundation
import Logging
@testable import MacpoolPool
import MacpoolVM
import Testing

/// Tests of the limits of paired clients and of the host paths in their replies.
@Suite(.timeLimit(.minutes(1)))
struct ClientRightsTests {
    /// Lets a paired client ask for priorities up to the ceiling in its record. The daemon reads
    /// the record again for every lease request.
    @Test func capsPrioritiesAtTheCeiling() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let owner = try LeaseLedgerTests.paired("a")
        let remote = try await pool.pairedClient(of: daemon, owner: owner, priorityCeiling: 5)
        let terms = { (priority: Int) in
            LeaseTerms(source: "base", timeToLive: 60, priority: priority, detached: true)
        }

        try remote.send(PoolRequest.lease(terms(6)))
        #expect(try await next(remote) == .failure(Self.refusal("this Mac may ask for a priority of at most 5")))
        try remote.send(PoolRequest.lease(terms(5)))
        #expect(try await next(remote).lease?.phase == .starting)
        #expect(try await next(remote).lease?.phase == .ready)

        try Self.record(owner, priorityCeiling: 0, in: pool.directory)
        try remote.send(PoolRequest.lease(terms(1)))
        #expect(try await next(remote) == .failure(Self.refusal("this Mac may ask for a priority of at most 0")))
        try Self.record(owner, priorityCeiling: 0, isBlocked: true, in: pool.directory)
        try remote.send(PoolRequest.lease(terms(0)))
        #expect(try await next(remote) == .failure(Self.refusal("the host no longer accepts this Mac")))
        try TrustList<TrustedClient>().save(to: pool.directory)
        try remote.send(PoolRequest.lease(terms(0)))
        #expect(try await next(remote) == .failure(Self.refusal("the host no longer accepts this Mac")))
        await daemon.shutdown()
    }

    /// Keeps at most as many of a paired client's requests in the queue as the host has slots.
    /// The local user has no such limit.
    @Test func limitsTheQueueOfAPairedClient() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(slots: 2, offeredSources: ["base": pool.source])
        let remote = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("a"))
        let terms = LeaseTerms(source: "base", timeToLive: 60)
        for _ in 0 ..< 2 {
            try remote.send(PoolRequest.lease(terms))
            #expect(try await next(remote).lease?.phase == .starting)
            #expect(try await next(remote).lease?.phase == .ready)
        }
        for position in 1 ... 2 {
            try remote.send(PoolRequest.lease(terms))
            #expect(try await next(remote) == .queued(position: position))
        }
        try remote.send(PoolRequest.lease(terms))
        let full = Self.refusal("this Mac already has as many requests in the queue as the host has slots")
        #expect(try await next(remote) == .failure(full))

        let local = try await PoolClient.connect(to: pool.directory)
        for position in 3 ... 5 {
            try local.send(PoolRequest.lease(pool.terms()))
            #expect(try await next(local) == .queued(position: position))
        }
        #expect(await daemon.summary().queue.count == 5)
        local.close()
        remote.close()
        await daemon.shutdown()
    }

    /// Sends a paired client no reply that names the data directory, an offered source, or the
    /// home directory. The replies cover a lease from its start to its end, an attach, the queue,
    /// and status. They also cover failures of the VM, refusals of sources, and an unreadable list
    /// of paired clients.
    @Test func keepsHostPathsFromPairedClients() async throws {
        let pool = try PoolFixture()
        let offered = try [
            "base": pool.source,
            "fresh": pool.makeSource(named: "fresh", hasBooted: false),
            "rotating": pool.makeSource(named: "rotating", credentialRotation: .started),
            "busy": pool.makeSource(named: "busy"),
            "missing": pool.root.url.appending(path: "missing").path(percentEncoded: false),
        ]
        let daemon = try await pool.start(slots: 1, offeredSources: offered)
        let remote = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("a"))
        var replies: [PoolReply] = []
        let receive = { () async throws -> PoolReply in try await next(remote) }

        try remote.send(PoolRequest.lease(LeaseTerms(
            source: "base",
            timeToLive: 60,
            restartPolicy: .onFailure,
            detached: true,
        )))
        try await replies.append(receive())
        #expect(replies.last?.lease?.source == "base")
        try await replies.append(receive())
        let ready = try #require(replies.last?.lease)
        #expect(ready.phase == .ready)
        #expect(ready.bundle == nil)
        #expect(ready.address == nil)
        try remote.send(PoolRequest.status)
        try await replies.append(receive())
        try remote.send(PoolRequest.renew(ready.id))
        try await replies.append(receive())
        #expect(replies.last?.lease?.id == ready.id)
        try remote.send(PoolRequest.attach(ready.id))
        try await replies.append(receive())
        let attached = try #require(replies.last?.lease)
        #expect([attached.source, attached.bundle, attached.address] == ["base", nil, nil])

        pool.launcher.exit(ready.id, .failed("the disk at \(pool.source) failed"), directory: pool.directory)
        try await replies.append(receive())
        guard case let .restarting(restarting, reason)? = replies.last else {
            Issue.record("the lease did not restart")
            return
        }
        #expect(reason == MachineOutcome.hiddenFailure)
        #expect([restarting.source, restarting.bundle, restarting.address] == ["base", nil, nil])
        try remote.send(PoolRequest.release(ready.id))
        try await replies.append(receive())
        try await replies.append(receive())
        #expect(replies.suffix(2).contains(.released(ready.id)))

        let refusals = [
            ("fresh", "the source fresh never booted, so its clones have no guest account"),
            ("rotating", "the source rotating did not finish its credential rotation"),
            ("busy", "another process uses the source busy"),
            ("missing", "the host cannot read the source missing"),
            (pool.source, "the host does not offer the requested source"),
        ]
        let lock = try BundleLock(bundle: VMBundle(root: URL(filePath: offered["busy"] ?? "")))
        for (source, reason) in refusals {
            try remote.send(PoolRequest.lease(LeaseTerms(source: source, timeToLive: 60)))
            try await replies.append(receive())
            #expect(replies.last == .failure(Self.refusal(reason)))
        }
        withExtendedLifetime(lock) {}
        // A paired client cannot fill the log by asking for a broken source again and again.
        try remote.send(PoolRequest.lease(LeaseTerms(source: "missing", timeToLive: 60)))
        try await replies.append(receive())
        #expect(pool.logs.entries("An offered source cannot be read").map(\.level) == [.warning, .debug])

        let local = try await pool.readyLease(pool.terms())
        try remote.send(PoolRequest.attach(local.lease.id))
        try await replies.append(receive())
        #expect(replies.last == .failure(PoolError.unknownLease(id: local.lease.id.rawValue).description))
        try remote.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60, restartPolicy: .never)))
        try await replies.append(receive())
        #expect(replies.last == .queued(position: 1))
        try remote.send(PoolRequest.status)
        try await replies.append(receive())
        guard case let .status(summary)? = replies.last else {
            Issue.record("the host sent no status")
            return
        }
        #expect(summary.queue.map(\.source) == ["base"])

        let list = pool.directory.trustDirectory.appending(path: "clients.json")
        let saved = try Data(contentsOf: list)
        try Data("{".utf8).write(to: list)
        for _ in 0 ..< 2 {
            try remote.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
            try await replies.append(receive())
            #expect(replies.last == .failure(Self.refusal("the host cannot read its list of paired Macs")))
        }
        #expect(pool.logs.entries("The list of paired clients cannot be read").map(\.level) == [.error, .debug])
        try saved.write(to: list)

        #expect(try await PoolClient.send(.release(local.lease.id), to: pool.directory) == .released(local.lease.id))
        try await replies.append(receive())
        #expect(replies.last?.lease?.phase == .starting)
        try await replies.append(receive())
        let queued = try #require(replies.last?.lease)
        pool.launcher.exit(queued.id, .failed("the disk at \(pool.source) failed"), directory: pool.directory)
        try await replies.append(receive())
        guard case let .ended(_, reason)? = replies.last else {
            Issue.record("the lease did not end")
            return
        }
        #expect(reason.hasPrefix(MachineOutcome.hiddenFailure))

        try remote.send(["request": pool.source])
        try await replies.append(receive())
        #expect(replies.last == .failure("the host could not read the request"))

        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let paths = [pool.root.url.path(percentEncoded: false), home]
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        for reply in replies {
            let text = try String(decoding: encoder.encode(reply), as: UTF8.self)
            #expect(!paths.contains { text.contains($0) }, "\(text)")
        }
        #expect(pool.logs.entries("A reply to a paired Mac named a host path").isEmpty)
        await daemon.shutdown()
    }

    /// Replaces a reply to a paired client that names a host path with a failure, and logs it.
    /// A source name cannot hold a path. The test therefore passes replies to the check directly.
    ///
    /// The host offers a source at a decomposed path. The texts hold the precomposed path, alone
    /// and before a combining mark, as a file URL, and percent-encoded from either form. Two more
    /// texts are a file URL to another path and a path that starts with `~/`. A status with an
    /// image in the data directory also gets the failure.
    @Test func replacesRepliesThatNameHostPaths() async throws {
        let pool = try PoolFixture()
        let path = try pool.makeSource(named: "j\u{FC} rgen")
        let precomposed = String(path.dropLast()).precomposedStringWithCanonicalMapping
        let url = URL(filePath: path)
        let texts = try [
            precomposed,
            precomposed + "\u{301}",
            "\(url)",
            url.path(percentEncoded: true),
            #require(precomposed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)),
            "file:///elsewhere",
            "~/elsewhere",
        ]
        let daemon = try await pool.start(offeredSources: ["base": path.decomposedStringWithCanonicalMapping])
        let paired = try LeaseLedgerTests.paired("a")
        let hidden = PoolReply.failure("the host could not complete the request. The host's log has the reason")
        for text in texts {
            #expect(await daemon.visible(.failure(text), to: paired) == hidden, "\(text)")
            #expect(await daemon.visible(.failure(text), to: .local) == .failure(text), "\(text)")
        }
        #expect(await daemon.visible(.failure("base"), to: paired) == .failure("base"))
        let image = ImageSummary(
            name: "xcode",
            path: pool.directory.imagesDirectory.appending(path: "xcode").path(percentEncoded: false),
            isReady: true,
        )
        let status = PoolReply.status(PoolSummary(slots: 1, leases: [], queue: [], images: [image]))
        #expect(await daemon.visible(status, to: paired) == hidden)
        #expect(pool.logs.entries("A reply to a paired Mac named a host path").count == texts.count + 1)
        await daemon.shutdown()
    }

    /// Refuses an offered source with a slash in its name or with a relative path.
    @Test func refusesOfferedSourcesThatCouldNameAPath() throws {
        let pool = try PoolFixture()
        for name in ["~/base", "file://base", "team/base", "a/\u{301}b"] {
            let refusal = PoolError.invalidRequest(reason: "the offered source \"\(name)\" needs a name without \"/\"")
            #expect(throws: refusal, "\(name)") {
                try pool.daemon(offeredSources: [name: pool.source])
            }
        }
        let relative = PoolError.invalidRequest(reason: "the offered source \"base\" needs an absolute path")
        #expect(throws: relative) {
            try pool.daemon(offeredSources: ["base": "base"])
        }
    }

    /// Returns the text of an invalid request's failure.
    ///
    /// - Parameter reason: The reason of the refusal.
    /// - Returns: The message of the failure reply.
    static func refusal(_ reason: String) -> String {
        PoolError.invalidRequest(reason: reason).description
    }

    /// Writes a paired client's record into the list of paired clients.
    ///
    /// - Parameters:
    ///   - owner: The paired client.
    ///   - priorityCeiling: The highest priority that the client may ask for.
    ///   - isBlocked: Whether the host refuses the client.
    ///   - directory: The host's data directory.
    /// - Throws: An error when the list cannot be read or written.
    static func record(
        _ owner: LeaseOwner,
        priorityCeiling: Int,
        isBlocked: Bool = false,
        in directory: PoolDirectory,
    ) throws {
        guard case let .client(key) = owner else {
            return
        }
        var clients = try TrustList<TrustedClient>.load(from: directory)
        clients.insert(TrustedClient(
            key: key,
            name: "client",
            pairedAt: Date(),
            isBlocked: isBlocked,
            priorityCeiling: priorityCeiling,
        ))
        try clients.save(to: directory)
    }
}

/// More source bundles for the tests of offered sources.
private extension PoolFixture {
    /// Creates another source bundle beside the fixture's source.
    ///
    /// - Parameters:
    ///   - name: The bundle's directory name.
    ///   - hasBooted: Whether the source booted once.
    ///   - credentialRotation: The state of the source's own credential rotation.
    /// - Returns: The bundle's path.
    /// - Throws: An error when the directory or the settings cannot be written.
    func makeSource(
        named name: String,
        hasBooted: Bool = true,
        credentialRotation: CredentialRotationState? = nil,
    ) throws -> String {
        let bundle = VMBundle(root: root.url.appending(path: name, directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: bundle.root, withIntermediateDirectories: false)
        try bundle.writeSettings(BundleSettings(
            cpuCount: 2,
            memoryByteCount: 4 << 30,
            macAddress: "02:00:00:00:00:0\(name.count % 10)",
            build: "25A1",
            hasBooted: hasBooted,
            credentialRotation: credentialRotation,
        ))
        return bundle.root.path(percentEncoded: false)
    }
}
