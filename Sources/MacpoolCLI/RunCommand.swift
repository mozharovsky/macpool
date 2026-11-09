import ArgumentParser
import Foundation
import Logging
import MacpoolVM

/// Boots a bundle headless, waits for its network, and stops it on request.
///
/// The command prints `ready` once the guest has an address and, when asked, answers on SSH. It
/// then holds the VM until the hold time ends, the bundle's `stop-request` file appears, or the
/// guest shuts itself down.
///
/// The command holds the bundle's lock while it runs. It records the first boot in the bundle's
/// settings, refuses a first boot without `--provision`, and refuses `--provision` after it,
/// because the guest applies provisioning only on its first boot after the install.
///
/// On a clone's first run the command replaces the guest password and SSH host keys that the
/// clone inherited, through `CredentialRotation` from MacpoolVM, before it prints `ready`. It
/// waits for SSH for that step even without `--wait-ssh`. When the rotation fails, the command
/// stops the VM. A failure after the guest started to change leaves a record that later runs
/// refuse.
struct RunCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Boots a bundle headless, waits for its network, and stops it on request.",
    )

    /// The interval between DHCP lease checks.
    static let leaseInterval = Duration.milliseconds(250)

    /// The interval between SSH banner checks.
    static let sshInterval = Duration.milliseconds(500)

    /// The hold time after which the command samples the VM's memory.
    static let memorySampleDelay = Duration.seconds(60)

    /// The longest wait for the guest to answer a stop request.
    ///
    /// macOS answers the virtual power button with a dialog and keeps running, so a guest that
    /// nobody shuts down from inside ends with a forced stop after this wait.
    static let stopRequestTimeout = Duration.seconds(90)

    /// The bundle to boot.
    @Option(help: "The bundle to boot.")
    var bundle: String

    /// A host directory to share with the guest.
    @Option(help: "A host directory to share with the guest through VirtioFS.")
    var share: String?

    /// Whether to provision the guest with the account stored in the bundle.
    @Flag(help: "Provisions the guest on its first boot with the account stored in the bundle.")
    var provision = false

    /// Whether to wait for the guest's SSH server after its address appears.
    @Flag(
        name: .customLong("wait-ssh"),
        help: """
        Waits for the guest's SSH server after its address appears. \
        A clone's first run always waits, because it replaces the inherited credentials over SSH.
        """,
    )
    var waitSSH = false

    /// The longest wait for the guest's address and SSH server, in seconds.
    @Option(help: "The longest wait for the guest's address and SSH server, in seconds.")
    var timeout = 900

    /// The time the VM keeps running once it is ready, in seconds.
    @Option(
        help: """
        The time the VM keeps running once it is ready, in seconds. \
        Creating the bundle's stop-request file ends the run sooner.
        """,
    )
    var hold = 0

    /// The diagnostic output options.
    @OptionGroup var logging: LoggingOptions

    /// Rejects negative durations.
    ///
    /// - Throws: `ValidationError` when the timeout or the hold time is negative.
    func validate() throws {
        guard timeout >= 0, hold >= 0 else {
            throw ValidationError("--timeout and --hold take seconds of zero or more.")
        }
    }

    /// Boots the VM, measures the time to its network and SSH, holds it, and stops it.
    ///
    /// - Throws: ``CommandError`` when the bundle is in use, the boot record rules out the
    ///   provisioning choice, the VM cannot start, a step times out, or the VM stops early.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when the bundle is in use, the boot record rules out the
    ///   provisioning choice, the VM cannot start, a step times out, or the VM stops early.
    private func perform() async throws(CommandError) {
        let target = VMBundle(root: URL(filePath: bundle))
        var settings = try library { () throws(MacpoolError) in try target.settings() }
        guard let macAddress = MACAddress(settings.macAddress) else {
            throw .invalidValue("the bundle's MAC address \(settings.macAddress) is malformed")
        }
        let logger = logging.makeLogger(label: "macpool.run")
        if settings.credentialRotation == .started {
            throw .library(.credentialRotationIncomplete(path: target.root.path(percentEncoded: false)))
        }
        switch (settings.hasBooted, provision) {
        case (false, false):
            throw .firstBootNeedsProvisioning
        case (true, true):
            throw .provisioningAfterFirstBoot
        case (nil, true):
            logger.warning("The bundle does not record its first boot. The guest ignores provisioning after it.")
        default:
            break
        }
        let lock = try library { () throws(MacpoolError) in try BundleLock(bundle: target) }
        defer { withExtendedLifetime(lock) {} }

        let earlierProcesses = await HostTools.virtualMachineProcesses()
        let devices = MachineDevices(sharedDirectory: share.map { URL(filePath: $0).absoluteURL })
        let machine = try library { () throws(MacpoolError) in
            try VirtualMachine(bundle: target, devices: devices, logger: logging.makeLogger(label: "macpool.vm"))
        }
        var provisioning: GuestProvisioning?
        if provision {
            let account = try library { () throws(MacpoolError) in try GuestAccount.loadOrCreate(in: target) }
            provisioning = GuestProvisioning(account: account)
        }
        let previousLease = DHCPLeases.lease(for: macAddress)
        try? FileManager.default.removeItem(at: target.stopRequest)

        let clock = ContinuousClock()
        let started = clock.now
        try await library { [provisioning] () async throws(MacpoolError) in
            try await machine.start(provisioning: provisioning)
        }
        Report.measure("start_seconds", Report.seconds(clock.now - started, decimals: 2))
        if settings.hasBooted != true {
            settings.hasBooted = true
            do {
                try target.writeSettings(settings)
            } catch {
                logger.error("The bundle could not record its first boot", metadata: ["error": "\(error)"])
            }
        }
        let processID = await HostTools.newVirtualMachineProcess(since: earlierProcesses)
        do {
            try await attend(
                machine,
                processID: processID,
                target: target,
                macAddress: macAddress,
                previousLease: previousLease,
                started: started,
                rotatesCredentials: settings.credentialRotation == .pending,
            )
        } catch {
            // The VM would otherwise keep running until this process exits.
            try? await machine.stop()
            throw error
        }
    }

    /// Waits for the guest's network, holds the VM, and stops it.
    ///
    /// - Parameters:
    ///   - machine: The started VM.
    ///   - processID: The VM's service process, or `nil` when the command could not identify it.
    ///   - target: The VM's bundle.
    ///   - macAddress: The guest's MAC address.
    ///   - previousLease: The guest's lease before this boot, which a new boot replaces.
    ///   - started: The time the start began.
    ///   - rotatesCredentials: Whether the bundle is a clone whose inherited credentials this run
    ///     replaces before the VM counts as ready.
    /// - Throws: ``CommandError`` when a step times out, the credential rotation fails, or the VM
    ///   stops early.
    private func attend(
        _ machine: VirtualMachine,
        processID: Int32?,
        target: VMBundle,
        macAddress: MACAddress,
        previousLease: DHCPLease?,
        started: ContinuousClock.Instant,
        rotatesCredentials: Bool,
    ) async throws(CommandError) {
        let clock = ContinuousClock()
        if let processID {
            Report.measure("vm_pid", processID)
            await HostTools.lowerPriority(of: processID)
        }

        let deadline = started + .seconds(timeout)
        var lease = DHCPLeases.lease(for: macAddress)
        while lease == nil || lease == previousLease {
            try await checkEvents(machine)
            guard clock.now < deadline else {
                throw .timedOut(step: "DHCP lease", seconds: timeout)
            }
            try? await Task.sleep(for: Self.leaseInterval)
            lease = DHCPLeases.lease(for: macAddress)
        }
        let address = lease?.address ?? ""
        Report.measure("ip_seconds", Report.seconds(clock.now - started, decimals: 1))
        Report.measure("ip_address", address)

        if waitSSH || rotatesCredentials {
            while await !SSHProbe.answers(host: address) {
                try await checkEvents(machine)
                guard clock.now < deadline else {
                    throw .timedOut(step: "SSH banner", seconds: timeout)
                }
                try? await Task.sleep(for: Self.sshInterval)
            }
            Report.measure("ssh_seconds", Report.seconds(clock.now - started, decimals: 1))
        }
        if rotatesCredentials {
            let rotating = clock.now
            let logger = logging.makeLogger(label: "macpool.credentials")
            let key = try await library { () async throws(MacpoolError) in
                try await CredentialRotation.rotate(bundle: target, address: address, logger: logger)
            }
            Report.measure("rotate_seconds", Report.seconds(clock.now - rotating, decimals: 1))
            Report.measure("host_key", key.fingerprint)
        }
        Report.line("ready")

        // Memory is sampled while the guest still runs, because a shutdown from inside the guest
        // can end the hold at any moment.
        var sampled = false
        let holdStarted = clock.now
        let stopRequest = target.stopRequest.path(percentEncoded: false)
        while clock.now - holdStarted < .seconds(hold), !FileManager.default.fileExists(atPath: stopRequest) {
            switch try await nextEvent(machine, within: .seconds(1)) {
            case nil:
                break
            case .guestStopped:
                Report.measure("stop", "guest")
                return
            case let .networkDisconnected(description):
                Report.line("network attachment disconnected: \(description)")
            case let event?:
                throw .stopped(event)
            }
            if !sampled, clock.now - holdStarted >= Self.memorySampleDelay, let processID {
                sampled = true
                await reportMemory(of: processID)
            }
        }
        if !sampled, let processID {
            await reportMemory(of: processID)
        }
        try? FileManager.default.removeItem(atPath: stopRequest)
        try await stop(machine)
    }

    /// Asks the guest to stop and forces the stop when it does not.
    ///
    /// - Parameter machine: The running VM.
    /// - Throws: ``CommandError`` when the VM rejects the request or the forced stop fails.
    private func stop(_ machine: VirtualMachine) async throws(CommandError) {
        let clock = ContinuousClock()
        let stopping = clock.now
        try await library { () async throws(MacpoolError) in try await machine.requestStop() }
        var event = try await nextEvent(machine, within: Self.stopRequestTimeout)
        while case .networkDisconnected = event, clock.now - stopping < Self.stopRequestTimeout {
            event = try await nextEvent(machine, within: Self.stopRequestTimeout - (clock.now - stopping))
        }
        switch event {
        case .guestStopped:
            Report.measure("stop", "guest")
        case let .stoppedWithError(description):
            throw .stopped(.stoppedWithError(description: description))
        case nil, .networkDisconnected:
            Report.line("guest did not stop on request")
            try await library { () async throws(MacpoolError) in try await machine.stop() }
            Report.measure("stop", "forced")
        }
        Report.measure("stop_seconds", Report.seconds(clock.now - stopping, decimals: 1))
    }

    /// Fails when the VM reported that it stopped.
    ///
    /// - Parameter machine: The running VM.
    /// - Throws: ``CommandError/stopped(_:)`` when the VM stopped.
    private func checkEvents(_ machine: VirtualMachine) async throws(CommandError) {
        switch try await nextEvent(machine, within: .zero) {
        case nil:
            break
        case let .networkDisconnected(description):
            Report.line("network attachment disconnected: \(description)")
        case let event?:
            throw .stopped(event)
        }
    }

    /// Waits for the VM's next event.
    ///
    /// - Parameters:
    ///   - machine: The running VM.
    ///   - timeout: The longest wait.
    /// - Returns: The event, or `nil` when none arrived in time.
    /// - Throws: ``CommandError/library(_:)`` when another task already waits.
    private func nextEvent(_ machine: VirtualMachine, within timeout: Duration) async throws(CommandError)
        -> MachineEvent? {
        try await library { () async throws(MacpoolError) in try await machine.nextEvent(within: timeout) }
    }

    /// Prints the resident size and memory footprint of the VM's service process.
    ///
    /// - Parameter processID: The VM's service process.
    private func reportMemory(of processID: Int32) async {
        if let kilobytes = await HostTools.residentKilobytes(of: processID) {
            Report.measure("vm_rss_kilobytes", kilobytes)
        }
        if let footprint = await HostTools.footprint(of: processID) {
            Report.measure("vm_footprint", footprint)
        }
    }
}
