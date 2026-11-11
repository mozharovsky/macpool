import Foundation
import MacpoolVM

/// A guest that runs the commands of an image build.
///
/// `GuestSession` from MacpoolVM reaches a real guest. Tests replace it with a scripted one.
protocol ImageGuest: Sendable {
    /// Runs a command in the guest and waits until it ends.
    ///
    /// - Parameters:
    ///   - command: The command line that `/bin/sh` runs in the guest.
    ///   - asRoot: Whether `sudo` runs the command as root.
    ///   - timeLimit: The longest time the call may take.
    /// - Returns: The command's outputs and exit status.
    /// - Throws: `MacpoolError` when the command cannot run or does not finish in time.
    func runStep(_ command: String, asRoot: Bool, timeLimit: Duration) async throws(MacpoolError)
        -> GuestCommandResult
}

/// The SSH session that `image xcode` runs its steps through.
extension GuestSession: ImageGuest {
    /// Runs a command without input.
    ///
    /// - Parameters:
    ///   - command: The command line that `/bin/sh` runs in the guest.
    ///   - asRoot: Whether `sudo` runs the command as root.
    ///   - timeLimit: The longest time the call may take.
    /// - Returns: The command's outputs and exit status.
    /// - Throws: `MacpoolError` when the account cannot run the command, `ssh` cannot start, or
    ///   the command outlasts `timeLimit`.
    func runStep(_ command: String, asRoot: Bool, timeLimit: Duration) async throws(MacpoolError)
        -> GuestCommandResult {
        try await run(command, input: "", asRoot: asRoot, timeLimit: timeLimit)
    }
}

/// The guest side of `image xcode`, from the shared archive to an installed simulator runtime.
///
/// The steps install Xcode from `Xcode.xip`, accept its license, install its first launch
/// packages, add the simulator runtime from `Runtime.dmg`, and boot one simulator once. Checks
/// then confirm the result. If a step or a check fails, the build stops.
struct XcodeImageSteps {
    /// The directory where a macOS guest mounts the shared directory.
    static let sharedDirectory = "/Volumes/My Shared Files"

    /// The guest directory where the archive expands. The build removes it at the end.
    static let workDirectory = "/private/tmp/macpool-xcode"

    /// The least free space, in bytes, that the guest keeps for builds and simulators.
    static let minimumFreeBytes: UInt64 = 40 << 30

    /// The guest that runs the commands.
    let guest: any ImageGuest

    /// The simulator to boot, or `nil` for the first available iPhone.
    let deviceName: String?

    /// Runs the steps and the checks.
    ///
    /// - Returns: The builds of Xcode and of the simulator runtime.
    /// - Throws: ``CommandError/imageStep(step:reason:)`` when a step or a check fails, or
    ///   ``CommandError/library(_:)`` when a command cannot run or outlasts its time limit.
    func run() async throws(CommandError) -> XcodeImageBuilds {
        let shared = Self.sharedDirectory
        let work = Self.workDirectory
        // The guest mounts the share when the account logs in. That can happen after SSH is up.
        try await step(
            "finding the shared archive and runtime",
            "for i in $(seq 60); do test -r '\(shared)/Xcode.xip' && test -r '\(shared)/Runtime.dmg' && exit 0; "
                + "sleep 2; done; exit 1",
            timeLimit: .seconds(180),
        )
        try await step(
            "expanding Xcode",
            "rm -rf \(work) && mkdir \(work) && cd \(work) && /usr/bin/xip --expand '\(shared)/Xcode.xip'",
            timeLimit: .seconds(3600),
        )
        let build = try await xcodeBuild()
        let app = "/Applications/Xcode_\(build).app"
        try await step(
            "installing Xcode",
            "test ! -e \(app) && cd \(work) && mv -- *.app \(app) && /usr/bin/xcode-select -s \(app)",
            asRoot: true,
            timeLimit: .seconds(300),
        )
        try await step("accepting the Xcode license", "/usr/bin/xcodebuild -license accept", asRoot: true)
        try await step(
            "installing the first launch packages",
            "/usr/bin/xcodebuild -runFirstLaunch",
            asRoot: true,
            timeLimit: .seconds(1200),
        )
        try await step(
            "adding the simulator runtime",
            "/usr/bin/xcrun simctl runtime add '\(shared)/Runtime.dmg'",
            timeLimit: .seconds(1800),
        )
        let runtime = try await runtimeBuild()
        let device = try await device(for: runtime)
        try await step(
            "booting \(device.name)",
            "/usr/bin/xcrun simctl bootstatus \(device.udid) -b",
            timeLimit: .seconds(900),
        )
        try await step("shutting down \(device.name)", "/usr/bin/xcrun simctl shutdown \(device.udid)")
        try await check(build: build)
        try await step("removing the expanded archive", "rm -rf \(work)", asRoot: true)
        return XcodeImageBuilds(xcode: build, iosRuntime: runtime.buildversion)
    }

