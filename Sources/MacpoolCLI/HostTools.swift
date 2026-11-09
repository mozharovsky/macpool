import Foundation
import Subprocess
import System

/// Host processes and tools that the commands use beside the framework.
///
/// Every tool runs from its fixed system path, so the user's `PATH` cannot replace it.
enum HostTools {
    /// The command-line pattern of the framework's VM service.
    ///
    /// The guest's CPU threads run in this XPC service, which `launchd` starts for each VM.
    static let virtualMachineService = "com.apple.Virtualization.VirtualMachine"

    /// Lists this user's VM service processes.
    ///
    /// - Returns: The process identifiers, which are empty when none runs or `pgrep` fails.
    static func virtualMachineProcesses() async -> Set<Int32> {
        let user = String(getuid())
        guard let output = await output(of: "/usr/bin/pgrep", ["-U", user, "-f", virtualMachineService]) else {
            return []
        }
        return Set(output.split(whereSeparator: \.isNewline).compactMap { Int32($0) })
    }

    /// Finds the VM service process that appeared since an earlier listing.
    ///
    /// The framework starts one service process per VM, and the process belongs to no API, so
    /// the command compares listings from before the VM was created and after it started. When a
    /// second VM started in between, the command cannot tell the two apart and gives up.
    ///
    /// - Parameter earlier: The listing from before the VM was created.
    /// - Returns: The one new process, or `nil` when none or several appeared.
    static func newVirtualMachineProcess(since earlier: Set<Int32>) async -> Int32? {
        let added = await virtualMachineProcesses().subtracting(earlier)
        return added.count == 1 ? added.first : nil
    }

    /// Lowers the scheduling priority of a process.
    ///
    /// `nice` on this process does not reach the guest, because the VM runs in a separate service
    /// process.
    ///
    /// - Parameter processID: The process to lower.
    static func lowerPriority(of processID: Int32) async {
        _ = await output(of: "/usr/bin/renice", ["-n", "10", "-p", String(processID)])
    }

    /// Reads a process's resident set size.
    ///
    /// - Parameter processID: The process to inspect.
    /// - Returns: The size in kilobytes as `ps` prints it, or `nil` when `ps` fails.
    static func residentKilobytes(of processID: Int32) async -> String? {
        await output(of: "/bin/ps", ["-o", "rss=", "-p", String(processID)])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads a process's memory footprint summary.
    ///
    /// - Parameter processID: The process to inspect.
    /// - Returns: The `Footprint:` line of `footprint`, or `nil` when it is missing.
    static func footprint(of processID: Int32) async -> String? {
        await output(of: "/usr/bin/footprint", ["-p", String(processID)])?
            .split(whereSeparator: \.isNewline)
            .first { $0.contains("Footprint:") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Downloads a URL into a file with `curl`.
    ///
    /// Curl resumes an interrupted transfer and follows the CDN's redirects over HTTPS only. Its
    /// errors go to this process's standard error.
    ///
    /// - Parameters:
    ///   - url: The file to download.
    ///   - destination: The local file, which an interrupted earlier run may have started.
    /// - Throws: ``CommandError/tool(_:reason:)`` when curl cannot start or fails.
    static func download(_ url: URL, to destination: URL) async throws(CommandError) {
        let status: TerminationStatus
        do {
            status = try await run(
                .path("/usr/bin/curl"),
                arguments: [
                    "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
                    "--silent", "--show-error", "--continue-at", "-",
                    "--output", destination.path(percentEncoded: false), url.absoluteString,
                ],
                output: .currentStandardOutput,
                error: .currentStandardError,
            ).terminationStatus
        } catch {
            throw .tool("curl", reason: "\(error)")
        }
        guard status.isSuccess else {
            throw .tool("curl", reason: "ended with \(status)")
        }
    }

    /// Runs a tool and collects its standard output.
    ///
    /// - Parameters:
    ///   - path: The tool's absolute path.
    ///   - arguments: The tool's arguments.
    /// - Returns: The output, or `nil` when the tool cannot start or exits with a failure.
    private static func output(of path: FilePath, _ arguments: [String]) async -> String? {
        guard let result = try? await run(
                  .path(path),
                  arguments: Arguments(arguments),
                  output: .string(limit: 1 << 20),
              ),
              result.terminationStatus.isSuccess
        else {
            return nil
        }
        return result.standardOutput
    }
}
