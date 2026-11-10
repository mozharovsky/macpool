import ArgumentParser
import Foundation
import MacpoolVM

/// Creates a VM bundle and installs macOS from a local IPSW into it.
///
/// The command holds the new bundle's lock during the install. When the install fails or a signal
/// interrupts it, the command removes the bundle.
struct CreateCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Creates a VM bundle and installs macOS from a local IPSW into it.",
    )

    /// The number of bytes in a gigabyte as the command line counts it.
    static let bytesPerGigabyte: UInt64 = 1 << 30

    /// The fraction of progress that the install must gain before the next progress line.
    static let progressStep = 0.05

    /// The interval between progress checks.
    static let progressInterval = Duration.seconds(10)

    /// The local IPSW file.
    @Option(help: "The local IPSW file.")
    var ipsw: String

    /// The bundle directory to create.
    @Option(help: "The bundle directory to create. It must not exist.")
    var bundle: String

    /// The logical size of the sparse disk image in gigabytes.
    ///
    /// The guest cannot grow its startup container later, because the recovery container follows
    /// it on the disk. The default leaves room for Xcode and an iOS simulator runtime. Together
    /// they do not fit beside macOS in 64 GB.
    @Option(name: .customLong("disk-gb"), help: "The logical size of the sparse disk image, in gigabytes.")
    var diskGigabytes: UInt64 = 128

    /// The number of virtual CPUs.
    @Option(help: "The number of virtual CPUs.")
    var cpus = 8

    /// The guest memory size in gigabytes.
    @Option(name: .customLong("memory-gb"), help: "The guest memory size, in gigabytes.")
    var memoryGigabytes: UInt64 = 16

    /// The diagnostic output options.
    @OptionGroup var logging: LoggingOptions

    /// Creates the bundle and installs macOS.
    ///
    /// - Throws: ``CommandError`` when the image is unusable, the host already runs two VMs, or the
    ///   install fails or is interrupted.
    func run() async throws {
        try await perform()
    }

    /// Converts a gigabyte count to bytes.
    ///
    /// - Parameter gigabytes: The size in gigabytes.
    /// - Returns: The size in bytes.
    /// - Throws: ``CommandError/invalidValue(_:)`` when the result does not fit in 64 bits.
    static func byteCount(gigabytes: UInt64) throws(CommandError) -> UInt64 {
        let (bytes, overflow) = gigabytes.multipliedReportingOverflow(by: bytesPerGigabyte)
        guard !overflow else {
            throw .invalidValue("\(gigabytes) GB is too large")
        }
        return bytes
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when the image is unusable, the host already runs two VMs, or the
    ///   install fails or is interrupted.
    private func perform() async throws(CommandError) {
        let ipswURL = URL(filePath: ipsw).absoluteURL
        let image = try await library { () async throws(MacpoolError) in
            try await RestoreImages.load(from: ipswURL)
        }
        Report.measure("image_build", image.build)
        Report.measure("image_minimum_cpus", image.minimumCPUCount)
        Report.measure("image_minimum_memory_bytes", image.minimumMemoryByteCount)
        let memoryByteCount = try Self.byteCount(gigabytes: memoryGigabytes)
        guard cpus >= image.minimumCPUCount, memoryByteCount >= image.minimumMemoryByteCount else {
            throw .insufficientResources(
                minimumCPUCount: image.minimumCPUCount,
                minimumMemoryByteCount: image.minimumMemoryByteCount,
            )
        }
        let settings = BundleSettings(
            cpuCount: cpus,
            memoryByteCount: memoryByteCount,
            macAddress: VMBundle.randomMACAddress(),
            build: image.build,
            hasBooted: false,
        )
        let target = VMBundle(root: URL(filePath: bundle))
        let diskByteCount = try Self.byteCount(gigabytes: diskGigabytes)
        let (machine, lock) = try library { () throws(MacpoolError) in
            let machine = try VirtualMachine.create(
                bundle: target,
                settings: settings,
                hardwareModel: image.hardwareModel,
                diskByteCount: diskByteCount,
                logger: logging.makeLogger(label: "macpool.vm"),
            )
            return try (machine, BundleLock(bundle: target))
        }
        defer { withExtendedLifetime(lock) {} }

        let clock = ContinuousClock()
        let started = clock.now
        let progress = Task {
            var lastReported = -1.0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
                // Only visible changes are printed, so the log stays short during a long install.
                if let fraction = await machine.installFractionCompleted, fraction - lastReported >= Self.progressStep {
                    lastReported = fraction
                    let seconds = Report.seconds(clock.now - started, decimals: 0)
                    Report.line("install progress \(Int((fraction * 100).rounded()))% after \(seconds) s")
                }
            }
        }
        defer { progress.cancel() }
        try await install(machine, from: ipswURL, into: target)
        Report.measure("install_seconds", Report.seconds(clock.now - started, decimals: 1))
        try Report.bundleSize(target)
    }

    /// Installs macOS and removes the new bundle when the install fails or a signal interrupts it.
    ///
    /// `SIGINT` and `SIGTERM` cancel the install instead of ending the process at once, so the
    /// installer stops the VM and the command can remove the directory it created.
    ///
    /// - Parameters:
    ///   - machine: The VM of the new bundle.
    ///   - restoreImage: The local IPSW file.
    ///   - target: The bundle that this command created.
    /// - Throws: ``CommandError/interrupted`` after a signal, or ``CommandError/library(_:)`` when
    ///   the install fails.
    private func install(
        _ machine: VirtualMachine,
        from restoreImage: URL,
        into target: VMBundle,
    ) async throws(CommandError) {
        let installation = Task { () async -> Result<Void, MacpoolError> in
            do throws(MacpoolError) {
                try await machine.install(from: restoreImage)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { installation.cancel() }
            source.resume()
            return source
        }
        let outcome = await installation.value
        for source in signals {
            source.cancel()
        }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        guard case let .failure(error) = outcome else {
            return
        }
        try? FileManager.default.removeItem(at: target.root)
        Report.line("removed the incomplete bundle \(target.root.path(percentEncoded: false))")
        throw installation.isCancelled ? .interrupted : .library(error)
    }
}
