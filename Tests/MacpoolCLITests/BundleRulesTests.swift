import ArgumentParser
import Foundation
@testable import MacpoolCLI
import MacpoolVM
import Testing

/// Tests of the bundle rules that commands enforce before any VM starts.
struct BundleRulesTests {
    /// Refuses a first boot without provisioning.
    @Test func refusesFirstBootWithoutProvisioning() async throws {
        let directory = try BundleDirectory(hasBooted: false)
        let command = try #require(try Macpool.parseAsRoot(["run", "--bundle", directory.path]) as? RunCommand)
        await #expect(throws: CommandError.firstBootNeedsProvisioning) {
            try await command.run()
        }
        #expect(!FileManager.default.fileExists(atPath: directory.bundle.guestAccountFile.path(percentEncoded: false)))
    }

    /// Refuses provisioning that a booted guest would ignore, before it writes an account.
    @Test func refusesProvisioningAfterFirstBoot() async throws {
        let directory = try BundleDirectory(hasBooted: true)
        let command = try #require(
            try Macpool.parseAsRoot(["run", "--bundle", directory.path, "--provision"]) as? RunCommand,
        )
        await #expect(throws: CommandError.provisioningAfterFirstBoot) {
            try await command.run()
        }
        #expect(!FileManager.default.fileExists(atPath: directory.bundle.guestAccountFile.path(percentEncoded: false)))
    }

    /// Refuses to boot a clone whose credential rotation did not finish.
    @Test func refusesIncompleteRotation() async throws {
        let directory = try BundleDirectory(hasBooted: true, credentialRotation: .started)
        let command = try #require(try Macpool.parseAsRoot(["run", "--bundle", directory.path]) as? RunCommand)
        await #expect(throws: CommandError.library(.credentialRotationIncomplete(path: directory.path))) {
            try await command.run()
        }
        #expect(!BundleLock.isHeld(on: directory.bundle))
    }

    /// Reports a rotation as in progress while another command holds the clone.
    @Test(arguments: [CredentialRotationState.pending, .started])
    func reportsRotationInProgress(state: CredentialRotationState) async throws {
        let directory = try BundleDirectory(hasBooted: true, credentialRotation: state)
        let lock = try BundleLock(bundle: directory.bundle)
        let command = try #require(try Macpool.parseAsRoot(["run", "--bundle", directory.path]) as? RunCommand)
        await #expect(throws: CommandError.library(.credentialRotationInProgress(path: directory.path))) {
            try await command.run()
        }
        withExtendedLifetime(lock) {}
    }

    /// Refuses to clone a bundle that another command holds.
    @Test func refusesCloneOfLockedSource() async throws {
        let directory = try BundleDirectory(hasBooted: true)
        let lock = try BundleLock(bundle: directory.bundle)
        let destination = directory.bundle.root.deletingLastPathComponent().appending(path: "clone")
        let command = try #require(
            try Macpool.parseAsRoot([
                "clone", "--from", directory.path, "--to", destination.path(percentEncoded: false),
            ]) as? CloneCommand,
        )
        await #expect(throws: CommandError.library(.bundleInUse(path: directory.path))) {
            try await command.run()
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        withExtendedLifetime(lock) {}
    }

    /// Refuses to print an address for a bundle that no run holds.
    @Test func refusesAddressOfStoppedBundle() async throws {
        let directory = try BundleDirectory(hasBooted: true)
        let command = try #require(try Macpool.parseAsRoot(["ip", "--bundle", directory.path]) as? AddressCommand)
        await #expect(throws: CommandError.notRunning(path: directory.path)) {
            try await command.run()
        }
    }
}

/// A temporary bundle directory with only a settings file, removed with the value.
private final class BundleDirectory {
    /// The bundle inside the temporary directory.
    let bundle: VMBundle

    /// The bundle's path without percent encoding.
    var path: String {
        bundle.root.path(percentEncoded: false)
    }

    /// Creates the bundle with a boot record.
    ///
    /// - Parameters:
    ///   - hasBooted: The boot record to store.
    ///   - credentialRotation: The rotation record to store.
    /// - Throws: An error when the directory or the settings cannot be written.
    init(hasBooted: Bool?, credentialRotation: CredentialRotationState? = nil) throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "macpool-cli-tests-\(UUID().uuidString)")
        bundle = VMBundle(root: parent.appending(path: "bundle"))
        try FileManager.default.createDirectory(at: bundle.root, withIntermediateDirectories: true)
        try bundle.writeSettings(BundleSettings(
            cpuCount: 4,
            memoryByteCount: 8 << 30,
            macAddress: VMBundle.randomMACAddress(),
            build: "26B123",
            hasBooted: hasBooted,
            credentialRotation: credentialRotation,
        ))
    }

    /// Removes the temporary directory.
    deinit {
        try? FileManager.default.removeItem(at: bundle.root.deletingLastPathComponent())
    }
}
