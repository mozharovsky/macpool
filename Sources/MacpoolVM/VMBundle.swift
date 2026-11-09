public import Foundation
import Virtualization

/// The settings of a bundle that the framework does not store in its own data files.
///
/// The JSON keys use snake case so that bundles stay readable by tools in any language.
public struct BundleSettings: Codable, Sendable, Equatable {
    /// The number of virtual CPUs.
    public var cpuCount: Int

    /// The guest memory size in bytes.
    public var memoryByteCount: UInt64

    /// The guest's MAC address in colon-separated form.
    ///
    /// The host's DHCP server keys its leases by this address, so every bundle that runs beside
    /// another needs its own.
    public var macAddress: String

    /// The build number of the installed macOS, such as `26B123`.
    public var build: String

    /// Whether the VM has started at least once since macOS was installed.
    ///
    /// The guest applies provisioning options only on its first boot, so commands use this record
    /// to refuse a first boot without them and a later boot with them. The value is `nil` for a
    /// bundle created before the record existed, whose first boot is unknown.
    public var hasBooted: Bool?

    /// The JSON keys of the settings file.
    private enum CodingKeys: String, CodingKey {
        /// The `cpus` key.
        case cpuCount = "cpus"
        /// The `memory_bytes` key.
        case memoryByteCount = "memory_bytes"
        /// The `mac_address` key.
        case macAddress = "mac_address"
        /// The `build` key.
        case build
        /// The `has_booted` key, which is absent in bundles that predate it.
        case hasBooted = "has_booted"
    }

    /// Creates settings from their values.
    ///
    /// - Parameters:
    ///   - cpuCount: The number of virtual CPUs.
    ///   - memoryByteCount: The guest memory size in bytes.
    ///   - macAddress: The guest's MAC address in colon-separated form.
    ///   - build: The build number of the installed macOS.
    ///   - hasBooted: Whether the VM has started since the install, or `nil` when unknown.
    public init(cpuCount: Int, memoryByteCount: UInt64, macAddress: String, build: String, hasBooted: Bool?) {
        self.cpuCount = cpuCount
        self.memoryByteCount = memoryByteCount
        self.macAddress = macAddress
        self.build = build
        self.hasBooted = hasBooted
    }
}

/// A VM bundle directory and the locations of its parts.
///
/// A bundle holds a sparse raw disk image, the auxiliary storage with the guest's NVRAM, the
/// serialized hardware model and machine identifier, and a JSON settings file. A stopped bundle
/// is self-contained. An APFS clone of the directory is therefore a complete second VM once it
/// receives its own machine identifier and MAC address.
///
/// The type only names paths. Its methods touch the file system, and none of them checks
/// whether a VM currently runs from the bundle. Commands coordinate through ``BundleLock``.
public struct VMBundle: Sendable, Hashable {
    /// The bundle directory.
    public let root: URL

    /// Refers to a bundle directory without checking its contents.
    ///
    /// - Parameter root: The bundle directory. A relative URL resolves against the current
    ///   directory.
    public init(root: URL) {
        self.root = root.absoluteURL.standardizedFileURL
    }

    /// The raw disk image.
    public var disk: URL {
        root.appending(path: "disk.img")
    }

    /// The auxiliary storage that holds the guest's NVRAM.
    public var auxiliaryStorage: URL {
        root.appending(path: "aux.img")
    }

    /// The serialized hardware model.
    public var hardwareModel: URL {
        root.appending(path: "hardware-model.bin")
    }

    /// The serialized machine identifier.
    public var machineIdentifier: URL {
        root.appending(path: "machine-id.bin")
    }

    /// The JSON settings file.
    public var settingsFile: URL {
        root.appending(path: "settings.json")
    }

    /// The guest account file, which only the owner can read.
    public var guestAccountFile: URL {
        root.appending(path: "guest-account.json")
    }

    /// The file that carries the bundle's ``BundleLock``.
    public var lockFile: URL {
        root.appending(path: "lock")
    }

    /// The file whose creation asks a held run to stop early.
    public var stopRequest: URL {
        root.appending(path: "stop-request")
    }

