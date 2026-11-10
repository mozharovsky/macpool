import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the pool state file.
struct PoolStoreTests {
    /// Reads a missing state file as an empty state.
    @Test func readsMissingFileAsEmpty() throws {
        let directory = try ShortDirectory()
        let store = PoolStore(file: directory.url.appending(path: "state.json"))
        #expect(try store.load() == .empty)
    }

    /// Writes and reads leases with every field.
    @Test func roundTripsLeases() throws {
        let directory = try ShortDirectory()
        let store = PoolStore(file: directory.url.appending(path: "state.json"))
        let record = try Self.record()
        let state = PoolState(version: PoolState.currentVersion, leases: [record])
        try store.save(state)
        #expect(try store.load() == state)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        #expect(text.contains("\"ttl_seconds\" : 600"))
        #expect(text.contains("\"restart\" : \"always\""))
        #expect(text.contains("\"supervisor_pid\" : 4242"))
    }

    /// Reads a file that lists one lease twice as malformed.
    @Test func rejectsRepeatedLeases() throws {
        let directory = try ShortDirectory()
        let store = PoolStore(file: directory.url.appending(path: "state.json"))
        let record = try Self.record()
        try store.save(PoolState(version: PoolState.currentVersion, leases: [record, record]))
        let path = store.file.path(percentEncoded: false)
        #expect(throws: PoolError.invalidState(path: path, reason: "it lists lease 0a1b2c3d more than once")) {
            try store.load()
        }
    }

    /// Creates a lease record with every field set.
    ///
    /// - Returns: The record of lease `0a1b2c3d`.
    /// - Throws: An error when the identifier is invalid.
    static func record() throws -> LeaseRecord {
        let id = try #require(LeaseID("0a1b2c3d"))
        return LeaseRecord(
            id: id,
            terms: LeaseTerms(
                source: "/vms/base",
                timeToLive: 600,
                priority: 3,
                restartPolicy: .always,
                sharedDirectory: "/share",
                bootTimeout: 300,
                detached: true,
            ),
            phase: .restarting,
            address: nil,
            grantedAt: Date(timeIntervalSince1970: 1_800_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_600),
            restarts: 1,
            restartAt: Date(timeIntervalSince1970: 1_800_000_010),
            endReason: nil,
            supervisorProcessID: 4242,
        )
    }

    /// Rejects malformed files and tells other format versions apart from them.
    @Test func rejectsUnusableFiles() throws {
        let directory = try ShortDirectory()
        let store = PoolStore(file: directory.url.appending(path: "state.json"))
        try Data("{".utf8).write(to: store.file)
        #expect {
            try store.load()
        } throws: { error in
            if case .invalidState = error as? PoolError {
                true
            } else {
                false
            }
        }
        // A newer format may change every other field, so only the version decides.
        try Data(#"{"version": 99, "leases": "changed"}"#.utf8).write(to: store.file)
        #expect(throws: PoolError.unsupportedStateVersion(path: store.file.path(percentEncoded: false), version: 99)) {
            try store.load()
        }
    }

    /// Writes the state for the owner only and moves an unreadable file aside.
    @Test func protectsAndSetsAsideStateFiles() throws {
        let directory = try ShortDirectory()
        let store = PoolStore(file: directory.url.appending(path: "state.json"))
        try store.save(.empty)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path(percentEncoded: false))
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false)) == [
            "state.json",
        ])

        try Data("{".utf8).write(to: store.file)
        let moved = try store.quarantine(at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(moved.lastPathComponent == "state.json.invalid-1800000000")
        #expect(try Data(contentsOf: moved) == Data("{".utf8))
        #expect(try store.load() == .empty)
    }
}
