# Limits

This page lists what macpool needs from your Mac and the limits you'll run into.

## Requirements

- A Mac with Apple silicon.
- macOS 27 or later on the host and in every guest. Unattended setup uses the guest provisioning
  that macOS 27 added to the Virtualization framework.
- Xcode 27.0, the version in `.xcode-version`, to build macpool.

## VMs, memory, and disks

macOS runs at most two VMs at a time on one Mac. Each guest takes all of its configured memory
while it runs, 16 GB by default.

A disk's size is fixed when you create the bundle, and the guest can't use a larger disk later. The
default is 128 GB. The disk is sparse and takes space on your Mac only as the guest writes. Xcode
with an iOS simulator runtime doesn't fit on a 64 GB disk.

## Known limitations

- Until a clone's first `run` prints `ready`, anyone with its source's password can log in and
  leave access behind. [Clone credentials](clone-credentials.md#the-window-before-ready) explains
  the window.
- Locks are advisory. They coordinate macpool commands and don't stop other tools from changing a
  bundle.
- The daemon counts only its own VMs. A `run` or `create` beside it can take a VM that macOS
  allows, and a lease's boot then fails and counts as a crash.
- Two daemons with different data directories each count their own slots. Together they can try
  to run more VMs than macOS allows.
- The daemon runs in the login session of the user who installed it. Its VMs don't start before
  that user logs in.
- When a lease ends, its VM stops by force. The guest gets no clean shutdown.
- Requests that wait in the queue aren't stored. When the daemon stops, their `lease` commands exit
  with an error.
- `logs/daemon.log` grows without rotation.
- `run` finds the guest's host process by comparing process listings from before and after the
  start. When another VM starts in the same moment, `run` skips the priority change and the memory
  sample.
