import Foundation
import MacpoolPool
import MacpoolVM

/// The files of one image build in the data directory's `images` directory.
///
/// The build clones the base to `.NAME.building` and shares `.NAME.inputs` with the guest. Both
/// names start with a dot, so `list` skips them. When the build succeeds, it moves the clone to
/// `NAME`. If the build fails, it deletes the clone or keeps it as `NAME` with a record that is
/// not ready.
struct ImageWorkspace {
    /// The smallest logical disk, in bytes, that holds Xcode and a simulator runtime.
    static let minimumDiskBytes: UInt64 = 128 << 30

    /// The data directory.
    let directory: PoolDirectory

    /// The image's name.
    let name: String

    /// The finished image.
    var image: URL {
        directory.imagesDirectory.appending(path: name, directoryHint: .notDirectory)
    }

    /// The clone that the build boots and changes.
    var building: VMBundle {
        VMBundle(root: directory.imagesDirectory.appending(path: ".\(name).building", directoryHint: .notDirectory))
    }

    /// The directory that the guest reads the archive and the runtime from.
    var inputs: URL {
        directory.imagesDirectory.appending(path: ".\(name).inputs", directoryHint: .isDirectory)
    }

    /// Reports whether a name can name an image.
    ///
    /// - Parameter name: The name.
    /// - Returns: Whether the name has 1 to 64 ASCII letters, digits, dots, hyphens, and
    ///   underscores and starts with a letter or digit.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first.isNumber, name.count <= 64 else {
            return false
        }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Creates the `images` directory and checks that the build can start.
    ///
    /// - Parameter base: The stopped bundle to clone.
    /// - Returns: The base's settings.
    /// - Throws: ``CommandError/fileExists(path:)`` when the image or a file of an earlier build
    ///   exists. ``CommandError/invalidValue(_:)`` when the base never booted, its disk is smaller
    ///   than 128 GiB, or it lies on another volume than the data directory.
    ///   ``CommandError/library(_:)`` when the base cannot be read or its rotation did not finish.
    func prepare(base: VMBundle) throws(CommandError) -> BundleSettings {
        let manager = FileManager.default
        for url in [image, building.root, inputs] where manager.fileExists(atPath: url.path(percentEncoded: false)) {
            throw .fileExists(path: url.path(percentEncoded: false))
        }
        let settings = try library { () throws(MacpoolError) in try base.settings() }
        let basePath = base.root.path(percentEncoded: false)
        if settings.credentialRotation == .started {
            throw .library(.credentialRotationIncomplete(path: basePath))
        }
        // A bundle without a boot record predates it. The daemon treats such a bundle as booted.
        guard settings.hasBooted != false else {
            throw .invalidValue("the base \(basePath) never booted, so it has no guest account to build with")
        }
        let diskBytes = (try? manager.attributesOfItem(atPath: base.disk.path(percentEncoded: false))[.size]) as? UInt64
        guard let diskBytes, diskBytes >= Self.minimumDiskBytes else {
            let size = diskBytes.map { "\($0 >> 30) GiB" } ?? "no readable size"
            throw .invalidValue(
                "the base's disk has \(size), and Xcode with a simulator runtime needs a disk of 128 GiB. "
                    + "Create the base with --disk-gb 128",
            )
        }
        do {
            try manager.createDirectory(
                at: directory.imagesDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700],
            )
        } catch {
            throw .library(.fileSystem(
                operation: "creating",
                path: directory.imagesDirectory.path(percentEncoded: false),
                reason: "\(error.localizedDescription)",
            ))
        }
        let baseVolume = try? manager.attributesOfItem(atPath: basePath)[.systemNumber] as? Int
        let imagesVolume = try? manager.attributesOfItem(
            atPath: directory.imagesDirectory.path(percentEncoded: false),
        )[.systemNumber] as? Int
        guard baseVolume != nil, baseVolume == imagesVolume else {
            throw .invalidValue("the base \(basePath) is not on the data directory's volume, so it cannot be cloned")
        }
        return settings
    }

    /// Clones the base to ``building``, gives the clone its own identity, and marks it not ready.
    ///
    /// The base's lock is held during the copy, so no VM can write to the base meanwhile. The
    /// record that is not ready replaces any record that the base had, so the daemon refuses to
    /// lease the clone while the build changes it.
    ///
    /// - Parameter base: The stopped bundle to clone.
    /// - Throws: ``CommandError/library(_:)`` when a command uses the base or the clone fails.
    func cloneBase(_ base: VMBundle) throws(CommandError) {
        let lock = try lockBundle(base)
        defer { withExtendedLifetime(lock) {} }
        let clone = try library { () throws(MacpoolError) in try base.clone(to: building.root) }
        do throws(MacpoolError) {
            try clone.assignIdentity()
            try clone.writeImageRecord(ImageRecord(isReady: false))
        } catch {
            discard()
            throw .library(error)
        }
    }

    /// Builds the image from a stopped base and publishes it as ``image``.
    ///
    /// The method clones the base, stages the inputs, and calls `inGuest` with the clone and
    /// ``inputs``. If every step succeeds, the clone becomes ``image`` with a ready record. If a
    /// step fails or `interrupted` is set, the method deletes the clone. With `keepFailed` it
    /// publishes the clone with a record that is not ready instead. The method always deletes
    /// ``inputs``.
    ///
    /// - Parameters:
    ///   - base: The stopped bundle to clone.
    ///   - xcode: The Xcode archive.
    ///   - runtime: The simulator runtime disk image.
    ///   - keepFailed: Whether a failed build keeps its clone.
    ///   - interrupted: The flag that a signal sets.
    ///   - inGuest: The guest part of the build. It returns the builds that the guest reports.
    /// - Throws: ``CommandError/interrupted`` when `interrupted` is set before the build ends.
    ///   The errors of ``prepare(base:)``, ``cloneBase(_:)``, ``stageInputs(xcode:runtime:interrupted:)``,
    ///   `inGuest`, and ``finish(_:)`` otherwise.
    func build(
        from base: VMBundle,
        xcode: URL,
        runtime: URL,
        keepFailed: Bool,
        interrupted: StopFlag,
        inGuest: (VMBundle, URL) async throws(CommandError) -> XcodeImageBuilds,
    ) async throws(CommandError) {
        let settings = try prepare(base: base)
        try cloneBase(base)
        defer { removeInputs() }
        let builds: XcodeImageBuilds
        do throws(CommandError) {
            try stageInputs(xcode: xcode, runtime: runtime, interrupted: interrupted)
            try Self.check(interrupted)
            builds = try await inGuest(building, inputs)
            try Self.check(interrupted)
        } catch {
            if keepFailed, (try? finish(ImageRecord(isReady: false, createdAt: Date()))) != nil {
                Report.line("kept the failed image \(image.path(percentEncoded: false))")
            } else {
                discard()
                Report.line("removed the incomplete image \(building.root.path(percentEncoded: false))")
            }
            throw interrupted.isSet ? .interrupted : error
        }
        do throws(CommandError) {
            try finish(ImageRecord(isReady: true, builds: builds.record(macOS: settings.build), createdAt: Date()))
        } catch {
            // An unpublished clone would block the next build with the same name.
            discard()
            throw error
        }
    }

    /// Puts the archive and the runtime in ``inputs`` under the names that the guest expects.
    ///
    /// The method copies the target of a symbolic link, because the guest cannot follow a link out
    /// of the shared directory. On the same APFS volume the files are clones and take no space. On
    /// another volume they are copies, and a signal takes effect only after the current copy.
    ///
    /// - Parameters:
    ///   - xcode: The Xcode archive.
    ///   - runtime: The simulator runtime disk image.
    ///   - interrupted: The flag that a signal sets. The method checks it before each copy.
    /// - Throws: ``CommandError/interrupted`` when `interrupted` is set before a copy.
    ///   ``CommandError/library(_:)`` when the directory or a file cannot be created.
    func stageInputs(xcode: URL, runtime: URL, interrupted: StopFlag) throws(CommandError) {
        do {
            try FileManager.default.createDirectory(
                at: inputs,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700],
            )
        } catch {
            throw .library(.fileSystem(
                operation: "creating",
                path: inputs.path(percentEncoded: false),
                reason: "\(error.localizedDescription)",
            ))
        }
        for (link, name) in [(xcode, "Xcode.xip"), (runtime, "Runtime.dmg")] {
            try Self.check(interrupted)
            let source = link.resolvingSymlinksInPath()
            let destination = inputs.appending(path: name).path(percentEncoded: false)
            // COPYFILE_CLONE clones when the volume allows it and copies otherwise.
            guard copyfile(source.path(percentEncoded: false), destination, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0
            else {
                throw .library(.fileSystem(
                    operation: "copying \(source.path(percentEncoded: false)) to",
                    path: destination,
                    reason: String(cString: strerror(errno)),
                ))
            }
        }
    }

    /// Records the build's outcome in the clone and moves the clone to ``image``.
    ///
    /// - Parameter record: The image record.
    /// - Throws: ``CommandError/library(_:)`` when the record cannot be written or the clone
    ///   cannot move.
    func finish(_ record: ImageRecord) throws(CommandError) {
        try library { () throws(MacpoolError) in try building.writeImageRecord(record) }
        do {
            try FileManager.default.moveItem(at: building.root, to: image)
        } catch {
            throw .library(.fileSystem(
                operation: "moving the image to",
                path: image.path(percentEncoded: false),
                reason: "\(error.localizedDescription)",
            ))
        }
    }

    /// Stops the build if a signal arrived.
    ///
    /// - Parameter interrupted: The flag that a signal sets.
    /// - Throws: ``CommandError/interrupted`` when the flag is set.
    private static func check(_ interrupted: StopFlag) throws(CommandError) {
        if interrupted.isSet {
            throw .interrupted
        }
    }

    /// Deletes the clone of a failed build.
    func discard() {
        try? FileManager.default.removeItem(at: building.root)
    }

    /// Deletes ``inputs`` with the archive and runtime copies in it.
    func removeInputs() {
        try? FileManager.default.removeItem(at: inputs)
    }
}
