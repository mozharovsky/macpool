import ArgumentParser
import Foundation
@testable import MacpoolCLI
@testable import MacpoolPool
@testable import MacpoolVM
import Testing

/// Tests of `image xcode` that run without a VM.
struct XcodeImageTests {
    /// Runs every step in order and returns the builds that the guest reports.
    @Test func runsStepsInOrder() async throws {
        let guest = ScriptedGuest()
        let builds = try await XcodeImageSteps(guest: guest, deviceName: nil).run()
        #expect(builds == XcodeImageBuilds(xcode: "27A266a", iosRuntime: "24A434"))
        #expect(builds.record(macOS: "26B123") == ["xcode": "27A266a", "ios_runtime": "24A434", "macos": "26B123"])

        let calls = await guest.calls
        let shared = XcodeImageSteps.sharedDirectory
        let work = XcodeImageSteps.workDirectory
        let app = "/Applications/Xcode_27A266a.app"
        let expected = [
            GuestCall(
                command: "for i in $(seq 60); do test -r '\(shared)/Xcode.xip' && test -r '\(shared)/Runtime.dmg' "
                    + "&& exit 0; sleep 2; done; exit 1",
                asRoot: false,
                timeLimit: .seconds(180),
            ),
            GuestCall(
                command: "rm -rf \(work) && mkdir \(work) && cd \(work) && /usr/bin/xip --expand '\(shared)/Xcode.xip'",
                asRoot: false,
                timeLimit: .seconds(3600),
            ),
            GuestCall(
                command: "cd \(work) && set -- *.app && [ $# -eq 1 ] && [ -d \"$1\" ] "
                    + "&& /usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' \"$1/Contents/version.plist\"",
                asRoot: false,
                timeLimit: .seconds(120),
            ),
            GuestCall(
                command: "test ! -e \(app) && cd \(work) && mv -- *.app \(app) && /usr/bin/xcode-select -s \(app)",
                asRoot: true,
                timeLimit: .seconds(300),
            ),
            GuestCall(command: "/usr/bin/xcodebuild -license accept", asRoot: true, timeLimit: .seconds(120)),
            GuestCall(command: "/usr/bin/xcodebuild -runFirstLaunch", asRoot: true, timeLimit: .seconds(1200)),
            GuestCall(
                command: "/usr/bin/xcrun simctl runtime add '\(shared)/Runtime.dmg'",
                asRoot: false,
                timeLimit: .seconds(1800),
            ),
            GuestCall(command: "/usr/bin/xcrun simctl list runtimes --json", asRoot: false, timeLimit: .seconds(120)),
            GuestCall(
                command: "/usr/bin/xcrun simctl list devices available --json",
                asRoot: false,
                timeLimit: .seconds(120),
            ),
            GuestCall(
                command: "/usr/bin/xcrun simctl bootstatus \(ScriptedGuest.iPhone) -b",
                asRoot: false,
                timeLimit: .seconds(900),
            ),
            GuestCall(
                command: "/usr/bin/xcrun simctl shutdown \(ScriptedGuest.iPhone)",
                asRoot: false,
                timeLimit: .seconds(120),
            ),
            GuestCall(command: "/usr/bin/xcodebuild -version", asRoot: false, timeLimit: .seconds(120)),
            GuestCall(command: "/usr/bin/xcodebuild -license check", asRoot: false, timeLimit: .seconds(120)),
            GuestCall(
                command: "/usr/bin/xcodebuild -checkFirstLaunchStatus",
                asRoot: false,
                timeLimit: .seconds(120),
            ),
            GuestCall(
                command: "/bin/df -k /System/Volumes/Data | /usr/bin/awk 'NR == 2 { print $4 }'",
                asRoot: false,
                timeLimit: .seconds(120),
            ),
            GuestCall(command: "rm -rf \(work)", asRoot: true, timeLimit: .seconds(120)),
        ]
        #expect(calls == expected)
    }

    /// Boots the simulator that `--device` names.
    @Test func bootsNamedDevice() async throws {
        let guest = ScriptedGuest()
        _ = try await XcodeImageSteps(guest: guest, deviceName: "iPad Air").run()
        #expect(await guest.calls.contains { $0.command.contains("bootstatus \(ScriptedGuest.iPad) -b") })
    }

