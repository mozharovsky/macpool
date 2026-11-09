import ArgumentParser
import Foundation
import MacpoolVM

/// Finds the newest supported restore image and optionally downloads it.
struct FetchCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Finds the latest supported restore image and optionally downloads it.",
    )

    /// Whether to download the IPSW into the cache directory.
    @Flag(help: "Downloads the IPSW into the cache directory.")
    var download = false

    /// The directory that receives the IPSW.
    @Option(help: "The directory that receives the IPSW.")
    var cache = ".cache/ipsw"

    /// Looks up the image, prints its details, and downloads it when asked.
    ///
    /// - Throws: ``CommandError`` when the lookup or the download fails, or the IPSW exists.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when the lookup or the download fails, or the IPSW exists.
    private func perform() async throws(CommandError) {
        let clock = ContinuousClock()
        let started = clock.now
        let image = try await library { () async throws(MacpoolError) in
            try await RestoreImages.latestSupported()
        }
        Report.measure("fetch_latest_seconds", Report.seconds(clock.now - started, decimals: 2))
        Report.measure("restore_url", image.url.absoluteString)
        Report.measure("restore_build", image.build)
        Report.measure("restore_version", image.version)
        Report.measure("restore_host", image.url.host() ?? "")
        guard download else {
            return
        }

        let directory = URL(filePath: cache).absoluteURL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .library(.fileSystem(
                operation: "creating",
                path: directory.path(percentEncoded: false),
                reason: error.localizedDescription,
            ))
        }
        let target = directory.appending(path: "\(image.build).ipsw")
        guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            throw .fileExists(path: target.path(percentEncoded: false))
        }
        let partial = directory.appending(path: "\(image.build).ipsw.partial")
        let downloadStarted = clock.now
        try await HostTools.download(image.url, to: partial)
        let elapsed = clock.now - downloadStarted
        let bytes: Int
        do {
            try FileManager.default.moveItem(at: partial, to: target)
            bytes = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw .library(.fileSystem(
                operation: "finishing the download",
                path: target.path(percentEncoded: false),
                reason: error.localizedDescription,
            ))
        }
        Report.measure("download_seconds", Report.seconds(elapsed, decimals: 1))
        Report.measure("download_bytes", bytes)
        let megabitsPerSecond = Double(bytes) * 8 / (elapsed / .seconds(1)) / 1e6
        Report.measure("download_mbit_per_second", String(format: "%.0f", megabitsPerSecond))
        Report.measure("ipsw_path", target.path(percentEncoded: false))
    }
}
