import Foundation
import Logging
@testable import MacpoolVM
import Testing

/// Tests of the rotation's guest script, its encodings, and its precondition.
struct CredentialRotationTests {
    /// Encodes the automatic login password as macOS stores it in `/etc/kcpassword`.
    @Test func encodesAutoLoginPassword() {
        var generator = GuestAccountTests.SequenceGenerator(state: 7)
        for password in ["a", "elevenchars", "twelve-chars", "an-eighteen-chars!", "a-password-of-24-chars!!"] {
            let data = CredentialRotation.autoLoginData(for: password, using: &generator)
            #expect(data.count.isMultiple(of: 12))
            #expect(data.count > password.utf8.count)
            let key = CredentialRotation.autoLoginKey
            let decoded = data.enumerated().map { index, byte in byte ^ key[index % key.count] }
            #expect(Array(decoded.prefix(password.utf8.count)) == Array(password.utf8))
            #expect(decoded[password.utf8.count] == 0)
        }
    }

    /// Keeps the root script free of single quotes, because the command line wraps it in them.
    @Test func scriptNeedsNoQuoting() {
        #expect(!CredentialRotation.rootScript.contains("'"))
        #expect(CredentialRotation.rootScript.hasPrefix("set -eu\n"))
        #expect(CredentialRotation.rootScript.hasSuffix("/bin/cat /etc/ssh/ssh_host_ed25519_key.pub"))
    }

    /// Accepts user names that need no shell quoting and rejects the rest.
    @Test func checksUsernames() {
        #expect(CredentialRotation.isPlainUsername("macpool"))
        #expect(CredentialRotation.isPlainUsername("ci.runner_2-a"))
        #expect(!CredentialRotation.isPlainUsername(""))
        #expect(!CredentialRotation.isPlainUsername("-o"))
        #expect(!CredentialRotation.isPlainUsername("a b"))
        #expect(!CredentialRotation.isPlainUsername("a'b"))
        #expect(!CredentialRotation.isPlainUsername("ä"))
    }

    /// Refuses a bundle without a pending rotation before it contacts any guest.
    @Test func refusesBundleWithoutPendingRotation() async throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        try VMBundleTests.settingsJSON.write(to: bundle.settingsFile, atomically: true, encoding: .utf8)
        await #expect(throws: MacpoolError.credentialRotation(
            step: "starting",
            reason: "the bundle has no pending rotation",
        )) {
            try await CredentialRotation.rotate(
                bundle: bundle,
                address: "192.0.2.1",
                logger: Logger(label: "test"),
            )
        }
        #expect(try bundle.settings().credentialRotation == nil)
    }
}
