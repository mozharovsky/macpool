# ``MacpoolCLI``

The `macpool` command line, which drives one VM's lifecycle step by step.

## Overview

Each subcommand performs one step and prints `measure key=value` lines with its timings and
sizes, so logs can collect them with `grep`. Other output lines describe progress.

Diagnostics go to standard error. `--log-level` on `create` and `run` selects how much of them
appears, and the default `warning` shows only unexpected events.

The binary needs the `com.apple.security.virtualization` entitlement to start a VM.
`Scripts/build.sh` builds it in the release configuration and signs it with that entitlement.

### Workflow

`macpool fetch --download` finds the newest restore image that the host supports and downloads
it. `macpool create` makes a bundle and installs macOS from the IPSW. The first
`macpool run --provision --wait-ssh` creates the guest account in the bundle and boots the guest
until SSH answers.

`macpool clone` copies a stopped bundle with APFS and gives the copy its own identity. The copy
starts with the source's guest password and SSH host keys. `macpool run` boots any bundle, and
`macpool ip` prints a running guest's address.

### Clone credentials

A clone's first `run` replaces the inherited password and host keys through `CredentialRotation`
from MacpoolVM before it prints `ready`. It reports the time as `measure rotate_seconds` and the
new key's fingerprint as `measure host_key`. When the rotation fails, `run` stops the VM. A clone
whose rotation began and did not finish is refused by `run`, `clone`, and `Scripts/ssh.sh`.

### Stopping a guest

macOS answers the virtual power button with a dialog. A run that ends by request therefore waits
90 seconds and then forces the stop. A clean stop comes from inside the guest.
`Scripts/shutdown.sh BUNDLE` feeds the guest account's password to `sudo -S` over SSH, because
the session has no terminal, and starts the shutdown. `run` reports a clean end as
`measure stop=guest` and a forced one as `measure stop=forced`.

### Bundles in use

`run` and `create` hold the bundle's lock, a `BundleLock` from MacpoolVM, while they work. `clone`
takes the source's lock for the copy. A clone therefore never captures a disk that a running guest
writes. `ip` answers only while a `run` holds the bundle.

`run` records the first boot in the bundle's settings. It refuses a first boot without
`--provision` and `--provision` on a bundle that has booted, because the guest applies
provisioning only once.

## Topics

### Commands

- ``Macpool``
- ``FetchCommand``
- ``CreateCommand``
- ``CloneCommand``
- ``RunCommand``
- ``AddressCommand``

### Support

- ``CommandError``
- ``HostTools``
- ``Report``
- ``LoggingOptions``
- ``LogLevel``