    /// Stops when the named simulator does not exist.
    @Test func refusesMissingDevice() async {
        let guest = ScriptedGuest()
        await #expect(throws: CommandError.imageStep(
            step: "listing the simulators",
            reason: "\(ScriptedGuest.runtime) has no available simulator named iPhone 1",
        )) {
            try await XcodeImageSteps(guest: guest, deviceName: "iPhone 1").run()
        }
    }

    /// Stops before the root install when the archive's build could break a command line.
    @Test func refusesMalformedBuild() async {
        let guest = ScriptedGuest(replies: ["PlistBuddy": .success("27A; rm -rf /\n")])
        await #expect(throws: CommandError.imageStep(
            step: "reading the Xcode build",
            reason: #"the archive's Xcode reports the build "27A; rm -rf /""#,
        )) {
            try await XcodeImageSteps(guest: guest, deviceName: nil).run()
        }
        #expect(await guest.calls.allSatisfy { !$0.asRoot })
    }

    /// Stops when the guest has a runtime besides the added one.
    @Test func refusesSecondRuntime() async {
        let second = ScriptedGuest.runtimeList(extra: #"{"identifier": "b", "platform": "iOS", "#
            + #""buildversion": "23A1", "isAvailable": true}"#)
        let guest = ScriptedGuest(replies: ["list runtimes": .success(second)])
        await #expect(throws: CommandError.imageStep(
            step: "listing the simulator runtimes",
            reason: "the guest has 2 available iOS runtimes, not one",
        )) {
            try await XcodeImageSteps(guest: guest, deviceName: nil).run()
        }
    }

    /// Fails the license check when `xcodebuild` reports that the license is not accepted.
    @Test func failsLicenseCheck() async {
        let guest = ScriptedGuest(replies: ["-license check": .failure(69, "license not accepted")])
        await #expect(throws: CommandError.imageStep(
            step: "checking the Xcode license",
            reason: "ssh exited(69): license not accepted",
        )) {
            try await XcodeImageSteps(guest: guest, deviceName: nil).run()
        }
    }

    /// Fails when the guest has less than 40 GB free, and survives a free size beyond 64 bits.
    @Test func checksFreeSpace() async {
        let low = ScriptedGuest(replies: ["df -k": .success("\((39 << 30) / 1024)\n")])
        await #expect(throws: CommandError.imageStep(
            step: "checking the free space",
            reason: "the guest has 39 GB free, less than 40 GB",
        )) {
            try await XcodeImageSteps(guest: low, deviceName: nil).run()
        }
        let huge = ScriptedGuest(replies: ["df -k": .success("\(UInt64.max)\n")])
        await #expect(throws: Never.self) {
            try await XcodeImageSteps(guest: huge, deviceName: nil).run()
        }
    }

    /// Fails when the installed Xcode is not the archive's build, even if it extends that build.
    @Test func checksXcodeVersion() async {
        for output in ["Xcode 26.0\nBuild version 17A1\n", "Xcode 27.0\nBuild version 27A266a1\n"] {
            let guest = ScriptedGuest(replies: ["xcodebuild -version": .success(output)])
            await #expect(throws: CommandError.imageStep(
                step: "checking the Xcode version",
                reason: "xcodebuild reports \(output)",
            )) {
                try await XcodeImageSteps(guest: guest, deviceName: nil).run()
            }
        }
    }

    /// Requires the license flag and a valid name before the command touches a file.
    @Test func validatesArguments() throws {
        let arguments = ["image", "xcode", "--from", "base", "--xcode", "X.xip", "--runtime", "R.dmg"]
        #expect(throws: (any Error).self) {
            try Macpool.parseAsRoot(arguments + ["--name", "xcode"])
        }
        do {
            _ = try Macpool.parseAsRoot(arguments + ["--name", "xcode"])
        } catch {
            #expect(Macpool.message(for: error) == XcodeImageCommand.licenseMessage)
        }
        #expect(throws: (any Error).self) {
            try Macpool.parseAsRoot(arguments + ["--name", ".hidden", "--accept-xcode-license"])
        }
        let command = try #require(
            try Macpool.parseAsRoot(arguments + ["--name", "xcode-27", "--accept-xcode-license"]) as? XcodeImageCommand,
        )
        #expect(command.name == "xcode-27")
        #expect(command.device == nil)
        #expect(!command.keepFailed)
        #expect(command.bootTimeout == 900)
    }

    /// Accepts names that cannot hide, escape the directory, or need quoting.
    @Test func validatesNames() {
        for name in ["xcode", "Xcode_27.0", "x-1", String(repeating: "a", count: 64)] {
            #expect(ImageWorkspace.isValidName(name))
        }
        for name in ["", ".x", "-x", "a/b", "..", "x y", "é", String(repeating: "a", count: 65)] {
            #expect(!ImageWorkspace.isValidName(name))
        }
    }

    /// Refuses an existing image, a base that never booted, and a disk below 128 GB.
    @Test func refusesUnfitBase() throws {
        let unbooted = try ImageFolder(hasBooted: false)
        let unbootedPath = unbooted.base.root.path(percentEncoded: false)
        #expect(throws: CommandError.invalidValue(
            "the base \(unbootedPath) never booted, so it has no guest account to build with",
        )) {
            try unbooted.workspace.prepare(base: unbooted.base)
        }

        let small = try ImageFolder(diskBytes: 64 << 30)
        #expect(throws: CommandError.invalidValue(
            "the base's disk has 64 GB, and Xcode with a simulator runtime needs a disk of 128 GB. "
                + "Create the base with --disk-gb 128",
        )) {
            try small.workspace.prepare(base: small.base)
        }

        let taken = try ImageFolder()
        try FileManager.default.createDirectory(at: taken.workspace.image, withIntermediateDirectories: true)
        #expect(throws: CommandError.fileExists(path: taken.workspace.image.path(percentEncoded: false))) {
            try taken.workspace.prepare(base: taken.base)
        }
    }

    /// Names both leftovers of an unfinished build when either one exists, and deletes neither.
    @Test func refusesLeftoversOfUnfinishedBuild() throws {
        for leftover in [\ImageWorkspace.building.root, \ImageWorkspace.inputs] {
            let folder = try ImageFolder()
            let workspace = folder.workspace
            let path = workspace[keyPath: leftover]
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            #expect(throws: CommandError.unfinishedImageBuild(
                name: "xcode",
                building: workspace.building.root.path(percentEncoded: false),
                inputs: workspace.inputs.path(percentEncoded: false),
            )) {
                try workspace.prepare(base: folder.base)
            }
            #expect(FileManager.default.fileExists(atPath: path.path(percentEncoded: false)))
        }
    }

    /// Refuses a directory or a missing file as an input before it clones the base.
    @Test func refusesInputThatIsNoFile() async throws {
        let folder = try ImageFolder()
        let app = folder.base.root.deletingLastPathComponent().appending(path: "Xcode.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let missing = folder.base.root.deletingLastPathComponent().appending(path: "missing.dmg")
        let cases = [
            (
                app,
                folder.runtime,
                "--xcode \(app.path(percentEncoded: false)) is not a readable file. "
                    + "Pass the .xip archive itself",
            ),
            (
                folder.xcode,
                missing,
                "--runtime \(missing.path(percentEncoded: false)) is not a readable file. "
                    + "Pass the .dmg disk image itself",
            ),
        ]
        for (xcode, runtime, message) in cases {
            await #expect(throws: CommandError.invalidValue(message)) {
                try await folder.workspace.build(
                    from: folder.base,
                    xcode: xcode,
                    runtime: runtime,
                    keepFailed: false,
                    watchSignals: Self.noSignals,
                ) { _, _, _ async throws(CommandError) in
                    Issue.record("the guest part ran with an input that is no file")
                    return XcodeImageBuilds(xcode: "1", iosRuntime: "1")
                }
            }
            #expect(!FileManager.default.fileExists(atPath: folder.workspace.building.root.path(percentEncoded: false)))
        }
    }

    /// Accepts a symbolic link to a file and refuses a file that the user cannot read.
    @Test func checksInputs() throws {
        let folder = try ImageFolder()
        let directory = folder.base.root.deletingLastPathComponent()
        let link = directory.appending(path: "link.xip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.xcode)
        #expect(throws: Never.self) {
            try ImageWorkspace.checkInputs(xcode: link, runtime: folder.runtime)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: folder.runtime.path(percentEncoded: false),
        )
        #expect(throws: CommandError.invalidValue(
            "--runtime \(folder.runtime.path(percentEncoded: false)) is not a readable file. "
                + "Pass the .dmg disk image itself",
        )) {
            try ImageWorkspace.checkInputs(xcode: folder.xcode, runtime: folder.runtime)
        }
    }

    /// Finishes the cleanup after `SIGHUP` and prints later lines when standard output is a closed
    /// terminal or a pipe without a reader.
    @Test(arguments: [false, true]) func cleansUpWithClosedOutput(throughPipe: Bool) async {
        await #expect(processExitsWith: .success) { [throughPipe] in
            // _exit skips the exit work of the harness and of stdio. That work would write to the closed output.
            let output = throughPipe ? closedPipe() : closedTerminal()
            guard dup2(output, STDOUT_FILENO) >= 0, dup2(output, STDERR_FILENO) >= 0 else {
                _exit(2)
            }
            guard let folder = try? ImageFolder() else {
                _exit(3)
            }
            let workspace = folder.workspace
            do throws(CommandError) {
                try await workspace.build(
                    from: folder.base,
                    xcode: folder.xcode,
                    runtime: folder.runtime,
                    keepFailed: false,
                    watchSignals: XcodeImageCommand.watchSignals,
                ) { _, _, interrupted async throws(CommandError) in
                    kill(getpid(), SIGHUP)
                    while !interrupted.isSet {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    throw .imageStep(step: "expanding Xcode", reason: "the VM stopped")
                }
                _exit(4)
            } catch {
                guard error == .interrupted else {
                    _exit(5)
                }
            }
            // A published image prints its lines after the watch ends.
            Report.line("image=\(workspace.image.path(percentEncoded: false))")
            let manager = FileManager.default
            let isClean = !manager.fileExists(atPath: workspace.building.root.path(percentEncoded: false))
                && !manager.fileExists(atPath: workspace.inputs.path(percentEncoded: false))
            try? manager.removeItem(at: folder.base.root.deletingLastPathComponent())
            _exit(isClean ? 0 : 6)
        }
    }

    /// Leaves a build running when `SIGHUP` arrives under `nohup`, and keeps the signal ignored after
    /// the watch ends.
    @Test func keepsIgnoredHangup() async {
        await #expect(processExitsWith: .success) {
            signal(SIGHUP, SIG_IGN)
            let interrupted = StopFlag()
            let stopWatching = XcodeImageCommand.watchSignals(interrupted)
            kill(getpid(), SIGHUP)
            // A watched signal reaches its handler on a background queue within milliseconds.
            usleep(300_000)
            guard !interrupted.isSet else {
                _exit(2)
            }
            stopWatching()
            guard SignalWatch.isIgnored(SIGHUP) else {
                _exit(3)
            }
            kill(getpid(), SIGHUP)
            usleep(100_000)
            _exit(0)
        }
    }

    /// Restores the action that a signal had before the watch, instead of the default action.
    @Test func restoresEarlierSignalAction() async {
        await #expect(processExitsWith: .success) {
            signal(SIGUSR1, SIG_IGN)
            SignalWatch(signals: [SIGUSR1]) { _ in }.cancel()
            // The default action of SIGUSR1 ends the process. Delivery to another thread can
            // take a moment.
            kill(getpid(), SIGUSR1)
            usleep(100_000)
            _exit(0)
        }
    }

    /// Ends the process when a line cannot be written, unless an image build drops such lines.
    @Test(arguments: [false, true]) func reportsUnwritableLine(dropping: Bool) async {
        await #expect(processExitsWith: dropping ? .success : .failure) { [dropping] in
            let output = closedTerminal()
            guard dup2(output, STDOUT_FILENO) >= 0, dup2(output, STDERR_FILENO) >= 0 else {
                _exit(2)
            }
            if dropping {
                Report.dropUnwritableLines()
            }
            Report.line("measure probe_seconds=1.0")
            _exit(0)
        }
    }

    /// Accepts a base without a boot record, as the daemon does when it leases one.
    @Test func acceptsBaseWithoutBootRecord() throws {
        let legacy = try ImageFolder(hasBooted: nil)
        #expect(throws: Never.self) {
            try legacy.workspace.prepare(base: legacy.base)
        }
    }

    /// Clones the base, stages the inputs, and moves the clone to its name with the record.
    @Test func finishesImage() throws {
        let folder = try ImageFolder()
        let workspace = folder.workspace
        #expect(try workspace.prepare(base: folder.base).build == "26B123")
        try workspace.cloneBase(folder.base)
        #expect(try workspace.building.imageRecord() == ImageRecord(isReady: false))
        #expect(try folder.base.imageRecord() == nil)
        #expect(try workspace.building.settings().credentialRotation == .pending)

        try workspace.stageInputs(xcode: folder.xcode, runtime: folder.runtime, interrupted: StopFlag())
        let staged = try FileManager.default.contentsOfDirectory(atPath: workspace.inputs.path(percentEncoded: false))
        #expect(staged.sorted() == ["Runtime.dmg", "Xcode.xip"])
        #expect(FileManager.default
            .contents(atPath: workspace.inputs.appending(path: "Xcode.xip").path) == Data("xip".utf8))

        let record = ImageRecord(isReady: true, builds: ["xcode": "27A266a"], createdAt: Date(timeIntervalSince1970: 0))
        try workspace.finish(record)
        workspace.removeInputs()
        #expect(try VMBundle(root: workspace.image).imageRecord() == record)
        #expect(!FileManager.default.fileExists(atPath: workspace.building.root.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: workspace.inputs.path(percentEncoded: false)))
        #expect(folder.directory.images().map(\.name) == ["xcode"])
    }

    /// Stages the target of a symbolic link and stops before a copy once a signal arrived.
    @Test func stagesInputs() throws {
        let folder = try ImageFolder()
        _ = try folder.workspace.prepare(base: folder.base)
        let link = folder.base.root.deletingLastPathComponent().appending(path: "link.xip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.xcode)
        try folder.workspace.stageInputs(xcode: link, runtime: folder.runtime, interrupted: StopFlag())
        let staged = folder.workspace.inputs.appending(path: "Xcode.xip").path(percentEncoded: false)
        #expect(try FileManager.default.attributesOfItem(atPath: staged)[.type] as? FileAttributeType == .typeRegular)
        #expect(FileManager.default.contents(atPath: staged) == Data("xip".utf8))

        folder.workspace.removeInputs()
        let interrupted = StopFlag()
        interrupted.set()
        #expect(throws: CommandError.interrupted) {
            try folder.workspace.stageInputs(xcode: folder.xcode, runtime: folder.runtime, interrupted: interrupted)
        }
        let left = try FileManager.default
            .contentsOfDirectory(atPath: folder.workspace.inputs.path(percentEncoded: false))
        #expect(left.isEmpty)
    }

    /// Stops a data copy once a signal arrives, and copies the whole file without one.
    @Test func stopsCopyOnSignal() throws {
        let folder = try ImageFolder()
        let directory = folder.base.root.deletingLastPathComponent()
        let source = directory.appending(path: "large.xip")
        try Data(repeating: 7, count: 4 << 20).write(to: source)
        // Without COPYFILE_CLONE the copy writes data, as it does across volumes.
        let flags = copyfile_flags_t(COPYFILE_DATA)
        let whole = directory.appending(path: "whole.xip")
        try ImageWorkspace.copy(source, to: whole, flags: flags, interrupted: StopFlag())
        #expect(FileManager.default.contents(atPath: whole.path(percentEncoded: false))?.count == 4 << 20)

        let interrupted = StopFlag()
        interrupted.set()
        #expect(throws: CommandError.interrupted) {
            try ImageWorkspace.copy(
                source,
                to: directory.appending(path: "stopped.xip"),
                flags: flags,
                interrupted: interrupted,
            )
        }
        let stopped = FileManager.default
            .contents(atPath: directory.appending(path: "stopped.xip").path(percentEncoded: false))
        #expect((stopped?.count ?? 0) < 4 << 20)
    }

    /// Names the step that a stopped VM ended, and accepts a shutdown that stops the VM before its
    /// command returns.
    @Test func namesStepThatTheVMStopped() async throws {
        let stopped = XcodeImageSteps(guest: ScriptedGuest(replies: ["xip --expand": .cancelled]), deviceName: nil)
        await #expect(throws: CommandError.imageStep(step: "expanding Xcode", reason: "the VM stopped")) {
            try await stopped.run()
        }
        #expect(XcodeImageCommand.vmStopped(
            .stoppedWithError(description: "disk error"),
            during: .imageStep(step: "expanding Xcode", reason: "the VM stopped"),
        ).description == "building the image failed while expanding Xcode: the VM stopped with an error: disk error")
        let unnamed = XcodeImageCommand.vmStopped(.guestStopped, during: .library(.guestCommandCancelled))
        #expect(unnamed == .stopped(.guestStopped))
        #expect(CommandError.stopped(.guestStopped).description == "the guest shut down")

        let guest = ScriptedGuest()
        try await XcodeImageSteps(guest: guest, deviceName: nil).shutDown()
        let shutdown = GuestCall(
            command: "(sleep 1; /sbin/shutdown -h now) >/dev/null 2>&1 &",
            asRoot: true,
            timeLimit: .seconds(60),
        )
        #expect(await guest.calls == [shutdown])

        // The build cancels the steps once the VM stops, and a guest that shut down that early
        // still did what the step asked.
        let early = XcodeImageSteps(guest: ScriptedGuest(replies: ["shutdown -h": .cancelled]), deviceName: nil)
        let cancelled = await Task { () async -> CommandError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(CommandError) {
                try await early.shutDown()
                return nil
            } catch {
                return error
            }
        }.value
        #expect(cancelled == nil)
        await #expect(throws: CommandError.imageStep(step: "shutting down the guest", reason: "the VM stopped")) {
            try await early.shutDown()
        }
    }

    /// Stops a copy after a failed write instead of letting `copyfile` write again.
    @Test func stopsCopyAfterFailedWrite() {
        #expect(ImageWorkspace.copyDecision(stage: COPYFILE_START, isInterrupted: false) == COPYFILE_CONTINUE)
        #expect(ImageWorkspace.copyDecision(stage: COPYFILE_PROGRESS, isInterrupted: false) == COPYFILE_CONTINUE)
        #expect(ImageWorkspace.copyDecision(stage: COPYFILE_PROGRESS, isInterrupted: true) == COPYFILE_QUIT)
        #expect(ImageWorkspace.copyDecision(stage: COPYFILE_ERR, isInterrupted: false) == COPYFILE_QUIT)
    }

    /// Publishes a ready image with the builds of the guest and the base.
    @Test func buildsImage() async throws {
        let folder = try ImageFolder()
        let workspace = folder.workspace
        try await workspace.build(
            from: folder.base,
            xcode: folder.xcode,
            runtime: folder.runtime,
            keepFailed: false,
            watchSignals: Self.noSignals,
        ) { building, inputs, _ async throws(CommandError) in
            #expect(building == workspace.building)
            #expect(FileManager.default.fileExists(atPath: inputs.appending(path: "Runtime.dmg").path))
            return XcodeImageBuilds(xcode: "27A266a", iosRuntime: "24A434")
        }
        let record = try #require(try VMBundle(root: workspace.image).imageRecord())
        #expect(record.isReady)
        #expect(record.builds == ["xcode": "27A266a", "ios_runtime": "24A434", "macos": "26B123"])
        #expect(!FileManager.default.fileExists(atPath: workspace.inputs.path(percentEncoded: false)))
    }

    /// Watches signals from before the clone until after the cleanup, and deletes the clone after
    /// a signal or keeps it with `keepFailed`.
    @Test func cleansUpAfterSignal() async throws {
        for keepFailed in [false, true] {
            let folder = try ImageFolder()
            let workspace = folder.workspace
            let stopped = StopFlag()
            await #expect(throws: CommandError.interrupted) {
                try await workspace.build(
                    from: folder.base,
                    xcode: folder.xcode,
                    runtime: folder.runtime,
                    keepFailed: keepFailed,
                    watchSignals: { interrupted in
                        #expect(
                            !FileManager.default
                                .fileExists(atPath: workspace.building.root.path(percentEncoded: false)),
                            "the signal watch started after the clone",
                        )
                        // The signal arrives as soon as the watch exists. That moment is before the clone.
                        interrupted.set()
                        let inputs = workspace.inputs.path(percentEncoded: false)
                        return {
                            #expect(
                                !FileManager.default.fileExists(atPath: inputs),
                                "the watch stopped before the cleanup",
                            )
                            stopped.set()
                        }
                    },
                ) { _, _, _ async throws(CommandError) in
                    Issue.record("the guest part ran after the signal")
                    return XcodeImageBuilds(xcode: "1", iosRuntime: "1")
                }
            }
            #expect(stopped.isSet)
            #expect(!FileManager.default.fileExists(atPath: workspace.building.root.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: workspace.inputs.path(percentEncoded: false)))
            let failedRecord = try VMBundle(root: workspace.image).imageRecord()
            #expect(failedRecord?.isReady == (keepFailed ? false : nil))
        }
    }

    /// Keeps a failed step's error, and deletes the clone or keeps it with `keepFailed`.
    @Test func cleansUpAfterFailedStep() async throws {
        let failure = CommandError.imageStep(step: "expanding Xcode", reason: "ssh exited(1): no space")
        for keepFailed in [false, true] {
            let folder = try ImageFolder()
            let workspace = folder.workspace
            await #expect(throws: failure) {
                try await workspace.build(
                    from: folder.base,
                    xcode: folder.xcode,
                    runtime: folder.runtime,
                    keepFailed: keepFailed,
                    watchSignals: Self.noSignals,
                ) { _, _, _ async throws(CommandError) in
                    throw failure
                }
            }
            #expect(!FileManager.default.fileExists(atPath: workspace.building.root.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: workspace.inputs.path(percentEncoded: false)))
            let failedRecord = try VMBundle(root: workspace.image).imageRecord()
            #expect(failedRecord?.isReady == (keepFailed ? false : nil))
        }
    }

    /// Deletes the clone and keeps the error when the image cannot be published.
    @Test func cleansUpAfterFailedPublish() async throws {
        let folder = try ImageFolder()
        let workspace = folder.workspace
        let error = await #expect(throws: CommandError.self) {
            try await workspace.build(
                from: folder.base,
                xcode: folder.xcode,
                runtime: folder.runtime,
                keepFailed: false,
                watchSignals: Self.noSignals,
            ) { _, _, _ async throws(CommandError) in
                // Another process takes the name while the guest builds.
                try? FileManager.default.createDirectory(at: workspace.image, withIntermediateDirectories: true)
                return XcodeImageBuilds(xcode: "27A266a", iosRuntime: "24A434")
            }
        }
        guard case let .library(.fileSystem(operation, _, _)) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(operation == "moving the image to")
        #expect(!FileManager.default.fileExists(atPath: workspace.building.root.path(percentEncoded: false)))
    }

    /// Deletes the clone and the inputs of a failed build, and reports when it could not.
    @Test func discardsClone() throws {
        let folder = try ImageFolder()
        _ = try folder.workspace.prepare(base: folder.base)
        try folder.workspace.cloneBase(folder.base)
        try FileManager.default.createDirectory(at: folder.workspace.inputs, withIntermediateDirectories: false)
        let images = folder.directory.imagesDirectory.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: images)
        #expect(!folder.workspace.discard())
        #expect(!folder.workspace.removeInputs())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: images)
        #expect(folder.workspace.discard())
        #expect(folder.workspace.removeInputs())
        #expect(!FileManager.default.fileExists(atPath: folder.workspace.building.root.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: folder.base.root.path(percentEncoded: false)))
    }

    /// Starts a signal watch that never sets the flag it receives.
    ///
    /// - Returns: The function that stops the watch.
    private static func noSignals(_: StopFlag) -> @Sendable () -> Void {
        {}
    }
}