    /// Reads the build of the one app that the archive expanded to.
    ///
    /// - Returns: The build, such as `27A266a`.
    /// - Throws: ``CommandError/imageStep(step:reason:)`` when the archive held no single app or
    ///   its build is malformed.
    private func xcodeBuild() async throws(CommandError) -> String {
        let name = "reading the Xcode build"
        let output = try await step(
            name,
            "cd \(Self.workDirectory) && set -- *.app && [ $# -eq 1 ] && [ -d \"$1\" ] "
                + "&& /usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' \"$1/Contents/version.plist\"",
        )
        let build = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // The build names a directory in a root command, so it must need no quoting.
        guard !build.isEmpty, build.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw .imageStep(step: name, reason: "the archive's Xcode reports the build \"\(build)\"")
        }
        return build
    }

    /// Finds the iOS runtime that the build added.
    ///
    /// - Returns: The runtime.
    /// - Throws: ``CommandError/imageStep(step:reason:)`` when the guest lists no available iOS
    ///   runtime or more than one.
    private func runtimeBuild() async throws(CommandError) -> SimulatorRuntime {
        let name = "listing the simulator runtimes"
        let output = try await step(name, "/usr/bin/xcrun simctl list runtimes --json")
        guard let list = try? JSONDecoder().decode(SimulatorRuntimeList.self, from: Data(output.utf8)) else {
            throw .imageStep(step: name, reason: "simctl printed no runtime list")
        }
        let available = list.runtimes.filter { $0.platform == "iOS" && $0.isAvailable }
        guard available.count == 1, let runtime = available.first else {
            throw .imageStep(step: name, reason: "the guest has \(available.count) available iOS runtimes, not one")
        }
        return runtime
    }

    /// Finds the simulator to boot.
    ///
    /// - Parameter runtime: The runtime whose devices to search.
    /// - Returns: The device that ``deviceName`` names, or the first available iPhone.
    /// - Throws: ``CommandError/imageStep(step:reason:)`` when no such device exists.
    private func device(for runtime: SimulatorRuntime) async throws(CommandError) -> SimulatorDevice {
        let name = "listing the simulators"
        let output = try await step(name, "/usr/bin/xcrun simctl list devices available --json")
        guard let list = try? JSONDecoder().decode(SimulatorDeviceList.self, from: Data(output.utf8)) else {
            throw .imageStep(step: name, reason: "simctl printed no device list")
        }
        let devices = list.devices[runtime.identifier] ?? []
        let match = deviceName.map { wanted in devices.first { $0.name == wanted } }
            ?? devices.first { $0.name.hasPrefix("iPhone") }
        // A UDID goes into a command line, so it must be the hexadecimal UUID form.
        guard let match, UUID(uuidString: match.udid) != nil else {
            let wanted = deviceName ?? "an iPhone"
            throw .imageStep(step: name, reason: "\(runtime.identifier) has no available simulator named \(wanted)")
        }
        return match
    }

    /// Confirms that Xcode is the expected build, its license and packages are in place, and the
    /// guest has enough free space.
    ///
    /// - Parameter build: The build that the archive held.
    /// - Throws: ``CommandError/imageStep(step:reason:)`` when a check fails.
    private func check(build: String) async throws(CommandError) {
        let version = try await step("checking the Xcode version", "/usr/bin/xcodebuild -version")
        let reported = version.split(whereSeparator: \.isNewline).first { $0.hasPrefix("Build version ") }
        guard reported?.dropFirst("Build version ".count).trimmingCharacters(in: .whitespaces) == build else {
            throw .imageStep(step: "checking the Xcode version", reason: "xcodebuild reports \(version)")
        }
        try await step("checking the Xcode license", "/usr/bin/xcodebuild -license check")
        try await step("checking the first launch packages", "/usr/bin/xcodebuild -checkFirstLaunchStatus")
        let name = "checking the free space"
        let output = try await step(name, "/bin/df -k /System/Volumes/Data | /usr/bin/awk 'NR == 2 { print $4 }'")
        guard let kilobytes = UInt64(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .imageStep(step: name, reason: "df printed \(output)")
        }
        guard kilobytes >= Self.minimumFreeBytes / 1024 else {
            throw .imageStep(step: name, reason: "the guest has \(kilobytes >> 20) GiB free, less than 40 GiB")
        }
    }

    /// Runs one command and requires that it succeed.
    ///
    /// - Parameters:
    ///   - name: What the step does, for the error.
    ///   - command: The command line.
    ///   - asRoot: Whether `sudo` runs the command as root.
    ///   - timeLimit: The longest time the command may take.
    /// - Returns: The command's standard output.
    /// - Throws: ``CommandError/imageStep(step:reason:)`` when the command fails, or
    ///   ``CommandError/library(_:)`` when it cannot run or outlasts its time limit.
    @discardableResult
    private func step(
        _ name: String,
        _ command: String,
        asRoot: Bool = false,
        timeLimit: Duration = .seconds(120),
    ) async throws(CommandError) -> String {
        Report.line("step: \(name)")
        let result = try await library { () async throws(MacpoolError) in
            try await guest.runStep(command, asRoot: asRoot, timeLimit: timeLimit)
        }
        guard result.succeeded else {
            throw .imageStep(step: name, reason: result.failureSummary)
        }
        return result.output
    }
}

