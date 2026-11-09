import Foundation
import MacpoolVM
import Subprocess
import System
import Testing

/// End-to-end tests that boot a real VM through the signed `macpool` binary.
///
/// The tests run only when `MACPOOL_VM_TEST_BUNDLE` names a stopped, provisioned bundle. The
/// framework requires the virtualization entitlement in the process that creates a VM, which a
/// test runner lacks, so the tests drive the binary that `Scripts/build.sh` signs. Set
/// `MACPOOL_BINARY` to use another signed binary.
///
/// Each test clones the bundle beside itself, boots the clone, and deletes the clone afterward.
/// Run them on a host where no other VM runs, because the command refuses to start beside one.
@Suite(.enabled(if: VirtualMachineTestEnvironment.bundlePath != nil, "set MACPOOL_VM_TEST_BUNDLE to run VM tests"))
struct VirtualMachineRunTests {
    /// The output and status of one command.
    struct CommandResult {
        /// The command's standard output.
        let output: String
        /// Whether the command exited with status zero.
        let succeeded: Bool
    }

    /// Clones the bundle, boots the clone to SSH, replaces its inherited credentials, and stops it.
    ///
    /// The clone must end with its own password and a pinned host key that differs from any key
    /// the source pins.
    @Test(.timeLimit(.minutes(10)))
    func bootsCloneToSSH() async throws {
        let source = try URL(filePath: #require(VirtualMachineTestEnvironment.bundlePath)).absoluteURL
        let clone = source.deletingLastPathComponent().appending(path: "test-clone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: clone) }

        let cloned = try await Self.macpool([
            "clone",
            "--from",
            source.path(percentEncoded: false),
            "--to",
            clone.path(percentEncoded: false),
        ])
        #expect(cloned.succeeded)
        #expect(cloned.output.contains("measure clone_mac_address="))

        let run = try await Self.macpool([
            "run", "--bundle", clone.path(percentEncoded: false), "--wait-ssh", "--timeout", "300", "--hold", "0",
        ])
        #expect(run.succeeded)
        #expect(run.output.contains("measure ip_address="))
        #expect(run.output.contains("measure ssh_seconds="))
        #expect(run.output.contains("\nready\n"))
        #expect(run.output.contains("measure stop="))
        #expect(run.output.contains("measure rotate_seconds="))
        #expect(run.output.contains("measure host_key=SHA256:"))

        let sourceBundle = VMBundle(root: source)
        let cloneBundle = VMBundle(root: clone)
        #expect(try cloneBundle.settings().credentialRotation == .finished)
        let sourceAccount = try GuestAccount.load(from: sourceBundle.guestAccountFile)
        let cloneAccount = try GuestAccount.load(from: cloneBundle.guestAccountFile)
        #expect(cloneAccount.username == sourceAccount.username)
        #expect(cloneAccount.password != sourceAccount.password)
        let sourceKeys = try HostKey.pinnedKeys(inKnownHosts: String(
            contentsOf: sourceBundle.knownHostsFile,
            encoding: .utf8,
        ))
        let cloneKeys = try HostKey.pinnedKeys(inKnownHosts: String(
            contentsOf: cloneBundle.knownHostsFile,
            encoding: .utf8,
        ))
        #expect(cloneKeys.count == 1)
        #expect(cloneKeys.allSatisfy { !sourceKeys.contains($0) })
        #expect(!FileManager.default
            .fileExists(atPath: cloneBundle.rotatingGuestAccountFile.path(percentEncoded: false)))
    }

    /// Runs the binary and collects its output.
    ///
    /// - Parameter arguments: The subcommand and its options.
    /// - Returns: The output and whether the command succeeded.
    /// - Throws: An error when the binary cannot start.
    static func macpool(_ arguments: [String]) async throws -> CommandResult {
        let result = try await run(
            .path(FilePath(VirtualMachineTestEnvironment.binaryPath)),
            arguments: Arguments(arguments),
            output: .string(limit: 1 << 20),
            error: .currentStandardError,
        )
        return CommandResult(output: result.standardOutput, succeeded: result.terminationStatus.isSuccess)
    }
}

/// The environment variables that enable and configure the VM tests.
enum VirtualMachineTestEnvironment {
    /// The provisioned bundle that the tests clone, or `nil` when the tests are off.
    static let bundlePath = ProcessInfo.processInfo.environment["MACPOOL_VM_TEST_BUNDLE"]

    /// The signed binary that the tests run.
    static let binaryPath = ProcessInfo.processInfo.environment["MACPOOL_BINARY"] ?? ".build/release/macpool"
}
