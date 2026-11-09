import ArgumentParser

/// The `macpool` command line.
///
/// Each subcommand performs one step of a VM's lifecycle and prints `measure` lines with its
/// timings and sizes.
@main
struct Macpool: AsyncParsableCommand {
    /// The command's name, summary, and subcommands.
    static let configuration = CommandConfiguration(
        commandName: "macpool",
        abstract: "Creates, clones, and runs macOS VMs on this Mac.",
        version: "0.1.0",
        subcommands: [
            FetchCommand.self,
            CreateCommand.self,
            CloneCommand.self,
            RunCommand.self,
            AddressCommand.self,
        ],
    )
}
