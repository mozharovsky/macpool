# macpool

macpool turns Macs into pools of disposable macOS VMs for coding agents and CI. It builds directly
on Apple's Virtualization framework. A VM comes from an APFS clone of a prepared image, does one
job, and is deleted.

The repository holds the first stage. It creates a VM from a macOS restore image, provisions the
guest on its first boot without a person, clones stopped VMs, and boots them headless until SSH
answers. A daemon leases clones to clients, queues requests while every VM slot is busy, and boots
crashed VMs again. Image layers and remote interfaces come later.

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
it, `create` removes the bundle. The sparse disk takes 128 GB by default and uses host space only
as the guest writes. The guest cannot use a larger disk later. Xcode with an iOS simulator runtime
does not fit in 64 GB. `clone` copies a stopped bundle with APFS in milliseconds and gives the copy
a new machine identifier and MAC address.

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
`/Volumes/My Shared Files`. With `--share-read-only`, the guest can only read it. `lease` accepts
both options.

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

Swift code runs commands in a running guest through `GuestSession` from MacpoolVM. It logs in as
the bundle's account and accepts only the host key that `known_hosts` pins. A clone pins its key
on its first run. A bundle from `create` has no pinned key until `Scripts/ssh.sh` connects once.
A root command goes through sudo. Sudo reads the password from standard input. If sudo runs
without a password, the session stops the command before it starts.

Every command prints `measure key=value` lines with its timings and sizes.

## Leases

The pool daemon owns the host's VM slots and hands out clones of stopped bundles as leases.

```sh
$macpool daemon install
$macpool lease --from .cache/vms/base -- sh -c 'Scripts/ssh.sh "$MACPOOL_BUNDLE" sw_vers'
$macpool lease --from .cache/vms/base --ttl 7200 --detach
$macpool list
$macpool renew LEASE
$macpool release LEASE
$macpool daemon uninstall
```

`daemon install` registers `macpool daemon run` as a launchd job in your login session. launchd
starts it at login and again whenever it exits. Running `daemon install` again replaces the job.
`macpool daemon` runs the same daemon in the foreground, and `--slots 1` limits it to one VM. The
daemon keeps its state, clones, sockets, and logs in `~/Library/Application Support/macpool`.
Every pool command except `daemon uninstall` accepts `--data-dir` for another directory, which
must be on the same APFS volume as the source bundles. The daemon refuses a data directory that belongs to another user or
that other users can write to.

`lease` waits in a queue while every slot is busy and prints `queued position=N`. A higher
`--priority` goes first, and equal priorities go in arrival order. Once a slot is free, the daemon
clones the source and boots the clone. `lease` then prints `lease_id=`, `bundle=`, `address=`,
`expires_at=`, and `ready`. The daemon refuses a source that is running, has never booted, or lies
on another volume, and a `--share` directory that does not exist.

Without `--detach`, the lease lasts as long as `lease` runs. Control-C releases it. A command after
`--` runs with `MACPOOL_LEASE_ID`, `MACPOOL_BUNDLE`, and `MACPOOL_ADDRESS` in its environment, and
its end releases the lease. With `--detach`, `lease` exits at `ready` and the lease lasts until
`release` or its expiry.

The time to live from `--ttl` starts at the first `ready` and defaults to one hour. `renew` sets
the expiry to the time to live from now. `list` prints the slots, leases, and queue, and `--json`
prints them as JSON. The daemon deletes a clone when its lease ends.

When a leased VM stops unexpectedly, the daemon boots the same clone again after 5, 10, and 20
seconds and then ends the lease. `--restart never` ends the lease at the first stop, and
`--restart always` also boots the clone again after the guest shuts down.

Each leased VM runs in its own `macpool supervise` process with a log in `logs/LEASE.log` in the
data directory. When the daemon starts or deletes a clone, it also deletes the logs of ended leases
that have not changed for 7 days. The VMs keep running when the daemon stops. A new daemon
reconnects to them, and a `lease` without `--detach` reconnects within 60 seconds. When `lease`
cannot reconnect or its lease ends, it stops the command after `--` first.

The daemon ends a supervisor when it cannot reconnect within 30 seconds after the connection
broke, or when the supervisor ignores a stop for 30 seconds. It tries another stop, then `SIGTERM`,
then `SIGKILL`, 10 seconds apart. A lease that was ending then loses its clone, and any other
lease boots again or ends as after a crash.

A malformed state file moves aside as `state.json.invalid-TIME`. The daemon then starts without
leases and stops the VMs that it finds. A state file in a format version that this build does not
read, or one that cannot be opened, keeps the daemon from starting, and the VMs keep running.
While the state file cannot be written, an ended lease keeps its VM, clone, and slot. The daemon
retries the write every second and stops the VM and deletes the clone after a write succeeds.

## Known limitations

- A clone accepts its source's password and host key until its first `run` prints `ready`, which
  took 11 to 69 seconds after SSH answered. Anyone with the source's password, in another guest or
  on the host, can log in during that time and leave access behind that `ready` does not reveal.
- When the source has no `known_hosts` file, a clone's first `run` trusts the first key the clone
  presents. A file without an unrevoked Ed25519 pin makes that `run` fail instead.
- The host finds a guest's service process by comparing process listings from before and after
  the start. When another VM starts in the same moment, `run` skips the priority change and the
  memory sample.
- Locks are advisory. They coordinate macpool commands and do not stop other tools from changing
  a bundle.
- The daemon runs in the login session of the user who installed it. Its VMs do not start before
  that user logs in.
- A lease's VM stops by force when the lease ends, so the guest gets no clean shutdown.
- Requests that wait in the queue are not stored. When the daemon stops, their `lease` commands
  exit with an error.
- The daemon counts only its own VMs. A `run` or `create` beside it can take a slot that macOS
  allows, and a lease's boot then fails and counts as a crash.
- Two daemons with different data directories each count two slots of their own, so together they
  can try to run more VMs than macOS allows.
- Under launchd the daemon's own log, `logs/daemon.log`, grows without rotation.
- The first start of this build's daemon rewrites `state.json` in format version 2, which records
  lease owners. A build from before that version then refuses to start on the file.

## Development

[AGENTS.md](AGENTS.md) lists the checks that every change passes, and
[CONTRIBUTING.md](CONTRIBUTING.md) describes how to contribute.

## License

macpool is available under the MIT license. See [LICENSE](LICENSE).
