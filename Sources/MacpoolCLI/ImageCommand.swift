import ArgumentParser
import Foundation
import MacpoolVM

/// Builds images that leases clone.
struct ImageCommand: AsyncParsableCommand {
    /// The subcommand's name, summary, and subcommands.
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Builds images that leases clone.",
        subcommands: [XcodeImageCommand.self],
    )
}

/// Builds an image with Xcode and an iOS simulator runtime from a stopped base bundle.
///
/// The command clones the base, boots the clone with the archive and the runtime in a read-only
/// shared directory, and installs both over SSH. It accepts the Xcode license in the guest, so it
/// runs only with `--accept-xcode-license`. Checks then confirm the Xcode build, the license, the
/// first launch packages, the runtime, and the free space. The guest shuts itself down, and the
/// clone becomes `images/NAME` in the data directory with a ready image record.
///
/// If the build fails, or `SIGINT`, `SIGTERM`, or `SIGHUP` interrupts it, the command stops the VM
/// and deletes the clone. With `--keep-failed` it keeps the clone as `images/NAME` with a record
/// that is not ready. The daemon refuses to lease such an image.
struct XcodeImageCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "xcode",
        abstract: "Builds an image with Xcode and an iOS simulator runtime.",
    )

    /// The message for a build without `--accept-xcode-license`.
    static let licenseMessage = """
    image xcode accepts the Xcode and Apple SDKs license agreement in the guest. \
    Read the agreement, then pass --accept-xcode-license.
    """

    /// The stopped base bundle.
    @Option(help: "The stopped base bundle. It must have booted, and its disk must have 128 GB.")
    var from: String

    /// The image's name.
    @Option(help: "The image's name. The image goes to images/NAME in the data directory.")
    var name: String

    /// The Xcode archive.
    @Option(help: "The Xcode archive (.xip) that you downloaded.")
    var xcode: String

    /// The iOS simulator runtime disk image.
    @Option(help: "The iOS simulator runtime disk image (.dmg).")
    var runtime: String

    /// Whether the person accepts the Xcode license for the guest.
    @Flag(
        name: .customLong("accept-xcode-license"),
        help: "Accepts the Xcode and Apple SDKs license agreement in the guest. The command needs it.",
    )
    var acceptsXcodeLicense = false

    /// The simulator that the build boots once, or `nil` for the first available iPhone.
    @Option(help: "The simulator that the build boots once. The default is the first available iPhone.")
    var device: String?

    /// Whether a failed build keeps its clone.
    @Flag(name: .customLong("keep-failed"), help: "Keeps a failed image as not ready instead of deleting it.")
    var keepFailed = false

    /// The longest wait for the guest's address, SSH server, and credential rotation, in seconds.
    @Option(name: .customLong("boot-timeout"), help: "The longest wait for the guest to be ready, in seconds.")
    var bootTimeout = 900

    /// The daemon's data directory.
    @OptionGroup var location: PoolOptions

    /// The diagnostic output options.
    @OptionGroup var logging: LoggingOptions

    /// Rejects a build without the license flag, a malformed name, and a timeout below 1.
    ///
    /// - Throws: `ValidationError` before the command touches any file.
    func validate() throws {
        guard acceptsXcodeLicense else {
            throw ValidationError(Self.licenseMessage)
        }
        guard ImageWorkspace.isValidName(name) else {
            throw ValidationError("""
            --name takes 1 to 64 ASCII letters, digits, dots, hyphens, and underscores, \
            starting with a letter or digit.
            """)
        }
        guard bootTimeout > 0 else {
            throw ValidationError("--boot-timeout takes a positive number of seconds.")
        }
    }

    /// Builds the image.
    ///
    /// - Throws: ``CommandError`` when an input is missing, the base cannot serve, a step or a
    ///   check fails, the VM stops early, or a signal interrupts the build.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` as ``run()`` describes.
    private func perform() async throws(CommandError) {
        let clock = ContinuousClock()
        let started = clock.now
        let base = VMBundle(root: URL(filePath: from).absoluteURL)
        let workspace = ImageWorkspace(directory: location.directory, name: name)
        let deviceName = device
        try await workspace.build(
            from: base,
            xcode: URL(filePath: xcode).absoluteURL,
            runtime: URL(filePath: runtime).absoluteURL,
            keepFailed: keepFailed,
            watchSignals: { interrupted in
                // Closing the terminal sends SIGHUP. Without a watch, it ends the build without cleanup.
                let watch = SignalWatch(signals: SignalWatch.signals + [SIGHUP]) { _ in interrupted.set() }
                return { watch.cancel() }
            },
        ) { building, inputs, interrupted async throws(CommandError) in
            try await buildInGuest(building, inputs: inputs, device: deviceName, interrupted: interrupted)
        }
        Report.measure("image_seconds", Report.seconds(clock.now - started, decimals: 1))
        Report.line("image=\(workspace.image.path(percentEncoded: false))")
    }

    /// Boots the clone, runs the build in the guest, and waits until the guest shuts down.
    ///
    /// - Parameters:
    ///   - building: The clone of the base.
    ///   - inputs: The directory that the guest reads the archive and the runtime from.
    ///   - device: The simulator to boot once, or `nil` for the first available iPhone.
    ///   - interrupted: The flag that a signal sets. Once it is set, the VM stops.
    /// - Returns: The builds of Xcode and of the simulator runtime.
    /// - Throws: ``CommandError`` when the VM does not become ready, a step fails, the guest does
    ///   not shut down, or a signal stops the VM.
    private func buildInGuest(
        _ building: VMBundle,
        inputs: URL,
        device: String?,
        interrupted: StopFlag,
    ) async throws(CommandError) -> XcodeImageBuilds {
        let stop = StopFlag()
        let (addresses, continuation) = AsyncStream.makeStream(of: String.self)
        let session = MachineSession(
            target: building,
            sharedDirectory: SharedDirectory(url: inputs, isReadOnly: true),
            provision: false,
            waitSSH: true,
            timeout: bootTimeout,
            hold: nil,
            stopMode: .immediate,
            logging: logging,
            isStopRequested: { stop.isSet || interrupted.isSet },
            onReady: { continuation.yield($0) },
        )
        let running = Task { () async -> Result<MachineSession.Ending, CommandError> in
            defer { continuation.finish() }
            do throws(CommandError) {
                return try await .success(session.run())
            } catch {
                return .failure(error)
            }
        }
        var ready = addresses.makeAsyncIterator()
        guard let address = await ready.next() else {
            stop.set()
            if case let .failure(error) = await running.value {
                throw error
            }
            throw .invalidValue("the VM stopped before it was ready")
        }
        let builds: XcodeImageBuilds
        do throws(CommandError) {
            let guest = try library { () throws(MacpoolError) in
                try GuestSession(bundle: building, address: address)
            }
            builds = try await XcodeImageSteps(guest: guest, deviceName: device).run()
            Report.line("step: shutting down the guest")
            // The delay lets ssh report the status before the guest drops the connection.
            let shutdown = try await library { () async throws(MacpoolError) in
                try await guest.runStep(
                    "(sleep 1; /sbin/shutdown -h now) >/dev/null 2>&1 &",
                    asRoot: true,
                    timeLimit: .seconds(60),
                )
            }
            guard shutdown.succeeded else {
                throw .imageStep(step: "shutting down the guest", reason: shutdown.failureSummary)
            }
        } catch {
            stop.set()
            _ = await running.value
            throw error
        }
        let watchdog = Task {
            try? await Task.sleep(for: Self.shutdownTimeout)
            stop.set()
        }
        let ending = await running.value
        watchdog.cancel()
        switch ending {
        case .success(.guestStopped):
            return builds
        case .success(.stopped):
            throw .imageStep(step: "shutting down the guest", reason: "the guest did not stop within 180 s")
        case let .failure(error):
            throw error
        }
    }

    /// The longest wait for the guest to stop after the shutdown command.
    static let shutdownTimeout = Duration.seconds(180)
}
