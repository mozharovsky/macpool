import Foundation
@testable import MacpoolVM
import Testing

/// Tests of the bundle layout, settings, disk creation, identity, and cloning.
struct VMBundleTests {
    /// Settings in the layout that existing bundles use.
    static let settingsJSON = """
    {
      "cpus": 8,
      "memory_bytes": 17179869184,
      "mac_address": "d6:c5:4f:ee:f7:9e",
      "build": "26B123"
    }
    """

    /// Names every part of a bundle inside its directory.
    @Test func namesBundleParts() {
        let bundle = VMBundle(root: URL(filePath: "/tmp/vms/base"))
        #expect(bundle.disk.path(percentEncoded: false) == "/tmp/vms/base/disk.img")
        #expect(bundle.auxiliaryStorage.lastPathComponent == "aux.img")
        #expect(bundle.hardwareModel.lastPathComponent == "hardware-model.bin")
        #expect(bundle.machineIdentifier.lastPathComponent == "machine-id.bin")
        #expect(bundle.settingsFile.lastPathComponent == "settings.json")
        #expect(bundle.guestAccountFile.lastPathComponent == "guest-account.json")
        #expect(bundle.stopRequest.lastPathComponent == "stop-request")
        #expect(bundle.lockFile.lastPathComponent == "lock")
        #expect(bundle.knownHostsFile.lastPathComponent == "known_hosts")
        #expect(bundle.rotatingGuestAccountFile.lastPathComponent == "guest-account.rotating.json")
    }

