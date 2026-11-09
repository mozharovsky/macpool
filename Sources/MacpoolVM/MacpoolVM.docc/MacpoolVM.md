# ``MacpoolVM``

Create, clone, and run disposable macOS VMs with Apple's Virtualization framework.

## Overview

MacpoolVM covers one VM's lifecycle on an Apple silicon Mac. It finds and loads macOS restore
images, creates VM bundles, installs macOS into them, clones stopped bundles with APFS, and boots
them headless with NAT networking and an optional shared directory.

A ``VMBundle`` is a directory that holds everything a stopped VM needs. A clone of the directory
becomes a second VM once ``VMBundle/assignIdentity()`` gives it a new machine identifier and MAC
address. Cloning takes milliseconds, and the clone shares every block with its source until one
of them writes. The clone starts with the source's guest account and SSH host keys, and
``CredentialRotation`` replaces both on the clone's first boot. The bundle then pins the new host
key as a ``HostKey`` and records the progress as ``CredentialRotationState``.

A ``BundleLock`` marks a bundle in use. Commands hold it while a VM runs from the bundle or while
they copy it, which keeps a clone from capturing a disk that a guest writes.

A ``VirtualMachine`` is an actor whose executor is the VM's dispatch queue. The framework requires
every call on that queue, and the actor makes the compiler check that requirement. The framework
also delivers its completion handlers and delegate calls on the queue, so the library needs no
main thread or run loop.

Each ``VirtualMachine`` accepts a swift-log `Logger`. It logs lifecycle steps at `info`,
configuration details at `debug`, and framework events at `notice` or above. The application
chooses the level and the destination.

### First boot without a person

macOS 27 guests accept provisioning options on their first boot after an install. A
``GuestProvisioning`` value creates an administrator account, turns on automatic login and Remote
Login, and skips Setup Assistant. The host then finds the guest's address in its DHCP leases with
``DHCPLeases`` and waits for SSH with ``SSHProbe``.

### Requirements

The library needs a Mac with Apple silicon and macOS 27. The process that creates a VM needs the
`com.apple.security.virtualization` entitlement. macOS allows two VMs per host.

## Topics

### Bundles

- ``VMBundle``
- ``BundleSettings``
- ``GuestAccount``
- ``BundleLock``
- ``CredentialRotationState``

### Restore images

- ``RestoreImages``
- ``RemoteRestoreImage``
- ``LocalRestoreImage``

### Running a VM

- ``VirtualMachine``
- ``MachineDevices``
- ``MachineState``
- ``MachineEvent``
- ``GuestProvisioning``

### Reaching the guest

- ``DHCPLeases``
- ``DHCPLease``
- ``MACAddress``
- ``SSHProbe``
- ``CredentialRotation``
- ``HostKey``

### Errors

- ``MacpoolError``
