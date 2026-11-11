import Foundation
@testable import MacpoolPool
import MacpoolVM
import Testing

/// Tests of images in the data directory and of leasing them.
@Suite(.timeLimit(.minutes(1)))
struct ImageTests {
    /// Refuses to lease an image that is not ready or whose record cannot be read.
    @Test func refusesImageThatIsNotReady() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let source = VMBundle(root: URL(filePath: pool.source))

        try source.writeImageRecord(ImageRecord(isReady: false))
        let notReady = PoolError.invalidRequest(
            reason: "the image \(pool.source) did not pass its checks, so it cannot be leased",
        )
        await #expect(throws: PoolError.daemonRefused(message: notReady.description)) {
            try await PoolClient.send(.lease(pool.terms()), to: pool.directory)
        }

        try Data(#"{"version": 2, "ready": true}"#.utf8).write(to: source.imageFile)
        let unsupported = PoolError.library(.invalidBundle(
            path: source.imageFile.path(percentEncoded: false),
            reason: "image record version 2 is not supported",
        ))
        await #expect(throws: PoolError.daemonRefused(message: unsupported.description)) {
            try await PoolClient.send(.lease(pool.terms()), to: pool.directory)
        }
        #expect(await daemon.summary().leases.isEmpty)
        #expect(await daemon.summary().queue.isEmpty)

        try source.writeImageRecord(ImageRecord(isReady: true))
        let granted = try await pool.readyLease(pool.terms())
        #expect(granted.lease.source == pool.source)
        await daemon.shutdown()
    }

    /// Refuses a bundle in the images directory without a record and leases one elsewhere.
    @Test func refusesImageWithoutRecord() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let image = try pool.makeImage(named: "xcode")
        let imagePath = image.root.path(percentEncoded: false)

        let missing = PoolError
            .invalidRequest(reason: "the image \(imagePath) has no image.json, so it cannot be leased")
        await #expect(throws: PoolError.daemonRefused(message: missing.description)) {
            try await PoolClient.send(.lease(LeaseTerms(source: imagePath, timeToLive: 60)), to: pool.directory)
        }
        let granted = try await pool.readyLease(pool.terms())
        #expect(granted.lease.source == pool.source)
        await daemon.shutdown()
    }

    /// Names an image by its offered name, without a path, when it refuses a paired client.
    @Test func hidesImagePathsFromPairedClients() async throws {
        let pool = try PoolFixture()
        let image = try pool.makeImage(named: "xcode")
        let daemon = try await pool.start(offeredSources: [
            "base": pool.source,
            "xcode": image.root.path(percentEncoded: false),
        ])
        let remote = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("a"))
        let source = VMBundle(root: URL(filePath: pool.source))
        let refuse = { (name: String, reason: String) async throws in
            try remote.send(PoolRequest.lease(LeaseTerms(source: name, timeToLive: 60)))
            let reply = try await next(remote)
            #expect(reply == .failure(PoolError.invalidRequest(reason: "the image \(name) \(reason)").description))
        }

        try await refuse("xcode", "has no image.json, so it cannot be leased")
        try source.writeImageRecord(ImageRecord(isReady: false))
        try await refuse("base", "did not pass its checks, so it cannot be leased")
        try Data(#"{"version": 2, "ready": true}"#.utf8).write(to: source.imageFile)
        try await refuse("base", "has an unreadable image.json, so it cannot be leased")
        await daemon.shutdown()
    }

    /// Lists every image directory by name, with the reason when its record cannot be read.
    @Test func listsImages() throws {
        let pool = try PoolFixture()
        let images = pool.directory.imagesDirectory
        #expect(pool.directory.images().isEmpty)

        for name in ["xcode", "broken", "empty", ".hidden"] {
            try FileManager.default.createDirectory(
                at: images.appending(path: name),
                withIntermediateDirectories: true,
            )
        }
        try Data().write(to: images.appending(path: "notes.txt"))
        try VMBundle(root: images.appending(path: "xcode")).writeImageRecord(ImageRecord(
            isReady: true,
            builds: ["xcode": "27A266a"],
        ))
        let broken = VMBundle(root: images.appending(path: "broken"))
        try Data(#"{"ready": true}"#.utf8).write(to: broken.imageFile)

        let path = { (name: String) in
            images.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false)
        }
        let problem = #expect(throws: MacpoolError.self) {
            try VMBundle(root: URL(filePath: path("broken"))).imageRecord()
        }?.description
        #expect(problem?.hasSuffix("image.json: the image record has no version") == true)
        #expect(pool.directory.images() == [
            ImageSummary(name: "broken", path: path("broken"), isReady: false, problem: problem),
            ImageSummary(name: "empty", path: path("empty"), isReady: false, problem: "it has no image.json"),
            ImageSummary(name: "xcode", path: path("xcode"), isReady: true, builds: ["xcode": "27A266a"]),
        ])
    }

    /// Sends images to clients on this Mac and none to a paired Mac.
    @Test func showsImagesOnlyToLocalClients() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let image = VMBundle(root: pool.directory.imagesDirectory.appending(path: "xcode"))
        try FileManager.default.createDirectory(at: image.root, withIntermediateDirectories: true)
        try image.writeImageRecord(ImageRecord(isReady: true))

        let local = try await PoolClient.send(.status, to: pool.directory)
        #expect(local == .status(PoolSummary(slots: 2, leases: [], queue: [], images: pool.directory.images())))
        #expect(pool.directory.images().map(\.name) == ["xcode"])

        let remote = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("a"))
        try remote.send(PoolRequest.status)
        #expect(try await next(remote) == .status(PoolSummary(slots: 2, leases: [], queue: [])))
        await daemon.shutdown()
    }

    /// Reads a summary without the `images` key as one without images.
    @Test func decodesSummaryWithoutImages() throws {
        let json = #"{"leases":[],"queue":[],"slots":2}"#
        let summary = try MessageCoding.decoder.decode(PoolSummary.self, from: Data(json.utf8))
        #expect(summary == PoolSummary(slots: 2, leases: [], queue: []))

        let image = ImageSummary(name: "xcode", path: "/pool/images/xcode", isReady: true, builds: ["xcode": "1"])
        let data = try MessageCoding.encoder.encode(PoolSummary(slots: 1, leases: [], queue: [], images: [image]))
        #expect(String(decoding: data, as: UTF8.self).contains(#""ready":true"#))
        #expect(try MessageCoding.decoder.decode(PoolSummary.self, from: data).images == [image])
    }
}