/// Opens a terminal and closes its controlling side, as closing a terminal window does.
///
/// - Returns: The descriptor of the terminal's other side. A write to it fails with `EIO`.
private func closedTerminal() -> Int32 {
    var primary: Int32 = -1
    var secondary: Int32 = -1
    guard openpty(&primary, &secondary, nil, nil, nil) == 0 else {
        _exit(7)
    }
    close(primary)
    return secondary
}

/// Opens a pipe and closes its read end, as a `tee` that ended does.
///
/// - Returns: The write end. A write to it raises `SIGPIPE` or fails with `EPIPE`.
private func closedPipe() -> Int32 {
    var ends: [Int32] = [-1, -1]
    guard pipe(&ends) == 0 else {
        _exit(8)
    }
    close(ends[0])
    return ends[1]
}

/// One recorded guest command.
private struct GuestCall: Equatable {
    /// The command line.
    let command: String

    /// Whether the command ran as root.
    let asRoot: Bool

    /// The command's time limit.
    let timeLimit: Duration
}

/// A reply of the scripted guest.
private enum GuestReply {
    /// The command exits with 0 and prints the output.
    case success(String)

    /// The command exits with the code and prints the error output.
    case failure(Int32, String)

    /// The build cancelled the command, as it does after the VM stops.
    case cancelled
}

