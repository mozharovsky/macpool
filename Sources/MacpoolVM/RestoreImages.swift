public import Foundation
import Virtualization

/// The newest restore image that Apple's servers offer for this host.
public struct RemoteRestoreImage: Sendable, Equatable {
    /// The download URL of the IPSW file.
    public let url: URL

    /// The macOS build number, such as `26B123`.
    public let build: String

    /// The macOS version as `major.minor.patch`.
    public let version: String
}

/// A downloaded restore image and the hardware it requires.
public struct LocalRestoreImage: Sendable, Equatable {
    /// The macOS build number.
    public let build: String

    /// The macOS version as `major.minor.patch`.
    public let version: String

    /// The serialized hardware model that a VM for this image uses.
    public let hardwareModel: Data

    /// The smallest CPU count that the image supports.
    public let minimumCPUCount: Int

    /// The smallest memory size that the image supports, in bytes.
    public let minimumMemoryByteCount: UInt64
}

/// Restore image discovery and inspection.
public enum RestoreImages {
    /// Asks Apple's servers for the newest restore image that this host supports.
    ///
    /// - Returns: The image's URL, build, and version.
    /// - Throws: ``MacpoolError/framework(operation:domain:code:description:)`` when the request
    ///   fails.
    public static func latestSupported() async throws(MacpoolError) -> RemoteRestoreImage {
        let operation = "fetching the latest restore image"
        do {
            return try await withCheckedThrowingContinuation { continuation in
                VZMacOSRestoreImage.fetchLatestSupported { result in
                    continuation.resume(with: result.map { image in
                        RemoteRestoreImage(
                            url: image.url,
                            build: image.buildVersion,
                            version: versionString(image.operatingSystemVersion),
                        )
                    })
                }
            }
        } catch {
            throw .framework(operation, error)
        }
    }

    /// Loads a downloaded IPSW file and reads the configuration it requires.
    ///
    /// - Parameter file: The local IPSW file.
    /// - Returns: The image's version and the requirements of its most capable configuration
    ///   that this host supports.
    /// - Throws: ``MacpoolError/framework(operation:domain:code:description:)`` when the file is
    ///   not a restore image, or ``MacpoolError/unsupported(reason:)`` when this host cannot run
    ///   it.
    public static func load(from file: URL) async throws(MacpoolError) -> LocalRestoreImage {
        let loaded: Result<LocalRestoreImage, MacpoolError> = await withCheckedContinuation { continuation in
            VZMacOSRestoreImage.load(from: file.absoluteURL) { result in
                switch result {
                case let .success(image):
                    continuation.resume(returning: localImage(image))
                case let .failure(error):
                    continuation.resume(returning: .failure(.framework("loading the restore image", error)))
                }
            }
        }
        return try loaded.get()
    }

    /// Reads the requirements of a loaded image.
    ///
    /// - Parameter image: The image that the framework loaded.
    /// - Returns: The requirements, or a failure when the host supports no configuration of the
    ///   image.
    private static func localImage(_ image: VZMacOSRestoreImage) -> Result<LocalRestoreImage, MacpoolError> {
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            return .failure(.unsupported(reason: "this host supports no configuration of the restore image"))
        }
        guard requirements.hardwareModel.isSupported else {
            return .failure(.unsupported(reason: "the image's hardware model is not supported on this host"))
        }
        return .success(LocalRestoreImage(
            build: image.buildVersion,
            version: versionString(image.operatingSystemVersion),
            hardwareModel: requirements.hardwareModel.dataRepresentation,
            minimumCPUCount: requirements.minimumSupportedCPUCount,
            minimumMemoryByteCount: requirements.minimumSupportedMemorySize,
        ))
    }

    /// Formats an operating system version as `major.minor.patch`.
    ///
    /// - Parameter version: The version to format.
    /// - Returns: The dotted version.
    private static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
