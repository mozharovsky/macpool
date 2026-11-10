import Foundation
import Virtualization

/// Builds the framework configuration of a headless macOS VM.
enum MachineConfiguration {
    /// The width of the guest's display in pixels.
    ///
    /// No window shows the display. The guest still needs one to finish booting.
    static let displayWidth = 1920

    /// The height of the guest's display in pixels.
    static let displayHeight = 1200

    /// The density of the guest's display in pixels per inch.
    static let displayPixelsPerInch = 80

    /// Builds and validates a configuration.
    ///
    /// The VM gets a Virtio disk, NAT networking with the bundle's MAC address, a keyboard, a
    /// trackpad, a display, and optionally a shared directory with the macOS automount tag.
    ///
    /// - Parameters:
    ///   - bundle: The bundle that provides the disk and machine identifier.
    ///   - settings: The CPU, memory, and MAC settings.
    ///   - model: The hardware model.
    ///   - storage: The auxiliary storage.
    ///   - devices: Devices beyond the fixed set.
    /// - Returns: A configuration that passed the framework's validation.
    /// - Throws: ``MacpoolError`` when a file or value is invalid or validation fails.
    static func make(
        bundle: VMBundle,
        settings: BundleSettings,
        model: VZMacHardwareModel,
        storage: VZMacAuxiliaryStorage,
        devices: MachineDevices,
    ) throws(MacpoolError) -> VZVirtualMachineConfiguration {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = try bundle.loadMachineIdentifier()
        platform.auxiliaryStorage = storage

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = settings.cpuCount
        configuration.memorySize = settings.memoryByteCount

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: displayWidth,
                heightInPixels: displayHeight,
                pixelsPerInch: displayPixelsPerInch,
            ),
        ]
        configuration.graphicsDevices = [graphics]

        let attachment: VZDiskImageStorageDeviceAttachment
        do {
            attachment = try VZDiskImageStorageDeviceAttachment(url: bundle.disk, readOnly: false)
        } catch {
            throw .framework("attaching the disk image", error)
        }
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        guard let address = VZMACAddress(string: settings.macAddress) else {
            throw .invalidBundle(
                path: bundle.settingsFile.filePath,
                reason: "invalid MAC address \(settings.macAddress)",
            )
        }
        let network = VZVirtioNetworkDeviceConfiguration()
        network.macAddress = address
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]

        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]

        if let directory = devices.sharedDirectory {
            configuration.directorySharingDevices = [sharingDevice(for: directory)]
        }

        do {
            try configuration.validate()
        } catch {
            throw .framework("validating the configuration", error)
        }
        return configuration
    }

    /// Builds the VirtioFS device that shares a host directory with a macOS guest.
    ///
    /// - Parameter directory: The host directory and whether the guest can only read it.
    /// - Returns: A device with the macOS automount tag.
    static func sharingDevice(for directory: SharedDirectory) -> VZVirtioFileSystemDeviceConfiguration {
        // The automount tag makes a macOS guest mount the share without any setup inside it.
        let device = VZVirtioFileSystemDeviceConfiguration(
            tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag,
        )
        device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(
            url: directory.url.absoluteURL,
            readOnly: directory.isReadOnly,
        ))
        return device
    }
}
