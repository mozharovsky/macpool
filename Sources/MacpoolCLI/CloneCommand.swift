import ArgumentParser
import Foundation
import MacpoolVM

/// Clones a stopped bundle with APFS and gives the clone a fresh identity.
struct CloneCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Clones a stopped bundle with APFS and gives the clone a fresh identity.",
    )

    /// The stopped source bundle.
    @Option(help: "The stopped source bundle.")
    var from: String

    /// The clone's bundle directory.
    @Option(help: "The clone's bundle directory. It must not exist.")
    var to: String

    /// Clones the bundle and assigns the clone a new machine identifier and MAC address.
    ///
    /// - Throws: ``CommandError`` when the source is not a bundle, a command uses it, or the clone
    ///   fails.
    func run() async throws {
        try perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// The source's lock is held during the copy, so no VM can start from it or write to it while
    /// the clone captures its files.
    ///
    /// - Throws: ``CommandError`` when the source is not a bundle, a command uses it, or the clone
    ///   fails.
    private func perform() throws(CommandError) {
        let source = VMBundle(root: URL(filePath: from))
        _ = try library { () throws(MacpoolError) in try source.settings() }
        let lock = try library { () throws(MacpoolError) in try BundleLock(bundle: source) }
        defer { withExtendedLifetime(lock) {} }
        let clock = ContinuousClock()
        let started = clock.now
        let clone = try library { () throws(MacpoolError) in try source.clone(to: URL(filePath: to)) }
        let cloned = clock.now - started
        try library { () throws(MacpoolError) in try clone.assignIdentity() }
        Report.measure("clonefile_seconds", Report.seconds(cloned, decimals: 3))
        Report.measure("clone_seconds", Report.seconds(clock.now - started, decimals: 3))
        let settings = try library { () throws(MacpoolError) in try clone.settings() }
        Report.measure("clone_mac_address", settings.macAddress)
        try Report.bundleSize(clone)
    }
}
