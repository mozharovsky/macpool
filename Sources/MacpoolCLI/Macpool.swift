import ArgumentParser

/// The `macpool` command line.
///
/// The VM subcommands perform one step of a VM's lifecycle and print `measure` lines with their
/// timings and sizes. The pool subcommands run the daemon and lease clones from it.
@main
struct Macpool: AsyncParsableCommand {
    /// The command's name, summary, and subcommands.
    static let configuration = CommandConfiguration(
        commandName: "macpool",
        abstract: "Creates, clones, runs, and leases macOS VMs on this Mac.",
        version: "0.1.0",
        subcommands: [
            FetchCommand.self,
            CreateCommand.self,
            CloneCommand.self,
            RunCommand.self,
            AddressCommand.self,
            DaemonCommand.self,
            LeaseCommand.self,
            ReleaseCommand.self,
            RenewCommand.self,
            ListCommand.self,
            HostCommand.self,
            PoolCommand.self,
            ImageCommand.self,
            SuperviseCommand.self,
        ],
    )
}
