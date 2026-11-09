import ArgumentParser
import Foundation
import MacpoolVM

/// Prints the address of a guest that `macpool run` runs, from the host's DHCP leases.
///
/// The command checks that a `run` holds the bundle's lock and that the lease has not expired. A
/// guest that just booted may not have its lease yet.
struct AddressCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "ip",
        abstract: "Prints the address of a running guest from the host's DHCP leases.",
    )

    /// The bundle whose guest address to print.
    @Option(help: "The bundle whose guest address to print.")
    var bundle: String

    /// Prints the address of the bundle's current lease.
    ///
    /// - Throws: ``CommandError`` when the bundle is unreadable, not running, or has no current
    ///   lease.
    func run() async throws {
        try perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when the bundle is unreadable, not running, or has no current
    ///   lease.
    private func perform() throws(CommandError) {
        let target = VMBundle(root: URL(filePath: bundle))
        let settings = try library { () throws(MacpoolError) in try target.settings() }
        guard BundleLock.isHeld(on: target) else {
            throw .notRunning(path: target.root.path(percentEncoded: false))
        }
        guard let macAddress = MACAddress(settings.macAddress),
              let lease = DHCPLeases.lease(for: macAddress),
              let expiry = lease.expiryDate,
              expiry > Date()
        else {
            throw .noLease(macAddress: settings.macAddress)
        }
        Report.line(lease.address)
    }
}
