import Foundation
import MacpoolVM
import Testing

/// Tests of reading and writing a bundle's `image.json`.
struct ImageRecordTests {
    /// Writes a record with its format version and reads it back.
    @Test func roundTrips() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        let record = ImageRecord(
            isReady: true,
            builds: ["xcode": "27A266a", "ios_runtime": "24A434"],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        )

        try bundle.writeImageRecord(record)

        #expect(try bundle.imageRecord() == record)
        let text = try String(contentsOf: bundle.imageFile, encoding: .utf8)
        #expect(text.contains(#""version" : 1"#))
        #expect(text.contains(#""created_at" : "2027-01-15T08:00:00Z""#))
    }

    /// Returns `nil` for a bundle that is not an image.
    @Test func returnsNothingWithoutRecord() throws {
        let directory = try TemporaryDirectory()
        #expect(try VMBundle(root: directory.url).imageRecord() == nil)
    }

    /// Reads a record without the `ready` key as an image that is not ready.
    @Test func readsMissingReadyAsNotReady() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        try Data(#"{"version": 1}"#.utf8).write(to: bundle.imageFile)

        #expect(try bundle.imageRecord() == ImageRecord(isReady: false))
    }

    /// Rejects a record whose version is missing or unknown, even when it says it is ready.
    @Test(arguments: [
        (#"{"ready": true}"#, "the image record has no version"),
        (#"{"version": 2, "ready": true}"#, "image record version 2 is not supported"),
        (#"{"version": "1", "ready": true}"#, nil),
        (#"{"version": 1, "ready": "yes"}"#, nil),
        ("not json", nil),
    ])
    func rejectsUnreadableRecord(json: String, reason: String?) throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        try Data(json.utf8).write(to: bundle.imageFile)

        #expect {
            try bundle.imageRecord()
        } throws: { error in
            guard case let .invalidBundle(path, actual) = error as? MacpoolError else {
                return false
            }
            return path == bundle.imageFile.path(percentEncoded: false) && (reason == nil || actual == reason)
        }
    }
}