/// The builds that an Xcode image build installs.
struct XcodeImageBuilds: Equatable {
    /// The Xcode build, such as `27A266a`.
    let xcode: String

    /// The iOS simulator runtime build, such as `24A434`.
    let iosRuntime: String

    /// Creates the builds of an image record.
    ///
    /// - Parameter macOS: The guest's macOS build.
    /// - Returns: The builds keyed by `xcode`, `ios_runtime`, and `macos`.
    func record(macOS: String) -> [String: String] {
        ["xcode": xcode, "ios_runtime": iosRuntime, "macos": macOS]
    }
}

/// The part of `simctl list runtimes --json` that the build reads.
struct SimulatorRuntimeList: Decodable {
    /// The installed runtimes.
    let runtimes: [SimulatorRuntime]
}

/// An installed simulator runtime.
struct SimulatorRuntime: Decodable {
    /// The runtime's identifier, such as `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
    let identifier: String

    /// The platform, such as `iOS`.
    let platform: String

    /// The runtime's build, such as `24A434`.
    let buildversion: String

    /// Whether simulators can run on the runtime.
    let isAvailable: Bool
}

/// The part of `simctl list devices --json` that the build reads.
struct SimulatorDeviceList: Decodable {
    /// The devices, keyed by runtime identifier.
    let devices: [String: [SimulatorDevice]]
}

/// A simulator device.
struct SimulatorDevice: Decodable {
    /// The device's name, such as `iPhone 18 Pro`.
    let name: String

    /// The device's identifier.
    let udid: String
}
