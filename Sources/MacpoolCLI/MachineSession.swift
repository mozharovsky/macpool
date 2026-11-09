import Foundation
import Logging
import MacpoolVM

/// One boot of a bundle, from taking its lock to stopping the VM.
///
/// `macpool run` and the daemon's supervisors both boot bundles through a session. The session
/// prints `ready` once the guest has an address and, when asked, answers on SSH. It then holds the
/// VM until the hold time ends, a stop is requested, or the guest shuts itself down. A stop that is
/// requested before `ready` stops the VM and fails the session.
///
/// The session holds the bundle's lock while it runs. It records the first boot in the bundle's
/// settings, refuses a first boot without provisioning, and refuses provisioning after it,
/// because the guest applies provisioning only on its first boot after the install.
///
/// On a clone's first boot the session replaces the guest password and SSH host keys that the
/// clone inherited, through `CredentialRotation` from MacpoolVM, before it prints `ready`. It
/// waits for SSH for that step even when SSH is not otherwise awaited, and the step must end
/// before the timeout. A stop request and a stop of the VM end the step early.
///
/// When the rotation fails, times out, or ends early, the session stops the VM. A failure after
/// the guest started to change leaves a record that later boots refuse.
struct MachineSession {
    /// How the session stops a VM that is still running at its end.
    enum StopMode {
        /// Asks the guest to shut down and forces the stop when it does not within 90 seconds.
        case requestThenForce
        /// Forces the stop at once, for a clone that is deleted afterward.
        case immediate
    }

    /// How a session that did not fail ended.
    enum Ending: Equatable {
        /// The guest shut itself down.
        case guestStopped
        /// The hold time ended or a stop was requested, and the session stopped the VM.
        case stopped
    }

    /// The interval between DHCP lease checks.
    static let leaseInterval = Duration.milliseconds(250)

    /// The interval between SSH banner checks.
    static let sshInterval = Duration.milliseconds(500)

    /// The longest wait for a VM event between checks for a stop request during the credential
    /// rotation.
    static let rotationWatchInterval = Duration.milliseconds(500)

    /// The hold time after which the session samples the VM's memory.
    static let memorySampleDelay = Duration.seconds(60)

    /// The longest wait for the guest to answer a stop request.
    ///
    /// macOS answers the virtual power button with a dialog and keeps running, so a guest that
    /// nobody shuts down from inside ends with a forced stop after this wait.
    static let stopRequestTimeout = Duration.seconds(90)

    /// The bundle to boot.
    let target: VMBundle

    /// A host directory to share with the guest, or `nil`.
    let sharedDirectory: URL?

    /// Whether to provision the guest with the account stored in the bundle.
    let provision: Bool

    /// Whether to wait for the guest's SSH server after its address appears.
    let waitSSH: Bool

    /// The longest wait for the guest's address, SSH server, and credential rotation, in seconds.
    let timeout: Int

    /// How long the VM keeps running once it is ready, or `nil` to hold it until a stop request or
    /// a guest shutdown.
    let hold: Duration?

    /// How the session stops a VM that is still running at its end.
    let stopMode: StopMode

    /// The diagnostic output options.
    let logging: LoggingOptions

    /// Reports whether someone asked the session to stop.
    ///
    /// The session calls it several times a second. It removes the bundle's `stop-request` file
    /// before the boot and once it acts on a request, so a check of that file ends with the
    /// session.
    let isStopRequested: @Sendable () -> Bool

    /// Receives the guest's address when the VM becomes ready.
    let onReady: @Sendable (String) -> Void

