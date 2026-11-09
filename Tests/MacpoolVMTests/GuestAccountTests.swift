import Foundation
@testable import MacpoolVM
import Testing
import Virtualization

/// Tests of the guest account file and the provisioning options.
struct GuestAccountTests {
    /// A deterministic generator that repeats a fixed sequence.
    struct SequenceGenerator: RandomNumberGenerator {
        /// The next value to return.
        var state: UInt64

        /// Returns the next value of a simple linear congruential sequence.
        ///
        /// - Returns: The next pseudorandom value.
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// Generates passwords of the fixed length from the fixed alphabet.
    @Test func generatesPasswordsFromAlphabet() {
        var generator = SequenceGenerator(state: 1)
        let first = GuestAccount.generatePassword(using: &generator)
        let second = GuestAccount.generatePassword(using: &generator)
        #expect(first.count == GuestAccount.passwordLength)
        #expect(first.allSatisfy(GuestAccount.passwordAlphabet.contains))
        #expect(first != second)
        #expect(!GuestAccount.passwordAlphabet.contains("0"))
        #expect(!GuestAccount.passwordAlphabet.contains("l"))
    }

    /// Creates the account file with owner-only permissions and keeps it afterward.
    @Test func createsAccountOnce() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        let account = try GuestAccount.loadOrCreate(in: bundle)
        #expect(account.username == "macpool")
        #expect(account.password.count == GuestAccount.passwordLength)
        let attributes = try FileManager.default
            .attributesOfItem(atPath: bundle.guestAccountFile.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try GuestAccount.loadOrCreate(in: bundle) == account)
    }

    /// Reads an account file in the layout that existing bundles use.
    @Test func readsExistingAccount() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        try #"{"full_name": "macpool", "username": "macpool", "password": "secret"}"#
            .write(to: bundle.guestAccountFile, atomically: true, encoding: .utf8)
        #expect(
            try GuestAccount.loadOrCreate(in: bundle)
                == GuestAccount(fullName: "macpool", username: "macpool", password: "secret"),
        )
    }

    /// Accepts a complete account and rejects an empty user name.
    ///
    /// The framework validates the options only on a host that can run VMs, which excludes hosted
    /// CI runners that are VMs themselves.
    @Test(.enabled(if: VZVirtualMachine.isSupported, "needs a host that can run VMs"))
    func validatesProvisioningOptions() throws {
        let account = GuestAccount(fullName: "Test", username: "test", password: "a-long-test-password")
        let options = try GuestProvisioning(account: account).startOptions()
        #expect(options.guestProvisioningOptions?.username == "test")
        var rejected = GuestProvisioning(account: account)
        rejected.account.username = ""
        #expect {
            try rejected.startOptions()
        } throws: { error in
            guard case let .framework(_, _, code, _) = error as? MacpoolError else {
                return false
            }
            return code == VZError.Code.guestProvisioningInvalidUsername.rawValue
        }
    }
}
