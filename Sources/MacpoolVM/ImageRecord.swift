public import Foundation

/// The record that marks a stopped bundle as an image and says whether its clones can be leased.
///
/// The record lives in the bundle as `image.json`. The JSON keys use snake case, and the `version`
/// key holds ``formatVersion``. ``VMBundle/imageRecord()`` rejects a file with another version or
/// without one. If the `ready` key is missing, the image reads as not ready.
///
/// ```json
/// {
///   "builds" : { "ios_runtime" : "24A434", "xcode" : "27A266a" },
///   "created_at" : "2026-11-11T09:30:00Z",
///   "ready" : true,
///   "version" : 1
/// }
/// ```
public struct ImageRecord: Codable, Sendable, Equatable {
    /// The format version that this library reads and writes.
    public static let formatVersion = 1

    /// Whether the image passed the checks of the command that built it.
    ///
    /// The pool daemon refuses to lease a clone of an image that is not ready.
    public var isReady: Bool

    /// The build of each piece of software in the image, keyed by a name such as `xcode`.
    public var builds: [String: String]

    /// The time at which the image was finished, or `nil` if the record does not say.
    public var createdAt: Date?

    /// Creates a record.
    ///
    /// - Parameters:
    ///   - isReady: Whether the image passed its checks.
    ///   - builds: The build of each piece of software, keyed by a name such as `xcode`.
    ///   - createdAt: The time at which the image was finished.
    public init(isReady: Bool, builds: [String: String] = [:], createdAt: Date? = nil) {
        self.isReady = isReady
        self.builds = builds
        self.createdAt = createdAt
    }

    /// Decodes a record and treats a missing `ready` key as not ready.
    ///
    /// The caller checks the `version` key first.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: `DecodingError` when a key holds a value of the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isReady = try container.decodeIfPresent(Bool.self, forKey: .isReady) ?? false
        builds = try container.decodeIfPresent([String: String].self, forKey: .builds) ?? [:]
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    /// Encodes the record with ``formatVersion``.
    ///
    /// - Parameter encoder: The encoder.
    /// - Throws: `EncodingError` when the encoder fails.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(isReady, forKey: .isReady)
        try container.encode(builds, forKey: .builds)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    /// The JSON keys of the record.
    private enum CodingKeys: String, CodingKey {
        /// The `version` key.
        case version
        /// The `ready` key.
        case isReady = "ready"
        /// The `builds` key.
        case builds
        /// The `created_at` key.
        case createdAt = "created_at"
    }
}

/// The part of `image.json` that a reader checks before it decodes the rest.
struct ImageFormatHeader: Decodable {
    /// The record's format version, or `nil` if the file has none.
    let version: Int?
}
