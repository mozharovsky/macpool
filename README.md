# macpool

macpool turns Macs into pools of disposable macOS VMs for coding agents and CI. It builds directly
on Apple's Virtualization framework. A VM comes from an APFS clone of a prepared image, does one
job, and is deleted.

The repository holds the first stage. It creates a VM from a macOS restore image, provisions the
guest on its first boot without a person, clones stopped VMs, and boots them headless until SSH
answers. Pools, leases, image layers, and remote interfaces come later.

## Requirements

- A Mac with Apple silicon.
- macOS 27 or later on the host and in every guest. Unattended setup relies on the guest
  provisioning that macOS 27 added to the Virtualization framework.
- Xcode 27.0, the version pinned in `.xcode-version`.

macOS allows two VMs per host. Each guest takes all of its configured memory, which is 16 GB by
default.

## Setup

Select Xcode 27.0 for each command through `DEVELOPER_DIR` and leave the machine's global Xcode
selection unchanged. The scripts do this themselves when Xcode 27.0 is installed at
`/Applications/Xcode_27.0.app`.

```sh
export DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer
Scripts/install-hooks.sh
Scripts/build.sh
```

The framework refuses to start a VM in a process without the `com.apple.security.virtualization`
entitlement. `Scripts/build.sh` builds the release binary and signs it ad hoc with that
entitlement from `macpool.entitlements`. It prints the binary's path, which `.build/release/macpool`
also links to.

## Commands

Restore images and bundles live wherever you point the commands. The examples use the ignored
`.cache` directory.

```sh
macpool=.build/release/macpool
$macpool fetch --download
$macpool create --ipsw .cache/ipsw/BUILD.ipsw --bundle .cache/vms/base --cpus 8 --memory-gb 16
$macpool run --bundle .cache/vms/base --provision --wait-ssh --hold 600
Scripts/shutdown.sh .cache/vms/base
$macpool clone --from .cache/vms/base --to .cache/vms/clone1
$macpool run --bundle .cache/vms/clone1 --share /some/dir --wait-ssh --hold 600
$macpool ip --bundle .cache/vms/clone1
Scripts/ssh.sh .cache/vms/clone1 'ls "/Volumes/My Shared Files"'
```

`fetch` finds the newest restore image that the host supports and downloads it with `--download`.
`create` makes a bundle and installs macOS into it. When the install fails or Control-C interrupts
it, `create` removes the bundle. `clone` copies a stopped bundle with APFS in milliseconds and gives
the copy a new machine identifier and MAC address.

A clone starts with its source's guest password and SSH host keys. Its first `run` replaces both
and then prints `ready`, so use a clone only after `ready`. The new password goes to the clone's
`guest-account.json` with owner-only permissions, and the new Ed25519 host key goes to its
`known_hosts`.

`settings.json` records this step as `credential_rotation`. A failed first login leaves `pending`,
and the next `run` tries again. A failure after the guest started to change leaves `started`, so
delete that clone and clone the source again.

`run` and `create` hold an `flock` lock on the bundle's `lock` file. `clone` refuses a source that
a command holds, so it never copies a disk that a running guest writes. `ip` prints an address only
while a `run` holds the bundle and its DHCP lease is current.

`run` boots a bundle headless with NAT networking and prints `ready` once the guest has an address
and, with `--wait-ssh`, answers on SSH. It holds the VM for `--hold` seconds. Creating the bundle's
`stop-request` file ends the hold early. `--share` mounts a host directory in the guest at
`/Volumes/My Shared Files`.

Measurements and the address go to standard output. Diagnostics go to standard error, and
`--log-level info` on `create` or `run` shows each lifecycle step.

`run --provision` creates the account in the bundle's `guest-account.json` on first use, with a
random password and owner-only permissions. The guest applies it only on its first boot after the
install. `run` records that boot as `has_booted` in `settings.json`. It refuses a first boot
without `--provision` and a later `--provision`, because either would leave the guest without the
account. `Scripts/ssh.sh` logs in with that account. Its first connection pins the guest's Ed25519
host key in the bundle's `known_hosts`, and later connections refuse any other key.

macOS answers the virtual power button with a dialog. A run that ends by request therefore forces
the stop after 90 seconds. A clean stop comes from inside the guest. `Scripts/shutdown.sh BUNDLE`
gives sudo the account's password on standard input, because the SSH session has no terminal, and
starts the shutdown. `run` then reports `measure stop=guest`, and a forced stop reports
`measure stop=forced`.

Every command prints `measure key=value` lines with its timings and sizes.

## Known limitations

- A clone accepts its source's password and host key until its first `run` prints `ready`, which
  took 11 to 69 seconds after SSH answered. Anyone with the source's password, in another guest or
  on the host, can log in during that time and leave access behind that `ready` does not reveal.
- When the source's `known_hosts` pins no Ed25519 key, a clone's first `run` trusts the first key
  the clone presents.
- The host finds a guest's service process by comparing process listings from before and after
  the start. When another VM starts in the same moment, `run` skips the priority change and the
  memory sample.
- Locks are advisory. They coordinate macpool commands and do not stop other tools from changing
  a bundle.

## Development

[AGENTS.md](AGENTS.md) lists the checks that every change passes, and
[CONTRIBUTING.md](CONTRIBUTING.md) describes how to contribute.

## License

macpool is available under the MIT license. See [LICENSE](LICENSE).
