public import Foundation
public import Logging
import Virtualization

/// A host directory that a macOS guest mounts automatically under `/Volumes/My Shared Files`.
public struct SharedDirectory: Sendable, Equatable {
    /// The host directory that the guest sees.
    public var url: URL

    /// Whether the guest can only read the directory.
    ///
    /// If the share is read-only, the framework rejects every write from the guest. The host's
    /// files then stay unchanged.
    public var isReadOnly: Bool

    /// Creates a shared directory.
    ///
    /// - Parameters:
    ///   - url: The host directory.
    ///   - isReadOnly: Whether the guest can only read the directory.
    public init(url: URL, isReadOnly: Bool = false) {
        self.url = url
        self.isReadOnly = isReadOnly
    }
}

/// Devices that a VM receives beyond its fixed set.
public struct MachineDevices: Sendable, Equatable {
    /// A host directory that the guest mounts, or `nil` for none.
    public var sharedDirectory: SharedDirectory?

    /// Creates a device selection.
    ///
    /// - Parameter sharedDirectory: A host directory to share with the guest through VirtioFS.
    public init(sharedDirectory: SharedDirectory? = nil) {
        self.sharedDirectory = sharedDirectory
    }
}

/// The run state of a VM.
public enum MachineState: Sendable, Hashable {
    /// The VM is stopped and can start.
    case stopped
    /// The VM runs.
    case running
    /// The VM is paused.
    case paused
    /// The VM stopped because of an error.
    case error
    /// The VM is starting.
    case starting
    /// The VM is pausing.
    case pausing
    /// The VM is resuming.
    case resuming
    /// The VM is stopping.
    case stopping
    /// The VM saves its state.
    case saving
    /// The VM restores its state.
    case restoring
    /// A state that this library does not know yet.
    case unknown
}

