# macpool

macpool gives every job its own clean macOS virtual machine. You prepare a macOS VM once. For
each job, macpool clones that VM, boots the clone, hands it to the job, and deletes the clone when
the job ends. A job can install or break anything in its VM, and the next job still starts from
the same prepared state. macpool is meant for coding agents and CI jobs on Macs with Apple
silicon, and it builds directly on Apple's Virtualization framework.

## What works today

macpool runs on one Mac. It downloads a macOS restore image and installs it into a VM without
anyone clicking through Setup Assistant. It clones a stopped VM in milliseconds and boots clones
headless until SSH answers. A daemon hands out clones as leases. macOS runs at most two VMs at a
time on one Mac. When both are taken, the daemon queues further requests. It also boots a crashed
VM again and deletes each clone when its lease ends.

These parts do not exist yet.

- Leases come only from the Mac that runs the daemon. One Mac cannot lease a VM from another.
- The command line cannot run a command in a guest by itself. You reach a guest over SSH.
- A prepared VM has no layers. Each one is a full copy of macOS.
- There is no packaged release. You build macpool from source.

## Quick start

You need a Mac with Apple silicon, macOS 27, and Xcode 27.0. The examples assume Xcode 27.0 at
`/Applications/Xcode_27.0.app`. If yours is elsewhere, point `DEVELOPER_DIR` at its
`Contents/Developer` directory instead. `Scripts/build.sh` stops with an error when
`DEVELOPER_DIR` selects another Xcode version. Run every command from the repository's root
directory. You will use two terminal windows.

Build the binary.

```sh
export DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer
Scripts/build.sh
macpool=.build/release/macpool
```

`Scripts/build.sh` builds the release binary and signs it with the
`com.apple.security.virtualization` entitlement. Virtualization refuses to start a VM in a process
without that entitlement. That is why a binary from a plain `swift build` cannot start VMs. The
script prints the binary's path, and `.build/release/macpool` links to it.

Download macOS.

```sh
$macpool fetch --download
```

`fetch` finds the newest restore image that your Mac supports and downloads it to `.cache/ipsw`.
The line `measure ipsw_path=` names the file. Its name is the macOS build, as in
`.cache/ipsw/BUILD.ipsw`. If the download breaks off, run the command again to continue it.

Install macOS into a new VM. Replace `BUILD` with the value of `measure restore_build=`.

```sh
$macpool create --ipsw .cache/ipsw/BUILD.ipsw --bundle .cache/vms/base
```

`create` makes the VM's directory and installs macOS into it. It prints
`install progress N% after S s` while it works. The VM gets 8 virtual CPUs, 16 GB of memory, and a
128 GB disk that takes space on your Mac only as the guest writes to it.

Boot the VM once to create its account.

```sh
$macpool run --bundle .cache/vms/base --provision --wait-ssh --hold 3600
```

The first boot creates an administrator account with a random password, turns on SSH, and skips
Setup Assistant. Wait until `run` prints `ready`. If you want tools in every clone, install them
now over SSH with `Scripts/ssh.sh .cache/vms/base`.

Shut the guest down from the second terminal.

```sh
Scripts/shutdown.sh .cache/vms/base
```

The first SSH connection pins the guest's host key in the VM's directory. Every clone of this VM
checks that key later. `run` in the first terminal prints `measure stop=guest` and exits. The VM
is now ready to clone.

Start the daemon in the first terminal.

```sh
$macpool daemon
```

It prints `listening` and the path of its socket, and it keeps running in the foreground. The
daemon keeps its clones in `~/Library/Application Support/macpool`. That directory must be on the
same APFS volume as `.cache/vms`.

Lease a clone and open a shell in it from the second terminal. Set `macpool` there too.

```sh
macpool=.build/release/macpool
$macpool lease --from .cache/vms/base -- sh -c 'Scripts/ssh.sh "$MACPOOL_BUNDLE"'
```

The daemon clones the VM, boots the clone, and gives it its own password and host key. `lease`
prints `lease_id=`, `bundle=`, `address=`, `expires_at=`, and `ready`, and then the shell opens.
When you leave the shell, the lease ends and the daemon deletes the clone. Press Control-C in the
first terminal to stop the daemon.

## How it works

