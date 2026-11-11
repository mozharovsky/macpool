# Getting started

This page takes you from a fresh checkout to a shell inside a disposable clone. Each step says
what it does and what it prints when it works.

You need a Mac with Apple silicon, macOS 27, and Xcode 27.0. Run every command from the
repository root. You'll use two terminal windows.

## 1. Build the binary

```sh
Scripts/build.sh
macpool=.build/release/macpool
```

`Scripts/build.sh` builds the release binary and signs it with the
`com.apple.security.virtualization` entitlement. Virtualization refuses to start a VM in a process
without that entitlement. That's why a binary from a plain `swift build` can't start VMs. The
script prints the binary's path, and `.build/release/macpool` links to it.

The script uses the Xcode in `DEVELOPER_DIR`. If you don't set it, the script picks
`/Applications/Xcode_27.0.app`. If yours is elsewhere, point `DEVELOPER_DIR` at its
`Contents/Developer` directory. The script stops with an error when `DEVELOPER_DIR` selects
another Xcode version.

## 2. Download macOS

```sh
$macpool fetch --download
```

`fetch` finds the newest restore image that your Mac supports and downloads it to `.cache/ipsw`.
It prints the macOS build as `measure restore_build=` and names the file after it. The line
`measure ipsw_path=` gives the full path. If the download breaks off, run the command again to
continue it.

## 3. Install macOS into a new VM

```sh
$macpool create --ipsw .cache/ipsw/BUILD.ipsw --bundle .cache/vms/base
```

Replace `BUILD` with the value of `measure restore_build=`. `create` makes the VM's bundle and
installs macOS into it. It prints `install progress N% after S s` while it works. The VM gets 8
virtual CPUs, 16 GB of memory, and a 128 GB disk that takes space on your Mac only as the guest
writes to it.

## 4. Boot it once

```sh
$macpool run --bundle .cache/vms/base --provision --wait-ssh --hold 3600
```

The first boot creates an administrator account with a random password, turns on SSH, and skips
Setup Assistant. Wait until `run` prints `ready`.

If you want tools in every clone, install them now. `Scripts/ssh.sh .cache/vms/base` opens a shell
in the guest.

## 5. Shut it down

In the second terminal, run this.

```sh
Scripts/shutdown.sh .cache/vms/base
```

The first SSH connection pins the guest's host key in the bundle, and every clone checks that key
later. `run` in the first terminal prints `measure stop=guest` and exits. The VM is now a source
you can clone.

## 6. Start the daemon

In the first terminal, run this.

```sh
$macpool daemon
```

It prints `listening` and the path of its socket, and keeps running in the foreground. The daemon
keeps its clones in `~/Library/Application Support/macpool`. That directory must be on the same
APFS volume as `.cache/vms`.

## 7. Lease a clone

In the second terminal, run this.

```sh
macpool=.build/release/macpool
$macpool lease --from .cache/vms/base -- sh -c 'Scripts/ssh.sh "$MACPOOL_BUNDLE"'
```

The daemon clones the source, boots the clone, and gives it its own password and host key. `lease`
prints `lease_id=`, `bundle=`, `address=`, `expires_at=`, and `ready`, and then the shell opens.

When you leave the shell, the lease ends and the daemon deletes the clone. Press Control-C in the
first terminal to stop the daemon.

## Next steps

- To run the daemon in the background, install it as a launchd job. See
  [Leases and the daemon](leases.md).
- To clone and boot by hand without the daemon, see [Commands](commands.md).
