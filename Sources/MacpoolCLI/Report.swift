import Foundation
import MacpoolVM

/// The command line's output.
///
/// Each line goes straight to the file descriptor, so a log that redirects standard output sees
/// it at once even while a long run continues.
enum Report {
    /// Prints one measurement in a form that logs can collect with `grep`.
    ///
    /// - Parameters:
    ///   - key: The measurement's name in snake case, such as `ssh_seconds`.
    ///   - value: The measured value.
    static func measure(_ key: String, _ value: some CustomStringConvertible) {
        line(measurementLine(key, value))
    }

    /// Formats one measurement line.
    ///
    /// - Parameters:
    ///   - key: The measurement's name.
    ///   - value: The measured value.
    /// - Returns: The line without a line break.
    static func measurementLine(_ key: String, _ value: some CustomStringConvertible) -> String {
        "measure \(key)=\(value)"
    }

    /// Prints a line on standard output.
    ///
    /// - Parameter text: The line without a line break.
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    /// Formats a duration in seconds with a fixed number of decimals.
    ///
    /// - Parameters:
    ///   - duration: The duration to format.
    ///   - decimals: The number of digits after the decimal point.
    /// - Returns: The seconds, such as `9.8`.
    static func seconds(_ duration: Duration, decimals: Int) -> String {
        String(format: "%.\(decimals)f", duration / .seconds(1))
    }

    /// Prints the logical and allocated sizes of a bundle's files.
    ///
    /// The allocated size counts blocks that a clone shares with its source, so the sum over
    /// several clones exceeds the space they really use.
    ///
    /// - Parameter bundle: The bundle to measure.
    /// - Throws: ``CommandError/library(_:)`` when the directory cannot be listed.
    static func bundleSize(_ bundle: VMBundle) throws(CommandError) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: bundle.root,
                includingPropertiesForKeys: Array(keys),
            )
        } catch {
            throw .library(.fileSystem(
                operation: "listing",
                path: bundle.root.path(percentEncoded: false),
                reason: error.localizedDescription,
            ))
        }
        var logical = 0
        var allocated = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: keys)
            logical += values?.fileSize ?? 0
            allocated += values?.totalFileAllocatedSize ?? 0
        }
        measure("bundle_logical_bytes", logical)
        measure("bundle_allocated_bytes", allocated)
    }
}
