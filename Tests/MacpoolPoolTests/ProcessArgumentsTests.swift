import Foundation
@testable import MacpoolPool
import Testing

/// Tests of reading a process's arguments from the kernel.
struct ProcessArgumentsTests {
    /// Builds a buffer in the layout that `sysctl` returns for `KERN_PROCARGS2`.
    ///
    /// - Parameters:
    ///   - count: The argument count to write, which may differ from the strings that follow.
    ///   - strings: The arguments and then the environment, each written with a terminating zero.
    ///   - terminatesLast: Whether the last string gets its terminating zero.
    /// - Returns: The buffer.
    private static func buffer(count: UInt32, _ strings: [[UInt8]], terminatesLast: Bool = true) -> [UInt8] {
        var buffer = (0 ..< 4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) }
        buffer += Array("/opt/macpool".utf8) + [0, 0, 0, 0]
        for (index, string) in strings.enumerated() {
            buffer += string
            if terminatesLast || index < strings.count - 1 {
                buffer.append(0)
            }
        }
        return buffer
    }

    /// Decodes every counted argument byte for byte and ignores the environment.
    @Test func decodesArgumentsExactly() throws {
        let arguments = [
            "/opt/macpool",
            "supervise",
            "--data-dir",
            "/Users/me/caf\u{E9} \t\u{43F}\u{443}\u{43B}",
            "--lease",
            "0a1b2c3d",
            "--share",
            "",
        ]
        let strings = arguments.map { Array($0.utf8) } + [Array("HOME=/Users/me".utf8), [0xFF, 0xFE]]
        let buffer = Self.buffer(count: UInt32(arguments.count), strings)
        #expect(try ProcessArguments.parse(buffer) == arguments)
        #expect(try ProcessArguments.parse(Self.buffer(count: 0, [])) == [])
    }

    /// Reports a buffer that ends before the arguments it counts.
    @Test func reportsTruncatedBuffer() {
        let strings = [Array("/opt/macpool".utf8), Array("supervise".utf8)]
        #expect(throws: SupervisorMismatch.truncatedArguments) {
            try ProcessArguments.parse([2, 0, 0])
        }
        #expect(throws: SupervisorMismatch.truncatedArguments) {
            try ProcessArguments.parse([2, 0, 0, 0] + Array("/opt/macpool".utf8))
        }
        #expect(throws: SupervisorMismatch.truncatedArguments) {
            try ProcessArguments.parse(Self.buffer(count: 3, strings))
        }
        #expect(throws: SupervisorMismatch.truncatedArguments) {
            try ProcessArguments.parse(Self.buffer(count: 2, strings, terminatesLast: false))
        }
        // A negative count reads as more arguments than any buffer holds.
        #expect(throws: SupervisorMismatch.truncatedArguments) {
            try ProcessArguments.parse(Self.buffer(count: UInt32.max, strings))
        }
    }

    /// Reports an argument that is not valid UTF-8.
    @Test func reportsInvalidUTF8() {
        let strings = [Array("/opt/macpool".utf8), [0x63, 0x61, 0x66, 0xE9]]
        #expect(throws: SupervisorMismatch.invalidUTF8) {
            try ProcessArguments.parse(Self.buffer(count: 2, strings))
        }
    }

    /// Reads the test process's own arguments as the process received them.
    @Test func readsRunningProcess() throws {
        #expect(try ProcessArguments.read(processID: getpid()) == CommandLine.arguments)
    }

    /// Reports the error of `sysctl` for an identifier above the system's highest one.
    @Test func reportsUnreadableProcess() {
        #expect(throws: SupervisorMismatch.unreadableArguments(errno: EINVAL)) {
            try ProcessArguments.read(processID: 99_999_999)
        }
        #expect(SupervisorMismatch.unreadableArguments(errno: EINVAL).description.contains("errno 22"))
    }
}