    /// Reads the bundle's settings.
    ///
    /// - Returns: The decoded settings.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the file cannot be read,
    ///   or ``MacpoolError/invalidBundle(path:reason:)`` when it is malformed.
    public func settings() throws(MacpoolError) -> BundleSettings {
        let data = try FileSystem.read(settingsFile, for: "reading settings")
        do {
            return try JSONDecoder().decode(BundleSettings.self, from: data)
        } catch {
            throw .invalidBundle(path: settingsFile.filePath, reason: "\(error)")
        }
    }

    /// Replaces the bundle's settings file.
    ///
    /// - Parameter settings: The settings to store.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the file cannot be
    ///   written.
    public func writeSettings(_ settings: BundleSettings) throws(MacpoolError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(settings) + Data("\n".utf8)
        } catch {
            throw .invalidBundle(path: settingsFile.filePath, reason: "\(error)")
        }
        try FileSystem.write(data, to: settingsFile, for: "writing settings")
    }

    /// Creates the sparse disk image with a logical size.
    ///
    /// APFS allocates blocks only when the guest writes them, so the new file holds no data.
    ///
    /// - Parameter byteCount: The logical size in bytes.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the file exists or
    ///   cannot be created.
    public func createDisk(byteCount: UInt64) throws(MacpoolError) {
        guard let length = off_t(exactly: byteCount) else {
            throw .unsupported(reason: "a disk of \(byteCount) bytes")
        }
        try FileSystem.createNewFile(at: disk, contents: Data(), permissions: 0o644)
        guard truncate(disk.filePath, length) == 0 else {
            throw .systemCall("sizing the disk image", disk)
        }
    }

    /// Gives the bundle a fresh machine identifier and, when settings exist, a fresh MAC address.
    ///
    /// The framework derives the guest's serial number and hardware UUID from the machine
    /// identifier, and the DHCP server keys its leases by MAC address. A clone needs both to be new
    /// so that it can run beside its source.
    ///
    /// - Throws: ``MacpoolError`` when an identity file cannot be written or the settings cannot be
    ///   read.
    public func assignIdentity() throws(MacpoolError) {
        let identifier = VZMacMachineIdentifier()
        try FileSystem.write(
            identifier.dataRepresentation,
            to: machineIdentifier,
            for: "writing the machine identifier",
        )
        if FileManager.default.fileExists(atPath: settingsFile.filePath) {
            var settings = try settings()
            settings.macAddress = Self.randomMACAddress()
            try writeSettings(settings)
        }
    }

    /// Clones this stopped bundle to a new directory with APFS `clonefile`.
    ///
    /// The clone shares every data block with the source until either side writes. The call keeps
    /// the source's identity, so callers follow it with ``assignIdentity()``. It also copies the
    /// guest account file, and the cloned disk keeps the guest's SSH host keys.
    ///
    /// The call does not check whether a VM runs from the source. Callers hold the source's
    /// ``BundleLock`` during the copy so that no guest writes to the disk meanwhile.
    ///
    /// - Parameter destination: The clone's directory. It must not exist and must be on the same
    ///   APFS volume as the source.
    /// - Returns: The cloned bundle.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the clone fails, for
    ///   example across volumes or when the destination exists.
    public func clone(to destination: URL) throws(MacpoolError) -> VMBundle {
        let clone = VMBundle(root: destination)
        guard clonefile(root.filePath, clone.root.filePath, 0) == 0 else {
            throw .systemCall("cloning \(root.filePath) to", clone.root)
        }
        return clone
    }

    /// Reads the stored machine identifier.
    ///
    /// - Returns: The identifier that the VM's platform configuration uses.
    /// - Throws: ``MacpoolError`` when the file is missing or holds no valid identifier.
    func loadMachineIdentifier() throws(MacpoolError) -> VZMacMachineIdentifier {
        let data = try FileSystem.read(machineIdentifier, for: "reading the machine identifier")
        guard let identifier = VZMacMachineIdentifier(dataRepresentation: data) else {
            throw .invalidBundle(path: machineIdentifier.filePath, reason: "not a machine identifier")
        }
        return identifier
    }

    /// Creates a random locally administered unicast MAC address.
    ///
    /// - Returns: The address in colon-separated form.
    public static func randomMACAddress() -> String {
        VZMACAddress.randomLocallyAdministered().string
    }
}
