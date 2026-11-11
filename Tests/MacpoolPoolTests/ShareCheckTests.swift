import Foundation
import MacpoolPool
import Testing

/// Tests of the rule that a shared directory stays clear of the data directory and the source.
struct ShareCheckTests {
    /// Refuses every spelling of the data directory, its parents, and its contents.
    @Test func refusesDirectoriesThatOverlapDataDirectory() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        let manager = FileManager.default
        try manager.createDirectory(at: directory.leasesDirectory, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: root.url.appending(path: "link"), withDestinationURL: directory.root)
        // A directory that the user can search but not read still resolves.
        let leases = directory.leasesDirectory.path(percentEncoded: false)
        try manager.setAttributes([.posixPermissions: 0o300], ofItemAtPath: leases)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leases) }
        let hidden = root.url.appending(path: "hidden")
        try manager.createSymbolicLink(at: hidden, withDestinationURL: directory.leasesDirectory)
        let parent = try #require(realpath(root.url.path(percentEncoded: false), nil))
        defer { free(parent) }
        let path = String(cString: parent)
        let refusals = [
            ("\(path)/pool", "includes"),
            (path, "includes"),
            ("\(path)/POOL", "includes"),
            ("\(path)/link", "includes"),
            ("/System/Volumes/Data\(path)", "includes"),
            ("/System/Volumes/Data", "includes"),
            ("\(path)/pool/leases", "lies inside"),
            ("\(path)/hidden", "lies inside"),
        ]
        for (shared, relation) in refusals {
            #expect {
                try directory.checkShare(shared)
            } throws: { error in
                "\(error)".contains("\(shared) \(relation) macpool's data directory")
            }
        }
        #expect {
            try directory.checkShare(path, isReadOnly: true)
        } throws: { error in
            "\(error)".contains("The guest could read the images")
        }
        // A data directory that does not exist yet is still kept out of the guest's reach.
        let missing = PoolDirectory(root: root.url.appending(path: "later/pool"))
        #expect(throws: PoolError.self) { try missing.checkShare(path) }
    }

    /// Accepts a directory beside the data directory and refuses one that includes the source.
    @Test func refusesDirectoriesThatIncludeSource() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        let source = root.url.appending(path: "work/base").path(percentEncoded: false)
        // The name begins with the data directory's name, so only a comparison of whole
        // components accepts it.
        let beside = root.url.appending(path: "poolside").path(percentEncoded: false)
        for created in [source, beside] {
            try FileManager.default.createDirectory(atPath: created, withIntermediateDirectories: true)
        }
        try directory.checkShare(beside, sources: [source])
        let work = root.url.appending(path: "work").path(percentEncoded: false)
        #expect {
            try directory.checkShare(work, sources: [beside + "/base", source])
        } throws: { error in
            "\(error)".contains("\(work) includes the source \(source)")
        }
    }

    /// Refuses a writable directory that includes the executable and accepts a read-only one.
    @Test func refusesWritableDirectoryWithExecutable() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        let bin = root.url.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        let executable = bin.appending(path: "macpool")
        let shared = root.url.appending(path: "BIN").path(percentEncoded: false)
        try directory.checkShare(shared, isReadOnly: true, executable: executable)
        #expect {
            try directory.checkShare(shared, executable: executable)
        } throws: { error in
            "\(error)".contains("\(shared) includes the macpool executable")
        }
    }
}
