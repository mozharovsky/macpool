import Foundation
@testable import MacpoolVM
import Testing
import Virtualization

/// Tests of the device that shares a host directory with the guest.
struct SharedDirectoryTests {
    /// Shares the directory with the macOS automount tag and its access.
    @Test(arguments: [false, true])
    func sharesDirectoryWithItsAccess(isReadOnly: Bool) throws {
        let directory = try TemporaryDirectory()
        let device = MachineConfiguration.sharingDevice(
            for: SharedDirectory(url: directory.url, isReadOnly: isReadOnly),
        )
        #expect(device.tag == VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        let share = try #require(device.share as? VZSingleDirectoryShare)
        #expect(share.directory.url == directory.url.absoluteURL)
        #expect(share.directory.isReadOnly == isReadOnly)
    }

    /// Shares a directory writable unless the caller asks for read-only access.
    @Test func defaultsToWritable() {
        #expect(!SharedDirectory(url: URL(filePath: "/tmp")).isReadOnly)
    }
}