A restore image is the IPSW file that Apple publishes for each macOS release. macpool installs
macOS from it into each new VM.

A bundle is a directory that holds one VM. It contains the disk image, the machine's identity,
`settings.json`, the guest account in `guest-account.json`, and the pinned SSH host key in
`known_hosts`. A bundle that has booted once and stopped is the source that you clone from.

A clone is a copy of a stopped bundle. APFS makes the copy, and the clone shares its disk blocks
with the source until one of them writes. The clone gets its own machine
identifier and MAC address. Its first boot replaces the guest password and SSH host key that it
inherited from the source.

`run` boots a bundle headless with NAT networking. macpool waits until the guest has an address
and, if you ask, until SSH answers. Then it prints `ready`. While a command boots or copies a
bundle, it holds a lock on the bundle. No other macpool command can boot it or clone it in that
time.

A lease is a clone that the daemon makes for you. It lasts while your `lease` command runs, or
until you release it or it expires. When it ends, the daemon stops the VM and deletes the clone.

The daemon owns your Mac's VM slots, one for each VM that macOS allows. Each leased VM runs in its
own supervisor process. When the daemon stops, leased VMs keep running, and the next daemon picks
them up.

A job reaches its guest over SSH. `Scripts/ssh.sh` logs in with the account stored in the bundle
and accepts only the pinned host key. If you write Swift, `GuestSession` in the `MacpoolVM`
library runs commands in a guest the same way. It runs a command as root through `sudo` and gives
`sudo` the password on standard input. If `sudo` runs without asking for a password, the session
stops the command before it starts.

## Commands

`macpool --help` lists the commands, and `macpool help COMMAND` lists a command's options.
`macpool --version` prints the version. The examples keep images and bundles in the ignored
`.cache` directory.

### Prepare a VM

`macpool fetch` prints the newest restore image that your Mac supports. `--download` also
downloads it. `--cache DIR` picks the directory and defaults to `.cache/ipsw`. `fetch`
refuses to download over an IPSW that is already there.

`macpool create --ipsw FILE --bundle DIR` creates a bundle and installs macOS into it. The bundle's
directory must not exist yet. `--cpus` defaults to 8 and `--memory-gb` to 16. `--disk-gb` sets the
disk size and defaults to 128. If the install fails or you press Control-C, `create` deletes the
bundle.

The first `run` of a new bundle needs `--provision`. It creates the account in
`guest-account.json` with a random password that only you can read. The guest applies that account
only on its first boot after the install. That is why `run` refuses a first boot without
`--provision` and refuses `--provision` on a bundle that has booted. It records the first boot as
`has_booted` in `settings.json`.

### Run a bundle

`macpool run --bundle DIR` boots a bundle and prints `ready` once the guest has an address.
`--wait-ssh` also waits for SSH. `--timeout` limits that wait and defaults to 900 seconds. On a
clone's first run, it also limits the credential replacement.

`--hold` sets how many seconds the VM keeps running after `ready`. With the default of 0, `run`
starts to stop the VM right after `ready`. If you create the file `stop-request` in the bundle,
the hold ends early. If the file appears before `ready`, `run` stops the VM and fails.

`--share DIR` shares a host directory with the guest. The guest mounts it at
`/Volumes/My Shared Files`. With `--share-read-only`, the guest can only read it.

`macpool ip --bundle DIR` prints the guest's address. It prints one only while a command holds the
bundle and the guest's DHCP lease is current.

`Scripts/ssh.sh DIR [COMMAND]` runs a command in the guest over SSH, or opens a shell without one.
It ignores your own SSH configuration and agent. Its first connection to a bundle pins the guest's
Ed25519 host key in the bundle's `known_hosts`, and later connections refuse any other key.

macOS answers the virtual power button with a dialog. When the hold ends or you request a stop,
`run` therefore waits 90 seconds and then forces the stop. For a clean stop, run
`Scripts/shutdown.sh DIR`. It shuts the guest down from inside over SSH. `run` reports a clean
stop as `measure stop=guest` and a forced one as `measure stop=forced`.

### Clone a bundle by hand

`macpool clone --from SOURCE --to DIR` copies a stopped bundle and gives the copy a new identity.
The target directory must not exist yet. `clone` refuses a source that a command holds. It
never copies a disk that a running guest writes to.

