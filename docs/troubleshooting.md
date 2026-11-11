# Troubleshooting

This page says where macpool writes its logs and what it does when a VM, a supervisor, or the
daemon's state file fails.

## Logs

| Log | Where |
| --- | --- |
| A command's measurements and progress | Standard output. |
| A command's diagnostics | Standard error. `--log-level info` shows each step of the VM's life. |
| A leased VM | `logs/LEASE.log` in the daemon's data directory. |
| The daemon under launchd | `logs/daemon.log` in the data directory. `daemon install` prints its path. |

When the daemon starts or deletes a clone, it also deletes the logs of ended leases that haven't
changed for 7 days. `logs/daemon.log` isn't rotated.

## A guest that doesn't stop

macOS answers the virtual power button with a dialog and keeps running. When `run` stops a VM, it
waits 90 seconds and then forces the stop. It reports `measure stop=forced`. To stop cleanly, run
`Scripts/shutdown.sh BUNDLE` and let `run` report `measure stop=guest`.

## A clone that `run` refuses

If `run`, `clone`, or `Scripts/ssh.sh` says that a clone didn't finish replacing its guest
credentials, delete the clone and clone the source again. If it says that the credentials are
still being replaced, wait for the other `run` to print `ready`. See
[Clone credentials](clone-credentials.md).

## The daemon stopped

Leased VMs keep running when the daemon stops. A new daemon reconnects to their supervisors.

If the daemon stops, a `lease` without `--detach` tries for 60 seconds to reach a new daemon. When
one answers, `lease` keeps its lease. If it can't reconnect or the lease ends early, it sends
`SIGTERM` to the command after `--` and waits for that command to exit before it fails.

Requests that wait in the queue aren't stored. When the daemon stops, their `lease` commands exit
with an error.

## A supervisor that doesn't answer

If a supervisor doesn't reconnect within 30 seconds after its connection broke, or ignores a stop
for 30 seconds, the daemon ends it. It sends another stop, then `SIGTERM`, then `SIGKILL`, 10
seconds apart. If that lease was ending, the daemon deletes its clone. Any other lease boots again
or ends as it would after a crash.

## The state file

The daemon keeps its leases in `state.json` in the data directory.

| Problem | What the daemon does |
| --- | --- |
| The file is malformed. | Moves it aside as `state.json.invalid-TIME`, starts without leases, stops the VMs it finds, and deletes their clones. |
| The file can't be opened, or it uses a format version that this build doesn't read. | Doesn't start. The VMs keep running. |
| The file can't be written. | An ended lease keeps its VM, clone, and slot. The daemon retries every second and cleans up after a write succeeds. |

This build writes format version 2, with an owner for each lease. A build that reads only
version 1 refuses to start on that file.