/// One macOS VM, confined to the serial queue that the framework requires.
///
/// The actor's executor is the VM's dispatch queue. Every framework call therefore runs on that
/// queue, and the compiler rejects any access from elsewhere. The framework also calls the
/// completion handlers and the delegate on the same queue, so no run loop or main thread is needed.
///
/// The VM runs in a framework XPC service that belongs to this process. It stops when the process
/// exits.
///
/// The actor logs lifecycle steps at `info`, configuration details at `debug`, and framework
/// events at `notice` or above. Every message carries the bundle name as `vm` metadata, and the
/// application chooses the level and the destination through its logging backend.
public actor VirtualMachine {
    /// The serial queue that owns the VM and serves as the actor's executor.
    private let queue: DispatchSerialQueue

    /// The framework's VM.
    private let machine: VZVirtualMachine

    /// The delegate, which the VM holds weakly.
    private let delegate: MachineDelegate

    /// The buffer that the delegate posts events to.
    private let mailbox: EventMailbox

    /// The installer while an install runs.
    private var installer: VZMacOSInstaller?

    /// The logger for lifecycle diagnostics, with the bundle name as metadata.
    private let logger: Logger

    /// The VM's queue as the actor's executor.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Creates a stopped VM for an existing bundle.
    ///
    /// - Parameters:
    ///   - bundle: A bundle with a disk, auxiliary storage, hardware model, and machine identifier.
    ///   - devices: Devices beyond the fixed set.
    ///   - logger: The logger for lifecycle diagnostics. The VM adds the bundle name as `vm`
    ///     metadata.
    /// - Throws: ``MacpoolError`` when a bundle file is invalid or the configuration fails the
    ///   framework's validation.
    public init(
        bundle: VMBundle,
        devices: MachineDevices = MachineDevices(),
        logger: Logger = Logger(label: "macpool.vm"),
    ) throws(MacpoolError) {
        let settings = try bundle.settings()
        let model = try Self.hardwareModel(
            FileSystem.read(bundle.hardwareModel, for: "reading the hardware model"),
            path: bundle.hardwareModel,
        )
        let storage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorage)
        try self.init(
            bundle: bundle,
            settings: settings,
            model: model,
            storage: storage,
            devices: devices,
            logger: logger,
        )
    }

    /// Creates a VM from a configuration's parts.
    ///
    /// - Parameters:
    ///   - bundle: The bundle that provides the disk and machine identifier.
    ///   - settings: The bundle's settings.
    ///   - model: The hardware model.
    ///   - storage: The auxiliary storage.
    ///   - devices: Devices beyond the fixed set.
    ///   - logger: The logger for lifecycle diagnostics.
    /// - Throws: ``MacpoolError`` when the configuration is invalid.
    private init(
        bundle: VMBundle,
        settings: BundleSettings,
        model: VZMacHardwareModel,
        storage: VZMacAuxiliaryStorage,
        devices: MachineDevices,
        logger: Logger,
    ) throws(MacpoolError) {
        var logger = logger
        logger[metadataKey: "vm"] = "\(bundle.root.lastPathComponent)"
        let configuration = try MachineConfiguration.make(
            bundle: bundle,
            settings: settings,
            model: model,
            storage: storage,
            devices: devices,
        )
        let queue = DispatchSerialQueue(label: "macpool.machine.\(bundle.root.lastPathComponent)")
        let mailbox = EventMailbox()
        let delegate = MachineDelegate(mailbox: mailbox, logger: logger)
        // Creating the VM on its queue keeps even the first calls to it where the framework expects them.
        let machine = queue.sync {
            let machine = VZVirtualMachine(configuration: configuration, queue: queue)
            machine.delegate = delegate
            return machine
        }
        self.queue = queue
        self.machine = machine
        self.delegate = delegate
        self.mailbox = mailbox
        self.logger = logger
        logger.debug("Created the VM", metadata: [
            "cpus": "\(settings.cpuCount)",
            "memory_bytes": "\(settings.memoryByteCount)",
            "mac_address": "\(settings.macAddress)",
            "shared_directory": "\(devices.sharedDirectory?.url.path(percentEncoded: false) ?? "none")",
            "shared_directory_read_only": "\(devices.sharedDirectory?.isReadOnly ?? false)",
        ])
    }

    /// Creates a bundle and a stopped VM for installing macOS into it.
    ///
    /// The call creates the directory, the settings, the sparse disk, a fresh machine identifier,
    /// and the auxiliary storage for the image's hardware model. When a later step fails, the call
    /// removes the directory it created.
    ///
    /// - Parameters:
    ///   - bundle: The bundle to create. Its directory must not exist, and its parent must.
    ///   - settings: The CPU, memory, MAC, and build settings to store.
    ///   - hardwareModel: The serialized hardware model from the restore image.
    ///   - diskByteCount: The logical disk size in bytes.
    ///   - logger: The logger for lifecycle diagnostics.
    /// - Returns: A stopped VM that is ready for ``install(from:)``.
    /// - Throws: ``MacpoolError`` when a file cannot be created or the configuration is invalid.
    public static func create(
        bundle: VMBundle,
        settings: BundleSettings,
        hardwareModel: Data,
        diskByteCount: UInt64,
        logger: Logger = Logger(label: "macpool.vm"),
    ) throws(MacpoolError) -> VirtualMachine {
        do {
            try FileManager.default.createDirectory(at: bundle.root, withIntermediateDirectories: false)
        } catch {
            throw .fileSystem("creating the bundle", bundle.root, error)
        }
        do {
            return try populate(
                bundle: bundle,
                settings: settings,
                hardwareModel: hardwareModel,
                diskByteCount: diskByteCount,
                logger: logger,
            )
        } catch {
            try? FileManager.default.removeItem(at: bundle.root)
            throw error
        }
    }

    /// Writes a new bundle's files and creates its VM.
    ///
    /// - Parameters:
    ///   - bundle: The bundle, whose directory exists and is empty.
    ///   - settings: The settings to store.
    ///   - hardwareModel: The serialized hardware model from the restore image.
    ///   - diskByteCount: The logical disk size in bytes.
    ///   - logger: The logger for lifecycle diagnostics.
    /// - Returns: A stopped VM that is ready for ``install(from:)``.
    /// - Throws: ``MacpoolError`` when a file cannot be created or the configuration is invalid.
    private static func populate(
        bundle: VMBundle,
        settings: BundleSettings,
        hardwareModel: Data,
        diskByteCount: UInt64,
        logger: Logger,
    ) throws(MacpoolError) -> VirtualMachine {
        try bundle.writeSettings(settings)
        try FileSystem.write(hardwareModel, to: bundle.hardwareModel, for: "writing the hardware model")
        try FileSystem.write(
            VZMacMachineIdentifier().dataRepresentation,
            to: bundle.machineIdentifier,
            for: "writing the machine identifier",
        )
        try bundle.createDisk(byteCount: diskByteCount)
        let model = try Self.hardwareModel(hardwareModel, path: bundle.hardwareModel)
        let storage: VZMacAuxiliaryStorage
        do {
            storage = try VZMacAuxiliaryStorage(
                creatingStorageAt: bundle.auxiliaryStorage,
                hardwareModel: model,
                options: [],
            )
        } catch {
            throw .framework("creating auxiliary storage", error)
        }
        return try VirtualMachine(
            bundle: bundle,
            settings: settings,
            model: model,
            storage: storage,
            devices: MachineDevices(),
            logger: logger,
        )
    }

    /// Installs macOS from a local restore image and returns when the installer finishes.
    ///
    /// Read ``installFractionCompleted`` from another task to follow the progress. Cancelling the
    /// calling task cancels the installer, and the call then throws the installer's error. The
    /// bundle is unusable after a failed or cancelled install.
    ///
    /// - Parameter restoreImage: The local IPSW file.
    /// - Throws: ``MacpoolError/virtualMachineLimitReached`` when the host already runs two macOS
    ///   VMs, or ``MacpoolError/framework(operation:domain:code:description:)`` when the installer
    ///   fails or is cancelled.
    public func install(from restoreImage: URL) async throws(MacpoolError) {
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: restoreImage.absoluteURL)
        self.installer = installer
        defer { self.installer = nil }
        logger.info("Installing macOS", metadata: ["restore_image": "\(restoreImage.path(percentEncoded: false))"])
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                installer.install { result in
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            Task { await self.cancelInstall() }
        }
        do {
            try result.get()
        } catch {
            logger.error("The install failed", metadata: ["error": "\(error.localizedDescription)"])
            throw .framework("installing macOS", error)
        }
        logger.info("Installed macOS")
    }

    /// Cancels the running install, if any.
    ///
    /// The installer stops the VM and reports the cancellation through its completion handler.
    private func cancelInstall() {
        logger.notice("Cancelling the install")
        installer?.progress.cancel()
    }

    /// The completed fraction of the running install, from 0 to 1.
    ///
    /// The value is `nil` while no install runs.
    public var installFractionCompleted: Double? {
        installer?.progress.fractionCompleted
    }

    /// Starts the VM and returns when the framework reports the start.
    ///
    /// - Parameter provisioning: The account and services to set up. The guest applies them only
    ///   on its first boot after an install and ignores them afterward.
    /// - Throws: ``MacpoolError/virtualMachineLimitReached`` when the host already runs two macOS
    ///   VMs, or ``MacpoolError/framework(operation:domain:code:description:)`` when the VM cannot
    ///   start or the framework rejects the provisioning options.
    public func start(provisioning: GuestProvisioning? = nil) async throws(MacpoolError) {
        let options = try provisioning?.startOptions() ?? VZMacOSVirtualMachineStartOptions()
        logger.info("Starting the VM", metadata: ["provisioning": "\(provisioning != nil)"])
        do {
            try await machine.start(options: options)
        } catch {
            logger.error("The VM did not start", metadata: ["error": "\(error.localizedDescription)"])
            throw .framework("starting the VM", error)
        }
        logger.info("Started the VM")
    }

    /// Asks the guest to shut down, like a press of the power button.
    ///
    /// A macOS guest answers with a dialog and keeps running, so callers fall back to ``stop()``
    /// when no ``MachineEvent/guestStopped`` event follows.
    ///
    /// - Throws: ``MacpoolError/framework(operation:domain:code:description:)`` when the VM cannot
    ///   accept the request in its current state.
    public func requestStop() throws(MacpoolError) {
        logger.info("Requesting a guest stop")
        do {
            try machine.requestStop()
        } catch {
            throw .framework("requesting a guest stop", error)
        }
    }

    /// Stops the VM at once, without the guest's cooperation.
    ///
    /// The guest loses data that it has not written, so callers prefer a shutdown from inside the
    /// guest.
    ///
    /// - Throws: ``MacpoolError/framework(operation:domain:code:description:)`` when the framework
    ///   cannot stop the VM, for example because the guest stopped first.
    public func stop() async throws(MacpoolError) {
        logger.info("Stopping the VM")
        do {
            try await machine.stop()
        } catch {
            logger.error("The VM did not stop", metadata: ["error": "\(error.localizedDescription)"])
            throw .framework("stopping the VM", error)
        }
        logger.info("Stopped the VM")
    }

    /// The VM's current run state.
    public var state: MachineState {
        switch machine.state {
        case .stopped: .stopped
        case .running: .running
        case .paused: .paused
        case .error: .error
        case .starting: .starting
        case .pausing: .pausing
        case .resuming: .resuming
        case .stopping: .stopping
        case .saving: .saving
        case .restoring: .restoring
        @unknown default: .unknown
        }
    }

    /// Returns the next lifecycle event, waiting at most for a timeout.
    ///
    /// Each event is delivered once. Events that arrive while no task waits stay buffered in
    /// order.
    ///
    /// Cancelling the waiting task ends the wait at once and returns `nil`, as a timeout does.
    ///
    /// - Parameter timeout: The longest wait. A zero timeout only takes a buffered event.
    /// - Returns: The oldest undelivered event, or `nil` when none arrived in time or the waiting
    ///   task was cancelled.
    /// - Throws: ``MacpoolError/eventWaitInProgress`` when another task already waits.
    public nonisolated func nextEvent(within timeout: Duration) async throws(MacpoolError) -> MachineEvent? {
        try await mailbox.next(within: timeout)
    }

    /// Decodes and checks a serialized hardware model.
    ///
    /// - Parameters:
    ///   - data: The serialized model.
    ///   - path: The file that held the data, for error messages.
    /// - Returns: A model that this host supports.
    /// - Throws: ``MacpoolError`` when the data is invalid or the host cannot run the model.
    private static func hardwareModel(_ data: Data, path: URL) throws(MacpoolError) -> VZMacHardwareModel {
        guard let model = VZMacHardwareModel(dataRepresentation: data) else {
            throw .invalidBundle(path: path.filePath, reason: "not a hardware model")
        }
        guard model.isSupported else {
            throw .unsupported(reason: "the bundle's hardware model is not supported on this host")
        }
        return model
    }
}