/// A guest that records each command and replies as if every step works.
private actor ScriptedGuest: ImageGuest {
    /// The runtime that the guest lists.
    static let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"

    /// The UDID of the guest's iPhone.
    static let iPhone = "A1B2C3D4-0000-4000-8000-000000000001"

    /// The UDID of the guest's iPad.
    static let iPad = "A1B2C3D4-0000-4000-8000-000000000002"

    /// The commands in the order that the build ran them.
    private(set) var calls: [GuestCall] = []

    /// Replies that replace the default for a command containing the key.
    private let replies: [String: GuestReply]

    /// Creates a guest with replies that replace the defaults.
    ///
    /// - Parameter replies: Replies keyed by a substring of the command.
    init(replies: [String: GuestReply] = [:]) {
        self.replies = replies
    }

    /// Builds the runtime list with the added runtime and an optional second one.
    ///
    /// - Parameter extra: The JSON of another runtime, or `nil`.
    /// - Returns: The output of `simctl list runtimes --json`.
    static func runtimeList(extra: String? = nil) -> String {
        let added = #"{"identifier": "\#(runtime)", "platform": "iOS", "buildversion": "24A434", "isAvailable": true}"#
        let unavailable = #"{"identifier": "c", "platform": "iOS", "buildversion": "22A1", "isAvailable": false}"#
        let runtimes = ([added, unavailable] + (extra.map { [$0] } ?? [])).joined(separator: ", ")
        return #"{"runtimes": [\#(runtimes)]}"#
    }

    /// Records the command and returns the reply for it.
    ///
    /// - Parameters:
    ///   - command: The command line.
    ///   - asRoot: Whether the command runs as root.
    ///   - timeLimit: The command's time limit.
    /// - Returns: The scripted reply, or the default for a guest where every step works.
    func runStep(_ command: String, asRoot: Bool, timeLimit: Duration) async throws(MacpoolError)
        -> GuestCommandResult {
        calls.append(GuestCall(command: command, asRoot: asRoot, timeLimit: timeLimit))
        let reply = replies.first { command.contains($0.key) }?.value ?? defaultReply(to: command)
        return switch reply {
        case let .success(output):
            GuestCommandResult(status: .exited(0), output: output, errorOutput: "")
        case let .failure(code, errorOutput):
            GuestCommandResult(status: .exited(code), output: "", errorOutput: errorOutput)
        case .cancelled:
            throw .guestCommandCancelled
        }
    }

    /// Answers a command as a guest where every step works.
    ///
    /// - Parameter command: The command line.
    /// - Returns: The reply.
    private func defaultReply(to command: String) -> GuestReply {
        if command.contains("PlistBuddy") {
            return .success("27A266a\n")
        }
        if command.contains("list runtimes") {
            return .success(Self.runtimeList())
        }
        if command.contains("list devices") {
            return .success(#"""
            {"devices": {"\#(Self.runtime)": [
                {"name": "iPad Air", "udid": "\#(Self.iPad)"},
                {"name": "iPhone 18", "udid": "\#(Self.iPhone)"}
            ]}}
            """#)
        }
        if command.contains("xcodebuild -version") {
            return .success("Xcode 27.0\nBuild version 27A266a\n")
        }
        if command.contains("df -k") {
            return .success("\((80 << 30) / 1024)\n")
        }
        return .success("")
    }
}

/// A temporary data directory with a stopped base and two input files, removed with the value.
private final class ImageFolder {
    /// The data directory.
    let directory: PoolDirectory

    /// The base bundle.
    let base: VMBundle

    /// The fake Xcode archive.
    let xcode: URL

    /// The fake runtime disk image.
    let runtime: URL

    /// The workspace of an image named `xcode`.
    var workspace: ImageWorkspace {
        ImageWorkspace(directory: directory, name: "xcode")
    }

    /// Creates the folder.
    ///
    /// - Parameters:
    ///   - hasBooted: The base's boot record.
    ///   - diskBytes: The logical size of the base's sparse disk.
    /// - Throws: An error when a file cannot be written.
    init(hasBooted: Bool? = true, diskBytes: UInt64 = 128 << 30) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "macpool-image-tests-\(UUID().uuidString)")
        directory = PoolDirectory(root: root.appending(path: "data"))
        base = VMBundle(root: root.appending(path: "base"))
        xcode = root.appending(path: "X.xip")
        runtime = root.appending(path: "R.dmg")
        try FileManager.default.createDirectory(at: base.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.root, withIntermediateDirectories: true)
        try base.writeSettings(BundleSettings(
            cpuCount: 4,
            memoryByteCount: 8 << 30,
            macAddress: VMBundle.randomMACAddress(),
            build: "26B123",
            hasBooted: hasBooted,
        ))
        #expect(FileManager.default.createFile(atPath: base.disk.path(percentEncoded: false), contents: nil))
        let disk = try FileHandle(forWritingTo: base.disk)
        try disk.truncate(atOffset: diskBytes)
        try disk.close()
        try Data("xip".utf8).write(to: xcode)
        try Data("dmg".utf8).write(to: runtime)
    }

    /// Removes the temporary directory.
    deinit {
        try? FileManager.default.removeItem(at: base.root.deletingLastPathComponent())
    }
}