    /// Boots the VM, measures the time to its network and SSH, holds it, and stops it.
    ///
    /// - Returns: How the session ended.
    /// - Throws: ``CommandError`` when the bundle is in use, the boot record rules out the
    ///   provisioning choice, the VM cannot start, a step times out, a stop is requested before
    ///   the VM is ready, the credential rotation fails, or the VM stops early.
    func run() async throws(CommandError) -> Ending {
        // The lock comes before the settings, so a rotation that another run is still performing
        // reads as in progress rather than as an abandoned one.
        let lock = try lockBundle(target)
        defer { withExtendedLifetime(lock) {} }
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

        let earlierProcesses = await HostTools.virtualMachineProcesses()
        let devices = MachineDevices(sharedDirectory: sharedDirectory)
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
            return try await attend(
                machine,
                processID: processID,
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
    ///   - processID: The VM's service process, or `nil` when the session could not identify it.
    ///   - macAddress: The guest's MAC address.
    ///   - previousLease: The guest's lease before this boot, which a new boot replaces.
    ///   - started: The time the start began.
    ///   - rotatesCredentials: Whether the bundle is a clone whose inherited credentials this boot
    ///     replaces before the VM counts as ready.
    /// - Returns: How the session ended.
    /// - Throws: ``CommandError`` when a step times out, a stop is requested before `ready`, the
    ///   credential rotation fails, or the VM stops early.
    private func attend(
        _ machine: VirtualMachine,
        processID: Int32?,
        macAddress: MACAddress,
        previousLease: DHCPLease?,
        started: ContinuousClock.Instant,
        rotatesCredentials: Bool,
    ) async throws(CommandError) -> Ending {
        let clock = ContinuousClock()
        if let processID {
            Report.measure("vm_pid", processID)
            await HostTools.lowerPriority(of: processID)
        }

        let deadline = started + .seconds(timeout)
        var lease = DHCPLeases.lease(for: macAddress)
        while lease == nil || lease == previousLease {
            try await checkEvents(machine)
            try checkStopRequest()
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
                try checkStopRequest()
                guard clock.now < deadline else {
                    throw .timedOut(step: "SSH banner", seconds: timeout)
                }
                try? await Task.sleep(for: Self.sshInterval)
            }
            Report.measure("ssh_seconds", Report.seconds(clock.now - started, decimals: 1))
        }
        if rotatesCredentials {
            let rotating = clock.now
            let key = try await rotateCredentials(machine, address: address, deadline: deadline)
            Report.measure("rotate_seconds", Report.seconds(clock.now - rotating, decimals: 1))
            Report.measure("host_key", key.fingerprint)
        }
        try checkStopRequest()
        Report.line("ready")
        onReady(address)

        // Memory is sampled while the guest still runs, because a shutdown from inside the guest
        // can end the hold at any moment.
        var sampled = false
        let holdStarted = clock.now
        while hold.map({ clock.now - holdStarted < $0 }) ?? true, !isStopRequested() {
            switch try await nextEvent(machine, within: .seconds(1)) {
            case nil:
                break
            case .guestStopped:
                Report.measure("stop", "guest")
                return .guestStopped
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
        try? FileManager.default.removeItem(at: target.stopRequest)
        try await stop(machine)
        return .stopped
    }

    /// Replaces a clone's inherited credentials while watching for a stop request and a VM stop.
    ///
    /// The rotation and the watch run as sibling tasks. The first one to end cancels the other,
    /// and cancelling the rotation ends its running `ssh`, so the bundle keeps the state that the
    /// rotation had reached.
    ///
    /// - Parameters:
    ///   - machine: The running VM.
    ///   - address: The guest's IPv4 address.
    ///   - deadline: The time by which the rotation must end.
    /// - Returns: The guest's new host key.
    /// - Throws: ``CommandError/library(_:)`` when the rotation fails or times out,
    ///   ``CommandError/stopRequested`` when a stop is requested, ``CommandError/stopped(_:)`` when
    ///   the VM stops, and ``CommandError/interrupted`` when the calling task is cancelled.
    private func rotateCredentials(
        _ machine: VirtualMachine,
        address: String,
        deadline: ContinuousClock.Instant,
    ) async throws(CommandError) -> HostKey {
        let logger = logging.makeLogger(label: "macpool.credentials")
        let timeout = deadline - ContinuousClock.now
        let target = target
        let isStopRequested = isStopRequested
        let event = await withTaskGroup(of: RotationEvent.self) { group in
            group.addTask {
                do throws(MacpoolError) {
                    return try await .finished(.success(CredentialRotation.rotate(
                        bundle: target,
                        address: address,
                        timeout: timeout,
                        logger: logger,
                    )))
                } catch {
                    return .finished(.failure(error))
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    if isStopRequested() {
                        return .stopRequested
                    }
                    do throws(MacpoolError) {
                        switch try await machine.nextEvent(within: Self.rotationWatchInterval) {
                        case nil:
                            break
                        case let .networkDisconnected(description):
                            Report.line("network attachment disconnected: \(description)")
                        case let event?:
                            return .machineStopped(event)
                        }
                    } catch {
                        return .finished(.failure(error))
                    }
                }
                return .watchCancelled
            }
            let first = await group.next() ?? .watchCancelled
            group.cancelAll()
            return first
        }
        switch event {
        case let .finished(.success(key)):
            return key
        case let .finished(.failure(error)):
            throw .library(error)
        case .stopRequested:
            try checkStopRequest()
            throw .stopRequested
        case let .machineStopped(event):
            throw .stopped(event)
        case .watchCancelled:
            throw .interrupted
        }
    }

    /// Stops a VM that is still running at the session's end.
    ///
    /// - Parameter machine: The running VM.
    /// - Throws: ``CommandError`` when the VM rejects the request or the forced stop fails.
    private func stop(_ machine: VirtualMachine) async throws(CommandError) {
        let clock = ContinuousClock()
        let stopping = clock.now
        if stopMode == .immediate {
            try await library { () async throws(MacpoolError) in try await machine.stop() }
            Report.measure("stop", "forced")
            Report.measure("stop_seconds", Report.seconds(clock.now - stopping, decimals: 1))
            return
        }
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

    /// Fails when someone asked the session to stop, and removes the bundle's stop-request file.
    ///
    /// - Throws: ``CommandError/stopRequested`` when a stop was requested.
    private func checkStopRequest() throws(CommandError) {
        if isStopRequested() {
            try? FileManager.default.removeItem(at: target.stopRequest)
            throw .stopRequested
        }
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

/// The first of the events that end a credential rotation.
private enum RotationEvent: Sendable {
    /// The rotation ended, or the VM's event stream failed.
    case finished(Result<HostKey, MacpoolError>)
    /// A stop was requested.
    case stopRequested
    /// The VM stopped.
    case machineStopped(MachineEvent)
    /// The watch ended because its task was cancelled.
    case watchCancelled
}