/// The VM delegate, which forwards framework callbacks to an event mailbox.
///
/// The framework calls it on the VM's queue and holds it weakly, so the owning ``VirtualMachine``
/// keeps it alive.
private final class MachineDelegate: NSObject, VZVirtualMachineDelegate {
    /// The buffer that receives the events.
    private let mailbox: EventMailbox

    /// The logger that records each event as it arrives.
    private let logger: Logger

    /// Creates a delegate that posts to a mailbox.
    ///
    /// - Parameters:
    ///   - mailbox: The buffer that receives the events.
    ///   - logger: The logger that records each event.
    init(mailbox: EventMailbox, logger: Logger) {
        self.mailbox = mailbox
        self.logger = logger
    }

    /// Records that the guest shut itself down.
    ///
    /// - Parameter virtualMachine: The VM that stopped.
    func guestDidStop(_: VZVirtualMachine) {
        logger.notice("The guest stopped")
        mailbox.post(.guestStopped)
    }

    /// Records that the VM stopped because of an error.
    ///
    /// - Parameters:
    ///   - virtualMachine: The VM that stopped.
    ///   - error: The framework's error.
    func virtualMachine(_: VZVirtualMachine, didStopWithError error: any Error) {
        logger.error("The VM stopped with an error", metadata: ["error": "\(error.localizedDescription)"])
        mailbox.post(.stoppedWithError(description: error.localizedDescription))
    }

    /// Records that a network attachment disconnected.
    ///
    /// - Parameters:
    ///   - virtualMachine: The running VM.
    ///   - networkDevice: The device whose attachment disconnected.
    ///   - error: The framework's error.
    func virtualMachine(
        _: VZVirtualMachine,
        networkDevice _: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error,
    ) {
        logger.warning("The network attachment disconnected", metadata: ["error": "\(error.localizedDescription)"])
        mailbox.post(.networkDisconnected(description: error.localizedDescription))
    }
}
