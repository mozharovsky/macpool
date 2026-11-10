import Darwin

/// A reason why a process does not count as a lease's supervisor.
///
/// The daemon logs the reason with each signal it withholds, so a lease whose supervisor stays
/// unidentified shows why.
public enum SupervisorMismatch: Error, Sendable, Equatable, CustomStringConvertible {
    /// The process identifier is 0 or less and names no single process.
    case noProcess

    /// The kernel did not return the process's arguments.
    ///
    /// A process that exited and a process of another user fail this way.
    ///
    /// - Parameter errno: The error number that `sysctl` set.
    case unreadableArguments(errno: Int32)

    /// The kernel's argument buffer ends before the arguments that it counts.
    case truncatedArguments

    /// An argument is not valid UTF-8.
    case invalidUTF8

    /// The arguments do not run `supervise` for the lease in the data directory.
    case otherArguments

    /// The kernel did not return the process's start time.
    ///
    /// - Parameter errno: The error number that `proc_pidinfo` set.
    case unreadableStartTime(errno: Int32)

    /// The supervisor lock holds a start time line that is not a whole number or not terminated.
    case malformedStartTime

    /// The process started at another time than the supervisor recorded, so its identifier was
    /// reused.
    ///
    /// - Parameters:
    ///   - recorded: The start time from the supervisor lock, in microseconds since 1970.
    ///   - actual: The running process's start time, in microseconds since 1970.
    case startTimeDiffers(recorded: UInt64, actual: UInt64)

    /// A description for logs.
    public var description: String {
        switch self {
        case .noProcess:
            "no process is recorded"
        case let .unreadableArguments(code):
            "sysctl cannot read the arguments: \(String(cString: strerror(code))) (errno \(code))"
        case .truncatedArguments:
            "the argument buffer is truncated"
        case .invalidUTF8:
            "an argument is not valid UTF-8"
        case .otherArguments:
            "the arguments name another lease, directory, or command"
        case let .unreadableStartTime(code):
            "proc_pidinfo cannot read the start time: \(String(cString: strerror(code))) (errno \(code))"
        case .malformedStartTime:
            "the supervisor lock's start time line is malformed"
        case let .startTimeDiffers(recorded, actual):
            "the process started at \(actual) instead of the recorded \(recorded) microseconds"
        }
    }
}

/// Reads the arguments of a running process from the kernel.
///
/// The kernel returns the arguments exactly as the process received them, independent of the
/// locale. A tool such as `ps` instead escapes some bytes, depending on its own environment.
enum ProcessArguments {
    /// Reads a process's arguments, including the first one.
    ///
    /// - Parameter processID: The process. It must be greater than 0.
    /// - Returns: The arguments.
    /// - Throws: ``SupervisorMismatch/unreadableArguments(errno:)`` when `sysctl` fails, and
    ///   the errors of ``parse(_:)``.
    static func read(processID: Int32) throws(SupervisorMismatch) -> [String] {
        var name = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0 else {
            throw .unreadableArguments(errno: errno)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, u_int(name.count), &buffer, &size, nil, 0) == 0 else {
            throw .unreadableArguments(errno: errno)
        }
        return try parse(buffer.prefix(size))
    }

    /// Decodes the buffer that `sysctl` returns for `KERN_PROCARGS2`.
    ///
    /// The buffer starts with the argument count as a little-endian 32-bit integer. The
    /// executable's path follows with a terminating zero byte and zero bytes of padding. Then come
    /// the arguments and the environment, each with a terminating zero byte. The environment is
    /// not decoded.
    ///
    /// The padding cannot be told apart from an empty first argument, so such an argument is
    /// skipped and the list then shifts by one.
    ///
    /// - Parameter buffer: The bytes that `sysctl` wrote.
    /// - Returns: The arguments, including the first one.
    /// - Throws: ``SupervisorMismatch/truncatedArguments`` when the buffer ends before the counted
    ///   arguments, and ``SupervisorMismatch/invalidUTF8`` when an argument is not valid UTF-8.
    static func parse(_ buffer: some Collection<UInt8>) throws(SupervisorMismatch) -> [String] {
        let bytes = Array(buffer)
        guard bytes.count >= 4 else {
            throw .truncatedArguments
        }
        // A negative count reads as a large unsigned one, which the loop reports as truncated.
        let count = bytes[0 ..< 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard let pathEnd = bytes[4...].firstIndex(of: 0) else {
            throw .truncatedArguments
        }
        var start = bytes[pathEnd...].firstIndex { $0 != 0 } ?? bytes.endIndex
        var arguments: [String] = []
        while arguments.count < Int(count) {
            guard let end = bytes[start...].firstIndex(of: 0) else {
                throw .truncatedArguments
            }
            guard let argument = String(validating: bytes[start ..< end], as: UTF8.self) else {
                throw .invalidUTF8
            }
            arguments.append(argument)
            start = end + 1
        }
        return arguments
    }
}