A clone's first `run` always waits for SSH, because it replaces the inherited credentials over
SSH. Use the clone only after that `run` prints `ready`. See
[Clone credentials](#clone-credentials) for what to do when this step fails.

`run` keeps its terminal busy until the VM stops. Run the commands after it in a second terminal.

```sh
$macpool clone --from .cache/vms/base --to .cache/vms/job1
$macpool run --bundle .cache/vms/job1 --share "$PWD" --hold 600
Scripts/ssh.sh .cache/vms/job1 'ls "/Volumes/My Shared Files"'
Scripts/shutdown.sh .cache/vms/job1
```

`Scripts/shutdown.sh` returns before the guest stops. Wait until `run` exits, and then delete the
clone with `rm -rf .cache/vms/job1`.

### Lease clones from the daemon

`macpool daemon` runs the daemon in the foreground. It is short for `macpool daemon run`.
`--slots 1` limits it to one VM, and the default is 2. Control-C stops the daemon and leaves leased
VMs running.

`macpool daemon install` registers the daemon as a launchd job in your login session and starts
it. launchd starts it again at login and whenever it exits. It takes `--data-dir` and `--slots`.
If you run it again, it replaces the job. `macpool daemon uninstall` stops the job and removes it.
Neither stops leased VMs.

The daemon keeps its state, clones, sockets, and logs in `~/Library/Application Support/macpool`.
Every pool command except `daemon uninstall` takes `--data-dir DIR` for another directory. The
directory must be on the same APFS volume as your source bundles. The daemon refuses a directory
that belongs to another user or that other users can write to.

`macpool lease --from SOURCE` asks the daemon for a clone of a stopped source. While both slots are
busy, it prints `queued position=N` and waits. A higher `--priority` gets a slot first, and the
default is 0. Requests with equal priority wait in the order they arrived. Once the clone is ready,
`lease` prints `lease_id=`, `bundle=`, `address=`, `expires_at=`, and `ready`.

The daemon refuses a source that is running, has never booted, lies on another volume, or did not
finish replacing its credentials. It also refuses a `--share` directory that does not exist.
`lease` takes `--share` and `--share-read-only` as `run` does. `--boot-timeout` limits the wait for
each boot of the clone and defaults to 900 seconds.

Without `--detach`, the lease lasts as long as `lease` runs, and Control-C releases it. A command
after `--` runs with `MACPOOL_LEASE_ID`, `MACPOOL_BUNDLE`, and `MACPOOL_ADDRESS` in its
environment. The lease ends when the command exits, and `lease` exits with the command's status.

With `--detach`, `lease` exits at `ready`, and the lease lasts until you release it or it expires.
Every lease expires. `--ttl` sets its time to live in seconds, counted from the first `ready`. The
default is one hour.

`macpool list` prints the slots, leases, and queue. `--json` prints them as one JSON object.
`macpool renew LEASE` moves the lease's expiry to its time to live from now and prints the new
`expires_at=`. `macpool release LEASE` ends a lease right away.

```sh
$macpool daemon install
$macpool lease --from .cache/vms/base -- sh -c 'Scripts/ssh.sh "$MACPOOL_BUNDLE" sw_vers'
$macpool lease --from .cache/vms/base --ttl 7200 --detach
$macpool list
$macpool renew LEASE
$macpool release LEASE
$macpool daemon uninstall
```

`--restart` decides when the daemon boots a leased VM again. With the default `on-failure`, the
daemon boots the same clone again if the VM stops unexpectedly. With `always`, it also does so
after the guest shuts itself down. With `never`, the lease ends at the first stop. A lease gets at
most three such boots, after 5, 10, and 20 seconds, and the next stop ends it. If the clone's
credential replacement stopped halfway, the daemon boots a fresh clone instead, and the old clone's
data is lost. `lease` prints `restarting reason=` and later `ready` again.

### Output

Every command prints `measure key=value` lines with its timings and sizes on standard output. You
can collect them with `grep`. Addresses and progress lines also go to standard output.
Diagnostics go to standard error. `create`, `run`, and `daemon run` take `--log-level`. The level
`info` shows each step of the VM's life, and the default `warning` shows only unexpected events.

## Clone credentials

A clone starts with its source's guest password and SSH host keys. Its first `run` replaces both
before it prints `ready`. The new password goes to the clone's `guest-account.json`, a file that
only you can read. The new Ed25519 host key goes to its `known_hosts`. `run` reports the time of
this step as `measure rotate_seconds` and the new key's fingerprint as `measure host_key`. A lease
goes through the same step before it reports `ready`.

`settings.json` records the step as `credential_rotation`. If the first login fails, the state stays
`pending`, and the next `run` tries again. If the step fails after the guest started to change, the
state is `started`. `run`, `clone`, and `Scripts/ssh.sh` refuse such a clone. Delete it and clone
the source again.

If the source has no `known_hosts` file, a clone's first `run` trusts the first host key that the
clone presents. If the file exists without an Ed25519 key that is still trusted, that `run` fails
instead. Connecting to the source once with `Scripts/ssh.sh` or `Scripts/shutdown.sh` writes the
file.

## When something fails

A leased VM runs in a process called `macpool supervise` and logs to `logs/LEASE.log` in the data
directory. When the daemon starts or deletes a clone, it also deletes the logs of ended leases that
have not changed for 7 days. Under launchd the daemon logs to `logs/daemon.log`.

If the daemon stops, a `lease` without `--detach` tries for 60 seconds to reach a new daemon. When
one answers, `lease` keeps its lease. If it cannot reconnect or the lease ends early, it sends
`SIGTERM` to the command after `--` and waits for that command to exit before it fails.

If a supervisor does not reconnect within 30 seconds after its connection broke, or ignores a
stop for 30 seconds, the daemon ends it. The daemon sends another stop, then `SIGTERM`, then
`SIGKILL`, 10 seconds apart. If that lease was ending, the daemon deletes its clone. Any other
lease boots again or ends as it would after a crash.

If `state.json` in the data directory is malformed, the daemon moves it aside as
`state.json.invalid-TIME` and starts without leases. It then stops the VMs that it finds and
deletes their clones. If the file cannot be opened or uses a format version that this build
cannot read, the daemon does not start, and the VMs keep running. While the file cannot be
written, an ended lease keeps its VM, clone, and slot. The daemon retries the write every second
and cleans up after a write succeeds.

## Requirements and limits

- A Mac with Apple silicon.
- macOS 27 or later on the host and in every guest. Unattended setup uses the guest provisioning
  that macOS 27 added to the Virtualization framework.
- Xcode 27.0, the version in `.xcode-version`, to build macpool.

macOS runs at most two VMs at a time on one Mac. Each guest takes all of its configured memory
while it runs. The default is 16 GB.

A disk's size is fixed when you create the bundle, and the guest cannot use a larger disk later.
The default is 128 GB. Xcode with an iOS simulator runtime does not fit on a 64 GB disk.

You will also meet these limits.

- Until a clone's first `run` prints `ready`, the clone accepts its source's password and host key.
  That usually lasts 11 to 69 seconds after SSH answers and can last until the `--timeout`
  deadline, and anyone with the source's password, in another guest or on the host, can log in
  during that time and leave access behind that `ready` does not reveal.
- Locks are advisory. They coordinate macpool commands and do not stop other tools from changing a
  bundle.
- The daemon counts only its own VMs. A `run` or `create` beside it can take a VM that macOS
  allows, and a lease's boot then fails and counts as a crash.
- Two daemons with different data directories each count their own slots. Together they can try
  to run more VMs than macOS allows.
- The daemon runs in the login session of the user who installed it. Its VMs do not start before
  that user logs in.
- When a lease ends, its VM stops by force. The guest gets no clean shutdown.
- Requests that wait in the queue are not stored. When the daemon stops, their `lease` commands
  exit with an error.
- `logs/daemon.log` grows without rotation.
- The daemon writes `state.json` in format version 2. A build that reads only version 1 refuses to
  start on that file.
- `run` finds the guest's host process by comparing process listings from before and after the
  start. When another VM starts in the same moment, `run` skips the priority change and the memory
  sample.

## Development

[AGENTS.md](AGENTS.md) lists the checks that every change passes, and
[CONTRIBUTING.md](CONTRIBUTING.md) describes how to contribute.

## License

macpool is available under the MIT license. See [LICENSE](LICENSE).