    /// Reads settings without a boot record and writes them back unchanged in meaning.
    @Test func roundTripsSettings() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        try Self.settingsJSON.write(to: bundle.settingsFile, atomically: true, encoding: .utf8)
        let settings = try bundle.settings()
        #expect(settings == BundleSettings(
            cpuCount: 8,
            memoryByteCount: 17_179_869_184,
            macAddress: "d6:c5:4f:ee:f7:9e",
            build: "26B123",
            hasBooted: nil,
        ))
        try bundle.writeSettings(settings)
        #expect(try bundle.settings() == settings)
        let text = try String(contentsOf: bundle.settingsFile, encoding: .utf8)
        #expect(text.contains("\"memory_bytes\""))
        #expect(!text.contains("has_booted"))
    }

    /// Stores the boot record under its snake case key.
    @Test func recordsFirstBoot() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        try Self.settingsJSON.write(to: bundle.settingsFile, atomically: true, encoding: .utf8)
        var settings = try bundle.settings()
        settings.hasBooted = false
        try bundle.writeSettings(settings)
        #expect(try bundle.settings().hasBooted == false)
        settings.hasBooted = true
        try bundle.writeSettings(settings)
        #expect(try bundle.settings().hasBooted == true)
        let text = try String(contentsOf: bundle.settingsFile, encoding: .utf8)
        #expect(text.contains("\"has_booted\" : true"))
    }

    /// Reports a missing or malformed settings file with its path.
    @Test func rejectsMissingAndMalformedSettings() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        #expect {
            try bundle.settings()
        } throws: { error in
            guard case let .fileSystem(_, path, _) = error as? MacpoolError else {
                return false
            }
            return path.hasSuffix("settings.json")
        }
        try "{}".write(to: bundle.settingsFile, atomically: true, encoding: .utf8)
        #expect {
            try bundle.settings()
        } throws: { error in
            guard case .invalidBundle = error as? MacpoolError else {
                return false
            }
            return true
        }
    }

    /// Creates a sparse disk with the requested size and refuses to replace it.
    @Test func createsSparseDiskOnce() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        let size: UInt64 = 64 << 30
        try bundle.createDisk(byteCount: size)
        let values = try bundle.disk.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        #expect(values.fileSize == Int(size))
        #expect((values.totalFileAllocatedSize ?? Int.max) < 1 << 20)
        #expect(throws: MacpoolError.self) {
            try bundle.createDisk(byteCount: size)
        }
    }

    /// Gives a bundle a new machine identifier and MAC address.
    @Test func assignsFreshIdentity() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        try Self.settingsJSON.write(to: bundle.settingsFile, atomically: true, encoding: .utf8)
        try bundle.assignIdentity()
        let firstIdentifier = try Data(contentsOf: bundle.machineIdentifier)
        let firstAddress = try bundle.settings().macAddress
        _ = try bundle.loadMachineIdentifier()
        try bundle.assignIdentity()
        #expect(try Data(contentsOf: bundle.machineIdentifier) != firstIdentifier)
        #expect(try bundle.settings().macAddress != firstAddress)
        #expect(firstAddress != "d6:c5:4f:ee:f7:9e")
        #expect(MACAddress(firstAddress) != nil)
    }

    /// Rejects a machine identifier file that holds no identifier.
    @Test func rejectsInvalidMachineIdentifier() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        try Data("not an identifier".utf8).write(to: bundle.machineIdentifier)
        #expect(throws: MacpoolError.invalidBundle(
            path: bundle.machineIdentifier.path(percentEncoded: false),
            reason: "not a machine identifier",
        )) {
            try bundle.loadMachineIdentifier()
        }
    }

    /// Clones a directory with all its files and refuses an existing destination.
    @Test func clonesBundleDirectory() throws {
        let directory = try TemporaryDirectory()
        let source = VMBundle(root: directory.url.appending(path: "source"))
        try FileManager.default.createDirectory(at: source.root, withIntermediateDirectories: false)
        try Self.settingsJSON.write(to: source.settingsFile, atomically: true, encoding: .utf8)
        try source.createDisk(byteCount: 1 << 20)
        let clone = try source.clone(to: directory.url.appending(path: "clone"))
        var expected = try source.settings()
        expected.credentialRotation = .pending
        #expect(try clone.settings() == expected)
        #expect(FileManager.default.fileExists(atPath: clone.disk.path(percentEncoded: false)))
        #expect(throws: MacpoolError.self) {
            try source.clone(to: clone.root)
        }
    }

    /// Keeps a booted source's account and pins for the clone's rotation and records it as pending.
    @Test func marksCloneOfBootedSourceForRotation() throws {
        let directory = try TemporaryDirectory()
        let source = try Self.makeSource(in: directory, hasBooted: true, rotation: .finished)
        try Data("stale".utf8).write(to: source.rotatingGuestAccountFile)
        let clone = try source.clone(to: directory.url.appending(path: "clone"))
        #expect(try clone.settings().credentialRotation == .pending)
        #expect(try clone.settings().hasBooted == true)
        #expect(FileManager.default.fileExists(atPath: clone.guestAccountFile.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: clone.knownHostsFile.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: clone.rotatingGuestAccountFile.path(percentEncoded: false)))
        #expect(try source.settings().credentialRotation == .finished)
    }

    /// Drops the account and pins of a source that never booted, so the clone provisions its own.
    @Test func dropsCredentialsOfUnbootedSource() throws {
        let directory = try TemporaryDirectory()
        let source = try Self.makeSource(in: directory, hasBooted: false, rotation: nil)
        let clone = try source.clone(to: directory.url.appending(path: "clone"))
        #expect(try clone.settings().credentialRotation == nil)
        #expect(!FileManager.default.fileExists(atPath: clone.guestAccountFile.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: clone.knownHostsFile.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: source.guestAccountFile.path(percentEncoded: false)))
    }

    /// Refuses to clone a bundle whose own rotation did not finish.
    @Test func refusesCloneOfIncompleteRotation() throws {
        let directory = try TemporaryDirectory()
        let source = try Self.makeSource(in: directory, hasBooted: true, rotation: .started)
        let destination = directory.url.appending(path: "clone")
        #expect(throws: MacpoolError.credentialRotationIncomplete(path: source.root.path(percentEncoded: false))) {
            try source.clone(to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    /// Stores the rotation record under its snake case key.
    @Test func recordsCredentialRotation() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        try Self.settingsJSON.write(to: bundle.settingsFile, atomically: true, encoding: .utf8)
        var settings = try bundle.settings()
        #expect(settings.credentialRotation == nil)
        settings.credentialRotation = .started
        try bundle.writeSettings(settings)
        let text = try String(contentsOf: bundle.settingsFile, encoding: .utf8)
        #expect(text.contains("\"credential_rotation\" : \"started\""))
        #expect(try bundle.settings().credentialRotation == .started)
    }

    /// Creates a source bundle with settings, an account, and a `known_hosts` file.
    ///
    /// - Parameters:
    ///   - directory: The temporary directory that receives the `source` bundle.
    ///   - hasBooted: The boot record to store.
    ///   - rotation: The rotation record to store.
    /// - Returns: The source bundle.
    /// - Throws: An error when a file cannot be written.
    static func makeSource(
        in directory: TemporaryDirectory,
        hasBooted: Bool?,
        rotation: CredentialRotationState?,
    ) throws -> VMBundle {
        let source = VMBundle(root: directory.url.appending(path: "source"))
        try FileManager.default.createDirectory(at: source.root, withIntermediateDirectories: false)
        try source.writeSettings(BundleSettings(
            cpuCount: 4,
            memoryByteCount: 8 << 30,
            macAddress: VMBundle.randomMACAddress(),
            build: "26B123",
            hasBooted: hasBooted,
            credentialRotation: rotation,
        ))
        _ = try GuestAccount.loadOrCreate(in: source)
        try Data("macpool-guest ssh-ed25519 \(HostKeyTests.first)\n".utf8).write(to: source.knownHostsFile)
        return source
    }

    /// Removes the bundle directory that a failed create made.
    @Test func removesBundleAfterFailedCreate() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url.appending(path: "new"))
        let settings = BundleSettings(
            cpuCount: 4,
            memoryByteCount: 8 << 30,
            macAddress: VMBundle.randomMACAddress(),
            build: "26B123",
            hasBooted: false,
        )
        #expect(throws: MacpoolError.invalidBundle(
            path: bundle.hardwareModel.path(percentEncoded: false),
            reason: "not a hardware model",
        )) {
            try VirtualMachine.create(
                bundle: bundle,
                settings: settings,
                hardwareModel: Data("not a hardware model".utf8),
                diskByteCount: 1 << 20,
            )
        }
        #expect(!FileManager.default.fileExists(atPath: bundle.root.path(percentEncoded: false)))
    }

    /// Resolves a relative bundle path against the current directory.
    @Test func resolvesRelativeRoot() {
        let bundle = VMBundle(root: URL(filePath: "vms/../vms/base"))
        #expect(bundle.root.path(percentEncoded: false).hasPrefix("/"))
        #expect(bundle.root.path(percentEncoded: false).hasSuffix("/vms/base"))
    }
}
