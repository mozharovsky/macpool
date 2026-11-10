import ArgumentParser
import Foundation
import MacpoolVM

/// The options that share a host directory with the guest.
struct ShareOptions: ParsableArguments {
    /// A host directory to share with the guest, or `nil` for none.
    @Option(help: "A host directory to share with the guest through VirtioFS.")
    var share: String?

    /// Whether the guest can only read the shared directory.
    @Flag(
        name: .customLong("share-read-only"),
        help: "Lets the guest only read the shared directory. Requires --share.",
    )
    var readOnly = false

    /// Rejects a read-only flag without a directory.
    ///
    /// - Throws: `ValidationError` when `--share-read-only` comes without `--share`.
    func validate() throws {
        guard share != nil || !readOnly else {
            throw ValidationError("--share-read-only requires --share.")
        }
    }

    /// The absolute path of the shared directory, or `nil` for none.
    var absolutePath: String? {
        share.map { URL(filePath: $0).absoluteURL.path(percentEncoded: false) }
    }

    /// The shared directory for the VM's devices, or `nil` for none.
    var sharedDirectory: SharedDirectory? {
        share.map { SharedDirectory(url: URL(filePath: $0).absoluteURL, isReadOnly: readOnly) }
    }
}
