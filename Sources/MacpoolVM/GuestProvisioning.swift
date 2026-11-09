import Virtualization

/// The account and services that a macOS guest sets up on its first boot after an install.
///
/// macOS 27 reads these options once and then skips Setup Assistant. The guest must run macOS 27
/// or later, and it ignores the options on any later boot.
public struct GuestProvisioning: Sendable, Equatable {
    /// The administrator account to create.
    public var account: GuestAccount

    /// Whether the account logs in automatically at startup.
    public var logsInAutomatically: Bool

    /// Whether the guest turns on Remote Login over SSH.
    public var enablesRemoteLogin: Bool

    /// Creates provisioning options for an account.
    ///
    /// - Parameters:
    ///   - account: The administrator account to create.
    ///   - logsInAutomatically: Whether the account logs in at startup.
    ///   - enablesRemoteLogin: Whether the guest turns on SSH.
    public init(account: GuestAccount, logsInAutomatically: Bool = true, enablesRemoteLogin: Bool = true) {
        self.account = account
        self.logsInAutomatically = logsInAutomatically
        self.enablesRemoteLogin = enablesRemoteLogin
    }

    /// Creates the framework's start options with these provisioning options.
    ///
    /// - Returns: Options for the VM's first start after an install.
    /// - Throws: ``MacpoolError/framework(operation:domain:code:description:)`` when the framework
    ///   rejects a value, such as an empty user name.
    func startOptions() throws(MacpoolError) -> VZMacOSVirtualMachineStartOptions {
        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.fullName = account.fullName
        provisioning.username = account.username
        provisioning.password = account.password
        provisioning.logsInAutomatically = logsInAutomatically
        provisioning.enablesRemoteLogin = enablesRemoteLogin
        let options = VZMacOSVirtualMachineStartOptions()
        do {
            try options.setGuestProvisioning(provisioning)
        } catch {
            throw .framework("setting guest provisioning options", error)
        }
        return options
    }
}
